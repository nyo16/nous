defmodule Nous.Eval.Store.File do
  @moduledoc """
  The default `Nous.Eval.Store`: a directory of JSON files, no dependencies.

      {:ok, store} = Nous.Eval.Store.File.init(root: "priv/eval")

  ## Layout

      <root>/runs/<run id>.json   one run, as Nous.Eval.Codec.encode_run_json/1 text
      <root>/manifest.jsonl       one run summary per line, in insertion order
      <root>/baselines.jsonl      one baseline entry per line, in insertion order

  `list_runs/2` reads only the manifest, so listing never decodes a trace.
  Every file is replaced atomically (written to a temporary file in the same
  directory, synced, then renamed over the target), so a reader never sees a
  half-written run or a torn manifest line.

  A run's file is written before its manifest line. If the process dies in
  between, the run is readable by id but not listed, and putting the same
  run again completes the write instead of failing with `:already_exists`.

  Run ids and labels are checked with `Nous.Eval.Store.validate_run_id/1` /
  `validate_label/1` before any path is built, so neither can escape the
  root. The store assumes one writer per root: two processes appending to
  the manifest at the same moment can lose one line.

  ## Options

    * `:root` - the directory (required); created if missing
  """

  @behaviour Nous.Eval.Store

  alias Nous.Eval.{Codec, Run, Store}
  alias Nous.Eval.Store.{Baseline, RunSummary}

  @manifest "manifest.jsonl"
  @baselines "baselines.jsonl"

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

  # -- helpers ---------------------------------------------------------------

  defp run_path(root, id), do: Path.join([root, "runs", id <> ".json"])

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
