defmodule Nous.Eval.Store.File do
  @moduledoc """
  The default `Nous.Eval.Store`: a directory of JSON files, no dependencies.

      {:ok, store} = Nous.Eval.Store.File.init(root: "priv/eval")

  ## Layout

      <root>/runs/<run id>.json   one run, as Nous.Eval.Codec.encode_run_json/1 text
      <root>/manifest.jsonl       one run summary per line, in insertion order
      <root>/baselines.jsonl      one baseline entry per line, in insertion order
      <root>/calibrations/sha256-<hex>.json
                                  the latest judge calibration for a fingerprint id,
                                  as Nous.Eval.Codec.encode_calibration_json/1 text
      <root>/profiles/sha256-<hex>.json
                                  one profile, as Nous.Eval.Codec.encode_profile_json/1 text
      <root>/profiles.jsonl       one line per named profile: name, version, id
      <root>/profile_labels.jsonl one profile label entry per line, in insertion order

  `list_runs/2` reads only the manifest, so listing never decodes a trace.
  Every file is replaced atomically (written to a temporary file in the same
  directory, synced, then renamed over the target), so a reader never sees a
  half-written run or a torn manifest line.

  A run's file is written before its manifest line, and a named profile's
  file before its `profiles.jsonl` line. If the process dies in between,
  the record is readable by id but not listed, and putting the same run or
  profile again completes the write instead of failing with
  `:already_exists` or assigning another version.

  Run ids, labels and profile names are checked with
  `Nous.Eval.Store.validate_run_id/1` / `validate_label/1` /
  `validate_profile_name/1`, and profile ids with `validate_profile_id/1`,
  before any path is built, so none can escape the root. The store assumes
  one writer per root: two processes appending to the manifest at the same
  moment can lose one line.

  `delete_runs_before/3` rewrites the manifest without the expired runs
  before it removes their files, so a crash in between leaves unlisted
  orphan files rather than a listed run that cannot be read.

  ## Options

    * `:root` - the directory (required); created if missing
  """

  @behaviour Nous.Eval.Store

  alias Nous.Eval.{Codec, Run, Store}
  alias Nous.Eval.Store.{Baseline, ProfileLabel, RunSummary}
  alias Nous.Profile

  @manifest "manifest.jsonl"
  @baselines "baselines.jsonl"
  @profile_index "profiles.jsonl"
  @profile_labels "profile_labels.jsonl"

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} when is_binary(root) and root != "" ->
        root = Path.expand(root)

        case File.mkdir_p(Path.join(root, "runs")) do
          :ok -> {:ok, %{root: root}}
          {:error, reason} -> {:error, {:mkdir_failed, root, reason}}
        end

      {:ok, other} ->
        {:error, {:invalid_option, {:root, other}}}

      :error ->
        {:error, {:missing_option, :root}}
    end
  end

  @impl true
  def put_run(%{root: root} = state, %Run{id: id} = run) do
    with :ok <- Store.validate_run_id(id),
         {:ok, payload} <- Codec.encode_run_json(run),
         {:ok, summary} <- Codec.encode_summary_json(RunSummary.from_run(run)),
         {:ok, lines} <- read_lines(Path.join(root, @manifest)),
         :ok <- ensure_unlisted(lines, id),
         :ok <- atomic_write(run_path(root, id), payload),
         :ok <- atomic_write(Path.join(root, @manifest), append_line(lines, summary)) do
      {:ok, state}
    end
  end

  @impl true
  def get_run(%{root: root}, id) do
    with :ok <- Store.validate_run_id(id) do
      case File.read(run_path(root, id)) do
        {:ok, text} -> Codec.decode_run_json(text)
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, {:read_failed, reason}}
      end
    end
  end

  @impl true
  def list_runs(%{root: root}, filters) do
    with {:ok, filters} <- Store.validate_filters(filters),
         {:ok, lines} <- read_lines(Path.join(root, @manifest)),
         {:ok, summaries} <- decode_summaries(lines) do
      summaries =
        summaries
        |> Enum.with_index()
        |> Enum.filter(fn {summary, _index} -> matches?(summary, filters) end)
        |> Enum.sort_by(fn {summary, index} -> sort_key(summary, index) end, :desc)
        |> Enum.map(fn {summary, _index} -> summary end)

      {:ok, take(summaries, filters[:limit])}
    end
  end

  @impl true
  def put_baseline(%{root: root} = state, label, run_id) do
    path = Path.join(root, @baselines)

    with :ok <- Store.validate_label(label),
         :ok <- Store.validate_run_id(run_id),
         :ok <- ensure_run_exists(root, run_id),
         {:ok, lines} <- read_lines(path) do
      entry = %{
        "label" => label,
        "run_id" => run_id,
        "set_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      with :ok <- atomic_write(path, append_line(lines, JSON.encode!(entry))), do: {:ok, state}
    end
  end

  @impl true
  def get_baseline(state, label) do
    case list_baselines(state, label) do
      {:ok, [latest | _]} -> {:ok, latest}
      {:ok, []} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @impl true
  def list_baselines(%{root: root}, label) do
    with :ok <- Store.validate_label(label),
         {:ok, lines} <- read_lines(Path.join(root, @baselines)) do
      lines
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case decode_baseline(line) do
          {:ok, %Baseline{label: ^label} = entry} -> {:cont, {:ok, [entry | acc]}}
          {:ok, _other_label} -> {:cont, {:ok, acc}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @impl true
  def put_calibration(%{root: root} = state, fingerprint_id, result) do
    dir = Path.join(root, "calibrations")

    with :ok <- Store.validate_calibration(fingerprint_id, result),
         {:ok, payload} <- Codec.encode_calibration_json(result),
         :ok <- mkdir(dir),
         :ok <- atomic_write(calibration_path(root, fingerprint_id), payload) do
      {:ok, state}
    end
  end

  @impl true
  def get_calibration(%{root: root}, fingerprint_id) do
    with :ok <- Store.validate_calibration(fingerprint_id) do
      case File.read(calibration_path(root, fingerprint_id)) do
        {:ok, text} -> decode_calibration(text, fingerprint_id)
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, {:read_failed, reason}}
      end
    end
  end

  @impl true
  def put_profile(%{root: root} = state, profile) do
    with {:ok, profile} <- Store.validate_profile(profile),
         {:ok, lines} <- read_lines(Path.join(root, @profile_index)),
         {:ok, index} <- decode_index(lines),
         {:ok, stored} <- read_profile(root, profile.id) do
      store_profile(state, profile, stored, index, lines)
    end
  end

  @impl true
  def get_profile(%{root: root}, ref) do
    with :ok <- Store.validate_profile_ref(ref),
         {:ok, id} <- resolve_ref(root, ref),
         {:ok, profile} <- fetch_profile(root, id),
         :ok <- Store.check_profile_ref(profile, ref) do
      {:ok, profile}
    end
  end

  @impl true
  def list_profiles(%{root: root}, name) do
    with :ok <- Store.validate_profile_name(name),
         {:ok, lines} <- read_lines(Path.join(root, @profile_index)),
         {:ok, index} <- decode_index(lines) do
      index
      |> Enum.filter(&(&1.name == name))
      |> Enum.sort_by(& &1.version, :desc)
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        ref = {:version, name, entry.version}

        with {:ok, profile} <- fetch_profile(root, entry.id),
             :ok <- Store.check_profile_ref(profile, ref) do
          {:cont, {:ok, [profile | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, profiles} -> {:ok, Enum.reverse(profiles)}
        error -> error
      end
    end
  end

  @impl true
  def put_profile_label(%{root: root} = state, name, label, profile_id) do
    path = Path.join(root, @profile_labels)

    with :ok <- Store.validate_profile_name(name),
         :ok <- Store.validate_label(label),
         :ok <- Store.validate_profile_id(profile_id),
         {:ok, %Profile{name: ^name}} <- named_profile(root, profile_id),
         {:ok, lines} <- read_lines(path) do
      entry = %{
        "name" => name,
        "label" => label,
        "profile_id" => profile_id,
        "set_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      with :ok <- atomic_write(path, append_line(lines, JSON.encode!(entry))), do: {:ok, state}
    else
      {:ok, %Profile{}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @impl true
  def list_profile_labels(%{root: root}, name, label) do
    with :ok <- Store.validate_profile_name(name),
         :ok <- Store.validate_label(label),
         {:ok, lines} <- read_lines(Path.join(root, @profile_labels)) do
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
        case decode_profile_label(line) do
          {:ok, %ProfileLabel{name: ^name, label: ^label} = entry} ->
            {:cont, {:ok, [entry | acc]}}

          {:ok, _other} ->
            {:cont, {:ok, acc}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    end
  end

  # -- retention (online eval) -----------------------------------------------

  @impl true
  def delete_runs_before(%{root: root} = state, task, before) do
    manifest = Path.join(root, @manifest)

    with :ok <- Store.validate_retention(task, before),
         {:ok, lines} <- read_lines(manifest),
         {:ok, summaries} <- decode_summaries(lines) do
      {expired, kept} =
        lines
        |> Enum.zip(summaries)
        |> Enum.split_with(fn {_line, summary} -> expired?(summary, task, before) end)

      delete_expired(root, manifest, expired, kept, state)
    end
  end

  defp delete_expired(_root, _manifest, [], _kept, state), do: {:ok, 0, state}

  # The manifest is rewritten before any run file is removed: a crash in
  # between leaves orphan run files (readable by id, never listed), never a
  # listed run whose file is gone. Ids are checked before anything is
  # written, so a corrupt id deletes nothing.
  defp delete_expired(root, manifest, expired, kept, state) do
    data = Enum.map(kept, fn {line, _summary} -> [line, ?\n] end)
    ids = Enum.map(expired, fn {_line, %RunSummary{id: id}} -> id end)

    with :ok <- validate_run_ids(ids),
         :ok <- atomic_write(manifest, data),
         :ok <- remove_run_files(root, ids) do
      {:ok, length(ids), state}
    end
  end

  defp expired?(%RunSummary{task: task, started_at: %DateTime{} = at}, task, before),
    do: DateTime.compare(at, before) == :lt

  defp expired?(%RunSummary{}, _task, _before), do: false

  defp validate_run_ids(ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Store.validate_run_id(id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp remove_run_files(root, ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case File.rm(run_path(root, id)) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:delete_failed, id, reason}}}
      end
    end)
  end

  # -- helpers ---------------------------------------------------------------

  defp run_path(root, id), do: Path.join([root, "runs", id <> ".json"])

  # `fingerprint_id` was validated as "sha256:<64 hex>", so the file name is
  # fixed-length hex and cannot escape the directory.
  defp calibration_path(root, "sha256:" <> hex),
    do: Path.join([root, "calibrations", "sha256-" <> hex <> ".json"])

  # `id` was validated as "sha256:<64 hex>", so the file name is fixed-length
  # hex and cannot escape the directory.
  defp profile_path(root, "sha256:" <> hex),
    do: Path.join([root, "profiles", "sha256-" <> hex <> ".json"])

  # `{:ok, profile | nil}`: nil when no file is stored under `id`.
  defp read_profile(root, id) do
    case fetch_profile(root, id) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp fetch_profile(root, id) do
    case File.read(profile_path(root, id)) do
      {:ok, text} ->
        with {:ok, profile} <- Codec.decode_profile_json(text),
             :ok <- Store.check_profile_ref(profile, {:id, id}),
             do: {:ok, profile}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp named_profile(root, id) do
    with {:ok, lines} <- read_lines(Path.join(root, @profile_index)),
         {:ok, index} <- decode_index(lines) do
      case Enum.find(index, &(&1.id == id)) do
        nil ->
          {:error, :not_found}

        entry ->
          with {:ok, profile} <- fetch_profile(root, id),
               :ok <- Store.check_profile_ref(profile, {:version, entry.name, entry.version}),
               do: {:ok, profile}
      end
    end
  end

  # An id already indexed (or an unnamed profile already written) is
  # returned as stored. A named profile's file without an index line is a
  # put that died half-way: it is indexed under the version it was written
  # with.
  defp store_profile(state, profile, stored, index, lines) do
    indexed = Enum.find(index, &(&1.id == profile.id))

    cond do
      stored && profile.name && stored.name != profile.name ->
        {:error, {:name_conflict, stored.name}}

      stored && (indexed || is_nil(stored.name)) ->
        {:ok, stored, state}

      stored ->
        with :ok <- append_index(state.root, lines, stored), do: {:ok, stored, state}

      is_nil(profile.name) ->
        write_profile(state, %{profile | version: nil}, lines, false)

      true ->
        version =
          index
          |> Enum.filter(&(&1.name == profile.name))
          |> Enum.map(& &1.version)
          |> Enum.max(fn -> 0 end)

        write_profile(state, %{profile | version: version + 1}, lines, true)
    end
  end

  defp write_profile(%{root: root} = state, profile, lines, index?) do
    with {:ok, payload} <- Codec.encode_profile_json(profile),
         :ok <- mkdir(Path.join(root, "profiles")),
         :ok <- atomic_write(profile_path(root, profile.id), payload),
         :ok <- if(index?, do: append_index(root, lines, profile), else: :ok) do
      {:ok, profile, state}
    end
  end

  defp append_index(root, lines, profile) do
    line =
      JSON.encode!(%{"name" => profile.name, "version" => profile.version, "id" => profile.id})

    atomic_write(Path.join(root, @profile_index), append_line(lines, line))
  end

  # Index lines are read back from disk, so the id is checked again before it
  # becomes a path.
  defp decode_index(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      with {:ok, %{"name" => name, "version" => version, "id" => id}}
           when is_binary(name) and is_integer(version) <- JSON.decode(line),
           :ok <- Store.validate_profile_id(id) do
        {:cont, {:ok, [%{name: name, version: version, id: id} | acc]}}
      else
        _ -> {:halt, {:error, {:corrupt_profile_index, line}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp resolve_ref(_root, {:id, id}), do: {:ok, id}

  defp resolve_ref(root, {:version, name, version}) do
    with {:ok, lines} <- read_lines(Path.join(root, @profile_index)),
         {:ok, index} <- decode_index(lines) do
      case Enum.find(index, &(&1.name == name and &1.version == version)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry.id}
      end
    end
  end

  defp resolve_ref(root, {:label, name, label}) do
    with {:ok, history} <- list_profile_labels(%{root: root}, name, label) do
      case history do
        [latest | _] -> {:ok, latest.profile_id}
        [] -> {:error, :not_found}
      end
    end
  end

  defp decode_profile_label(line) do
    with {:ok, %{"name" => name, "label" => label, "profile_id" => id, "set_at" => set_at}}
         when is_binary(name) and is_binary(label) and is_binary(id) and is_binary(set_at) <-
           JSON.decode(line),
         :ok <- Store.validate_profile_id(id),
         {:ok, set_at, _offset} <- DateTime.from_iso8601(set_at) do
      {:ok, %ProfileLabel{name: name, label: label, profile_id: id, set_at: set_at}}
    else
      _ -> {:error, {:corrupt_profile_label, line}}
    end
  end

  defp decode_calibration(text, fingerprint_id) do
    case Codec.decode_calibration_json(text) do
      {:ok, %{fingerprint_id: ^fingerprint_id} = result} -> {:ok, result}
      {:ok, _other} -> {:error, {:corrupt_calibration, fingerprint_id}}
      {:error, _} = error -> error
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp ensure_unlisted(lines, id) do
    # A cheap prefilter: only lines mentioning the id are decoded.
    needle = JSON.encode!(id)

    listed? =
      Enum.any?(lines, fn line ->
        String.contains?(line, needle) and
          match?({:ok, %RunSummary{id: ^id}}, Codec.decode_summary_json(line))
      end)

    if listed?, do: {:error, :already_exists}, else: :ok
  end

  defp ensure_run_exists(root, run_id) do
    if File.regular?(run_path(root, run_id)), do: :ok, else: {:error, :not_found}
  end

  defp decode_summaries(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Codec.decode_summary_json(line) do
        {:ok, summary} -> {:cont, {:ok, [summary | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp decode_baseline(line) do
    with {:ok, %{"label" => label, "run_id" => run_id, "set_at" => set_at}}
         when is_binary(label) and is_binary(run_id) and is_binary(set_at) <- JSON.decode(line),
         {:ok, set_at, _offset} <- DateTime.from_iso8601(set_at) do
      {:ok, %Baseline{label: label, run_id: run_id, set_at: set_at}}
    else
      _ -> {:error, {:corrupt_baseline_entry, line}}
    end
  end

  defp matches?(%RunSummary{} = summary, filters) do
    Enum.all?(filters, fn
      {:task, task} ->
        summary.task == task

      {:status, status} ->
        summary.status == status

      {:since, since} ->
        summary.started_at != nil and DateTime.compare(summary.started_at, since) != :lt

      {:until, until} ->
        summary.started_at != nil and DateTime.compare(summary.started_at, until) == :lt

      {:limit, _} ->
        true
    end)
  end

  # Newest start first, ties in reverse insertion order; runs without a start
  # time sort after every timed run.
  defp sort_key(%RunSummary{started_at: nil}, index), do: {0, 0, index}

  defp sort_key(%RunSummary{started_at: at}, index),
    do: {1, DateTime.to_unix(at, :microsecond), index}

  defp take(summaries, nil), do: summaries
  defp take(summaries, limit), do: Enum.take(summaries, limit)

  defp read_lines(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, String.split(text, "\n", trim: true)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp append_line(lines, line), do: Enum.map(lines ++ [line], &[&1, ?\n])

  defp atomic_write(path, data) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- write_synced(tmp, data),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:write_failed, path, reason}}
    end
  end

  defp write_synced(path, data) do
    with {:ok, io} <- :file.open(path, [:write, :binary, :raw]) do
      result =
        with :ok <- :file.write(io, data), do: :file.sync(io)

      case {result, :file.close(io)} do
        {:ok, close_result} -> close_result
        {error, _} -> error
      end
    end
  end
end
