defmodule Nous.Eval.Online.Promote do
  @moduledoc false
  # `Nous.Eval.promote/3` (documented there) and the `list/2` filters of
  # `Nous.Eval.Online`.
  #
  # A stored sample is already redacted; promotion applies the redactor
  # again (the current one: redactors evolve, and a dataset outlives the
  # online area's retention), and a sample whose re-redaction fails is
  # skipped, never promoted with its earlier content.

  alias Nous.Eval.{CanonicalJSON, Sample, Scoring, Trace}
  alias Nous.Eval.Online.Redaction
  alias Nous.Eval.Trace.{GuardVerdict, ModelCall, ToolCall}
  alias Nous.Message

  @surfaces ["user_input", "tool_call", "tool_result", "model_output"]

  # The split `Nous.Eval.Guard.Hygiene.hashed_split/1` assigns a group by
  # default (seed "nous-guard-v1", tune 0.4 / holdout 0.3 / test 0.3).
  @split_seed "nous-guard-v1"

  @type target :: :case | {:guard_case, keyword()}

  @doc false
  @spec promote({module(), term()}, [String.t()], keyword()) ::
          {:ok, %{promoted: non_neg_integer(), skipped: [{String.t(), atom()}]}}
          | {:error, term()}
  def promote(store, trace_ids, opts) when is_list(trace_ids) and is_list(opts) do
    with {:ok, opts} <- options(opts),
         {:ok, entries} <- Nous.Eval.Online.list(store, instance: opts.instance, ids: trace_ids),
         {:ok, existing} <- read_lines(opts.to) do
      by_id = Map.new(entries, &{&1.sample.trace_id, &1})
      seen = seen(existing)

      {lines, skipped, _seen} =
        Enum.reduce(trace_ids, {[], [], seen}, fn tid, {lines, skipped, seen} ->
          case promote_one(Map.get(by_id, tid), opts, seen) do
            {:ok, line, key} -> {[line | lines], skipped, MapSet.put(seen, key)}
            {:skip, reason} -> {lines, [{tid, reason} | skipped], seen}
          end
        end)

      with :ok <- write_lines(opts.to, existing ++ Enum.reverse(lines)) do
        {:ok, %{promoted: length(lines), skipped: Enum.reverse(skipped)}}
      end
    end
  end

  def promote(_store, trace_ids, _opts), do: {:error, {:invalid_trace_ids, trace_ids}}

  defp options(opts) do
    with {:ok, opts} <- keys(opts),
         {:ok, to} <- path(opts[:to]),
         {:ok, target} <- target(Keyword.get(opts, :as, :case)),
         {:ok, redact} <- redactor(opts[:redact]) do
      {:ok,
       %{
         to: to,
         target: target,
         redact: redact,
         reviewer: opts[:reviewer],
         instance: Keyword.get(opts, :instance, "default"),
         redact_timeout: Keyword.get(opts, :redact_timeout, 2_000)
       }}
    end
  end

  defp keys(opts) do
    Keyword.validate(opts, [:to, :as, :redact, :reviewer, :instance, :redact_timeout])
    |> case do
      {:ok, opts} -> {:ok, opts}
      {:error, unknown} -> {:error, {:unknown_options, unknown}}
    end
  end

  defp path(path) when is_binary(path) and path != "", do: {:ok, path}
  defp path(other), do: {:error, {:invalid_option, :to, other}}

  defp target(:case), do: {:ok, :case}

  defp target({:guard_case, gopts}) when is_list(gopts) do
    case Keyword.get(gopts, :surface) do
      surface when surface in @surfaces -> {:ok, {:guard_case, gopts}}
      other -> {:error, {:invalid_option, :surface, other}}
    end
  end

  defp target(other), do: {:error, {:invalid_option, :as, other}}

  # The redactor is required again; `:drop_content` would promote nothing.
  defp redactor(fun) when is_function(fun, 1), do: {:ok, fun}

  defp redactor(module)
       when is_atom(module) and module not in [nil, true, false, :drop_content] do
    if Code.ensure_loaded?(module) and function_exported?(module, :redact, 1),
      do: {:ok, module},
      else: {:error, {:invalid_redact, module}}
  end

  defp redactor(nil), do: {:error, :redact_required}
  defp redactor(other), do: {:error, {:invalid_redact, other}}

  # ── one sample ─────────────────────────────────────────────────────────────

  defp promote_one(nil, _opts, _seen), do: {:skip, :not_found}

  defp promote_one(%{sample: sample, info: info, run_id: run_id}, opts, seen) do
    with :ok <- has_content(info),
         {:ok, trace} <- re_redact(sample.trace, opts),
         {:ok, record} <- record(opts.target, trace, sample, info, run_id, opts) do
      key = dedup_key(record)

      cond do
        MapSet.member?(seen, {:trace, sample.trace_id}) -> {:skip, :duplicate}
        MapSet.member?(seen, key) -> {:skip, :duplicate}
        true -> {:ok, CanonicalJSON.encode(record), key}
      end
    end
  end

  # A sample stored without content (`:drop_content`, or a redactor that
  # failed at capture) has no input to build a case from.
  defp has_content(%{"redaction" => "redacted"}), do: :ok
  defp has_content(_info), do: {:skip, :no_content}

  defp re_redact(%Trace{} = trace, opts) do
    {content, keys} = Redaction.split(trace)

    with {:ok, redacted, :redacted} <-
           Redaction.redact(opts.redact, content, opts.redact_timeout, Nous.TaskSupervisor),
         {:ok, trace} <- Redaction.rebuild(trace, redacted, keys) do
      {:ok, trace}
    else
      _ -> {:skip, :redaction_failed}
    end
  end

  defp record(:case, trace, sample, info, run_id, opts) do
    case case_input(trace) do
      nil ->
        {:skip, :no_content}

      input ->
        {:ok,
         %{
           "schema" => "nous.case/1",
           "id" => "online-" <> sample.trace_id,
           "input" => input,
           "tags" => ["online"],
           "group" => info["group"] || sample.trace_id,
           "metadata" => %{"provenance" => provenance(sample, info, run_id, opts)}
         }}
    end
  end

  defp record({:guard_case, gopts}, trace, sample, info, run_id, opts) do
    surface = Keyword.fetch!(gopts, :surface)

    case guard_input(surface, trace, gopts) do
      nil ->
        {:skip, :no_content}

      input ->
        group = info["group"] || sample.trace_id

        promoted_from =
          Map.put(
            promoted_from(sample, run_id, opts),
            "observed_verdict",
            observed(trace, surface)
          )

        {:ok,
         %{
           "schema" => "nous.guard_case/1",
           "id" => "online-" <> sample.trace_id <> "-" <> surface,
           "kind" => "classifier",
           "surface" => surface,
           # Unlabelled until a human reviews it: the guard's own verdict is
           # never the label (it would certify the guard against itself).
           "label" => nil,
           "split" => split(group),
           "group" => group,
           "tags" => ["online"],
           "input" => input,
           "provenance" => %{
             "source" => Nous.Eval.Online.task(opts.instance),
             "license" => "proprietary",
             "public" => false,
             "redacted" => true,
             "promoted_from" => promoted_from,
             "review" => "pending"
           }
         }}
    end
  end

  defp provenance(sample, info, run_id, opts) do
    %{
      "promoted_from" => promoted_from(sample, run_id, opts),
      "redacted" => true,
      "redaction_at_capture" => info["redaction"],
      "captured_at" => info["captured_at"],
      "reviewer" => opts.reviewer
    }
  end

  defp promoted_from(sample, run_id, opts) do
    %{
      "instance" => opts.instance,
      "run_id" => run_id,
      "trace_id" => sample.trace_id,
      "redactor" => redactor_name(opts.redact),
      "reviewer" => opts.reviewer,
      "nous_version" => nous_version()
    }
  end

  defp redactor_name(fun) when is_function(fun), do: "function"

  defp redactor_name(module) do
    version = if function_exported?(module, :version, 0), do: to_string(module.version())
    %{"module" => inspect(module), "version" => version}
  end

  defp nous_version do
    case Application.spec(:nous, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  # ── inputs ─────────────────────────────────────────────────────────────────

  # The root run's first request: the last user message as a string, or the
  # user/assistant turns when it carried history.
  defp case_input(trace) do
    turns =
      for %Message{role: role} = m <- first_request(trace),
          role in [:user, :assistant],
          text = Message.extract_text(m),
          text != "",
          do: %{"role" => Atom.to_string(role), "content" => text}

    case turns do
      [] -> nil
      [%{"role" => "user", "content" => text}] -> text
      turns -> turns
    end
  end

  defp first_request(trace) do
    root = Trace.root_run_id(trace)

    case Enum.find(Trace.model_calls(trace), &(&1.agent_run_id == root)) do
      %ModelCall{messages: messages} when is_list(messages) ->
        Enum.filter(messages, &is_struct(&1, Message))

      _ ->
        []
    end
  end

  defp guard_input("user_input", trace, _gopts) do
    case trace |> first_request() |> Enum.filter(&(&1.role == :user)) |> List.last() do
      %Message{} = m -> text_input("text", Message.extract_text(m))
      nil -> nil
    end
  end

  defp guard_input("model_output", trace, _gopts) do
    root = Trace.root_run_id(trace)

    trace
    |> Trace.model_calls()
    |> Enum.filter(&(&1.agent_run_id == root and &1.outcome == :ok))
    |> List.last()
    |> case do
      %ModelCall{response: %Message{} = m} -> text_input("content", Message.extract_text(m))
      _ -> nil
    end
  end

  defp guard_input(surface, trace, gopts) when surface in ["tool_call", "tool_result"] do
    calls = Trace.tool_calls(trace, include: :all)
    tool = Keyword.get(gopts, :tool)

    case Enum.find(calls, &(is_nil(tool) or &1.name == tool)) do
      %ToolCall{name: name, arguments: args} = call when is_binary(name) and is_map(args) ->
        base = %{"tool" => %{"name" => name}, "arguments" => json(args)}
        if surface == "tool_call", do: base, else: tool_result(base, call)

      _ ->
        nil
    end
  end

  defp tool_result(base, %ToolCall{result: result}) when not is_nil(result),
    do: Map.put(base, "result", if(is_binary(result), do: result, else: json(result)))

  defp tool_result(_base, _call), do: nil

  defp text_input(key, text) when is_binary(text) and text != "", do: %{key => text}
  defp text_input(_key, _text), do: nil

  defp json(value), do: value |> Nous.Eval.Codec.encode_value() |> strip_tags()

  # Plain JSON for the dataset file: Codec tags are reduced to their text.
  defp strip_tags(%{"$atom" => name}) when is_binary(name), do: name

  defp strip_tags(%{} = map) when map_size(map) == 1 and is_map_key(map, "$opaque"),
    do: map["$opaque"]

  defp strip_tags(%{} = map), do: Map.new(map, fn {k, v} -> {k, strip_tags(v)} end)
  defp strip_tags(list) when is_list(list), do: Enum.map(list, &strip_tags/1)
  defp strip_tags(value), do: value

  defp observed(trace, surface) do
    trace
    |> Trace.guard_verdicts(scope: :tree)
    |> Enum.filter(&(to_string(&1.surface) == surface))
    |> List.last()
    |> case do
      %GuardVerdict{verdict: verdict} when is_atom(verdict) and not is_nil(verdict) ->
        Atom.to_string(verdict)

      _ ->
        nil
    end
  end

  defp split(group) do
    <<n::unsigned-64, _::binary>> = :crypto.hash(:sha256, @split_seed <> ":" <> group)
    u = n / 18_446_744_073_709_551_616

    cond do
      u < 0.4 -> "tune"
      u < 0.7 -> "holdout"
      true -> "test"
    end
  end

  # ── target file ────────────────────────────────────────────────────────────

  defp dedup_key(record) do
    {:content, CanonicalJSON.hash(Map.take(record, ["schema", "input", "surface"]))}
  end

  defp seen(lines) do
    Enum.reduce(lines, MapSet.new(), fn line, acc ->
      case JSON.decode(line) do
        {:ok, %{} = record} ->
          acc
          |> MapSet.put(dedup_key(record))
          |> put_trace(record)

        _ ->
          acc
      end
    end)
  end

  defp put_trace(acc, record) do
    from =
      get_in(record, ["metadata", "provenance", "promoted_from"]) ||
        get_in(record, ["provenance", "promoted_from"])

    case from do
      %{"trace_id" => tid} when is_binary(tid) -> MapSet.put(acc, {:trace, tid})
      _ -> acc
    end
  end

  @doc false
  # The non-blank lines of a JSONL file; a missing file has none.
  @spec read_lines(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def read_lines(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  @doc false
  # Replaces the file with `lines` through a temporary file and a rename,
  # so a reader never sees a half-written queue.
  @spec write_lines(Path.t(), [String.t()]) :: :ok | {:error, term()}
  def write_lines(path, lines) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Enum.map(lines, &[&1, ?\n])),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write_failed, path, reason}}
    end
  end

  # ── list filters ───────────────────────────────────────────────────────────

  @doc false
  @spec matches?(Sample.t(), map(), keyword()) :: boolean()
  def matches?(sample, info, opts) do
    Enum.all?(opts, fn
      {:ids, ids} -> sample.trace_id in ids
      {:outcome, outcome} -> sample.outcome == outcome
      {:verdict, verdict} -> sample.verdict == verdict
      {:rule, rule} -> rule in Map.get(info, "rules", [])
      {:score_below, {name, limit}} -> score_below?(sample, name, limit)
      _other -> true
    end)
  end

  defp score_below?(sample, name, limit) do
    Enum.any?(sample.scores, fn score ->
      score.name == name and
        match?(
          {:ok, value} when value < limit,
          Scoring.value_to_float(score.value, label_values(score))
        )
    end)
  end

  defp label_values(%{metadata: %{label_values: %{} = values}}), do: values
  defp label_values(_score), do: %{}
end
