defmodule Nous.Eval.Guard.Recording do
  @moduledoc """
  A guard's recorded answers on a set of classifier cases, and the verdicts
  they replay to under any band or threshold setting.

  `record/3` asks the guard's model once per case:

    * DecisionGuard: `Nous.Hook.Decision.verdict/3` with `record:
      :all_chunks` (every chunk classified, no stop at the first deny), plus
      the `Pattern` verdict when the ensemble runs. A model error is kept as
      the case's error.
    * InputGuard: every strategy's `check/3` result, or the error that
      dropped it. `Semantic` records `top_similarity` on every verdict, so its
      threshold replays in both directions; `Pattern` and `LLMJudge` have no
      score and replay as the fixed operating point they were recorded at.

  `outcomes/2` replays the recording under a subject (the recorded one, or
  the same guard with other bands / thresholds): `Nous.Hook.Decision.replay/2`
  per case, re-aggregated with the ensemble
  (`Nous.Plugins.InputGuard.Engine.aggregate/3`). Bands never reach the
  model, so a sweep costs no model calls and is exact.

  ## Errors

  A case whose model call failed replays to the guard's `:on_error` verdict
  (DecisionGuard) or the fail-closed verdict (InputGuard, a dropped
  strategy: `:deny`), with `error?: true`. Reports count errors in their own
  row and never as a deny.

  ## Cache

  With `cache: dir`, a recording is stored under its fingerprint
  (`Nous.Eval.Guard.Subject.recording_fingerprint/3`: model, questions, state
  builder, chunking, cases and tool descriptions, not the bands) and served
  from there by the next `record/3` with the same fingerprint, so a baseline
  is recorded once however many candidates are compared with it.
  """

  alias Nous.Eval.Guard.{Case, Subject}
  alias Nous.Hook.Decision
  alias Nous.Plugins.InputGuard.{Engine, Result}
  alias Nous.Plugins.InputGuard.Strategies.{Pattern, Semantic}

  require Logger

  @verdicts %{safe: :allow, suspicious: :escalate, blocked: :deny}
  @severities %{allow: :safe, escalate: :suspicious, deny: :blocked}
  @rank %{allow: 0, escalate: 1, deny: 2}

  @type item :: %{
          case: Case.t(),
          decision: Decision.recording() | nil,
          pattern: Result.t() | nil,
          strategies: [{:ok, Result.t()} | {:error, term()}] | nil,
          error: term() | nil
        }

  @type t :: %__MODULE__{
          kind: Subject.kind(),
          surface: Case.surface(),
          fingerprint: String.t(),
          items: [item()]
        }

  @enforce_keys [:kind, :surface, :fingerprint]
  defstruct [:kind, :surface, :fingerprint, items: []]

  @typedoc """
  One case under one guard setting: its verdict (`:allow | :escalate |
  :deny`, after the error policy), whether it errored, and its scalar risk
  score (the largest probability any band read; Semantic's top similarity;
  `nil` without one).
  """
  @type outcome :: %{
          id: String.t(),
          label: Case.label() | nil,
          split: Case.split() | nil,
          severity: :normal | :critical,
          group: String.t(),
          tags: [String.t()],
          category: String.t() | nil,
          certifiable?: boolean(),
          verdict: :allow | :escalate | :deny,
          error?: boolean(),
          score: float() | nil
        }

  @doc """
  Records `subject` on `cases` (classifier cases of the subject's surface;
  others are ignored).

  Options: `:tools` (tool descriptions for cases without one, see
  `Nous.Eval.Guard.Subject`), `:cache` (a directory, see the moduledoc),
  `:max_concurrency` (default `4`).
  """
  @spec record(Subject.t(), [Case.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def record(%Subject{} = subject, cases, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    cases = Enum.filter(cases, &(&1.kind == :classifier and &1.surface == subject.surface))
    fingerprint = Subject.recording_fingerprint(subject, cases, tools)

    case cached(opts[:cache], fingerprint) do
      {:ok, recording} ->
        {:ok, recording}

      :miss ->
        items =
          cases
          |> Task.async_stream(&record_case(subject, &1, tools),
            max_concurrency: Keyword.get(opts, :max_concurrency, 4),
            timeout: :infinity,
            ordered: true
          )
          |> Enum.map(fn {:ok, item} -> item end)

        recording = %__MODULE__{
          kind: subject.kind,
          surface: subject.surface,
          fingerprint: fingerprint,
          items: items
        }

        store(opts[:cache], recording)
        {:ok, recording}
    end
  end

  defp record_case(%Subject{kind: :decision_guard} = s, c, tools) do
    {pattern, input} =
      case Subject.state(s, c, tools) do
        {:text, text} ->
          state = Nous.Plugins.DecisionGuard.Packs.UserInput.state(%{content: text}, %{})
          {if(s.pattern_ensemble, do: pattern(text)), state}

        {:state, state} ->
          {nil, state}
      end

    case safe(fn ->
           Decision.verdict(s.decision, input, record: :all_chunks, timeout: s.timeout)
         end) do
      {:ok, _verdict, info} ->
        %{
          case: c,
          decision: Map.take(info, [:chunks, :floor]),
          pattern: pattern,
          strategies: nil,
          error: nil
        }

      {:error, reason, _info} ->
        %{case: c, decision: nil, pattern: pattern, strategies: nil, error: reason}

      {:raised, reason} ->
        %{case: c, decision: nil, pattern: pattern, strategies: nil, error: reason}
    end
  end

  defp record_case(%Subject{kind: :input_guard} = s, c, tools) do
    {:text, text} = Subject.state(s, c, tools)

    results =
      Enum.map(s.strategies, fn {mod, opts} ->
        case safe(fn -> mod.check(text, opts, nil) end) do
          {:ok, %Result{} = result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
          {:raised, reason} -> {:error, reason}
          other -> {:error, {:invalid_result, other}}
        end
      end)

    error =
      Enum.find_value(results, fn
        {:error, reason} -> reason
        _ -> nil
      end)

    %{case: c, decision: nil, pattern: nil, strategies: results, error: error}
  end

  defp pattern(text) do
    case safe(fn -> Pattern.check(text, [], nil) end) do
      {:ok, %Result{} = result} -> result
      _ -> nil
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:raised, e}
  catch
    kind, reason -> {:raised, {kind, reason}}
  end

  # ── cache ─────────────────────────────────────────────────────────────────

  defp cached(nil, _fingerprint), do: :miss

  defp cached(dir, fingerprint) do
    with {:ok, binary} <- File.read(cache_path(dir, fingerprint)),
         %__MODULE__{fingerprint: ^fingerprint} = recording <- decode(binary) do
      {:ok, recording}
    else
      _ -> :miss
    end
  end

  # `:safe` refuses to create atoms: a tampered or foreign cache file cannot
  # grow the atom table, it is just a miss.
  defp decode(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> nil
  end

  defp store(nil, _recording), do: :ok

  defp store(dir, recording) do
    path = cache_path(dir, recording.fingerprint)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path <> ".tmp", :erlang.term_to_binary(recording)),
         :ok <- File.rename(path <> ".tmp", path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Nous.Eval.Guard: could not cache a recording in #{dir}: #{inspect(reason)}"
        )
    end
  end

  defp cache_path(dir, "sha256:" <> hex), do: Path.join(dir, hex <> ".guard_recording")

  # ── replay ────────────────────────────────────────────────────────────────

  @doc """
  Every recorded case's `t:outcome/0` under `subject` (which must be the
  recorded guard, with any bands / thresholds).
  """
  @spec outcomes(t(), Subject.t()) :: [outcome()]
  def outcomes(
        %__MODULE__{kind: kind, surface: surface} = recording,
        %Subject{kind: kind, surface: surface} = s
      ) do
    Enum.map(recording.items, &outcome(s, &1))
  end

  defp outcome(s, item) do
    {verdict, error?, score} = replay(s, item)
    c = item.case

    %{
      id: c.id,
      surface: c.surface,
      label: c.label,
      split: c.split,
      severity: c.severity,
      group: c.group,
      tags: c.tags,
      category: c.category,
      certifiable?: Case.certifiable?(c),
      verdict: verdict,
      error?: error?,
      score: score
    }
  end

  defp replay(%Subject{kind: :decision_guard} = s, %{error: nil} = item) do
    case Decision.replay(s.decision, item.decision) do
      {:ok, verdict, _info} ->
        {with_pattern(s, verdict, item.pattern), false, risk(s.decision, item.decision.chunks)}

      {:error, _reason} ->
        {with_pattern(s, s.on_error, item.pattern), true, nil}
    end
  end

  defp replay(%Subject{kind: :decision_guard} = s, item),
    do: {with_pattern(s, s.on_error, item.pattern), true, nil}

  defp replay(%Subject{kind: :input_guard} = s, item) do
    results =
      s.strategies
      |> Enum.zip(item.strategies)
      |> Enum.flat_map(fn
        {{mod, opts}, {:ok, result}} -> [resolve(mod, opts, result)]
        {_strategy, {:error, _}} -> []
      end)

    dropped = length(s.strategies) - length(results)
    aggregated = Engine.aggregate(results, length(s.strategies), %{aggregation: s.aggregation})

    verdict =
      if dropped > 0 and s.fail_closed and aggregated.severity != :blocked,
        do: :deny,
        else: Map.fetch!(@verdicts, aggregated.severity)

    {verdict, dropped > 0, semantic_score(results)}
  end

  # A recorded Semantic result replays at the subject's threshold.
  defp resolve(Semantic, opts, %Result{metadata: %{top_similarity: sim}} = result) do
    %{result | severity: Semantic.severity(sim, Keyword.get(opts, :threshold, 0.85))}
  end

  defp resolve(_mod, _opts, result), do: result

  defp semantic_score(results) do
    Enum.find_value(results, fn
      %Result{strategy: Semantic, metadata: %{top_similarity: sim}} when is_number(sim) -> sim / 1
      _ -> nil
    end)
  end

  # DecisionGuard's user-input surface runs Pattern beside the model under
  # `:any`, so a Pattern hit raises the verdict.
  defp with_pattern(%Subject{pattern_ensemble: true}, verdict, %Result{} = pattern) do
    model = %Result{severity: Map.fetch!(@severities, verdict)}
    Map.fetch!(@verdicts, Engine.aggregate([model, pattern], 2, %{aggregation: :any}).severity)
  end

  defp with_pattern(_subject, verdict, _pattern), do: verdict

  @doc false
  # The item's scalar risk: the largest probability any band of `d` reads in
  # any chunk; nil when nothing was classified.
  @spec risk(Decision.t(), [Decision.chunk()]) :: float() | nil
  def risk(d, chunks) do
    chunks
    |> Enum.flat_map(fn chunk ->
      case Decision.band_readings(d, chunk.answers) do
        {:ok, readings} -> Enum.map(readings, &elem(&1, 2))
        {:error, _} -> []
      end
    end)
    |> Enum.max(fn -> nil end)
  end

  @doc false
  @spec worst(atom(), atom()) :: atom()
  def worst(a, b), do: if(@rank[a] >= @rank[b], do: a, else: b)
end
