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

  A cache file is JSON (`nous.guard_recording/1`). It is read back only
  when every item has exactly the shape this subject records; anything else
  (a tampered, truncated or foreign file) is a miss and the cases are
  recorded again, and nothing in it ever becomes an atom. Still, a cache
  file decides verdicts: keep the cache directory somewhere only you can
  write. Cache files from earlier releases (binary term format) are
  ignored and re-recorded.
  """

  alias Nous.DecisionModel.Answer
  alias Nous.Eval.Codec
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

    case cached(opts[:cache], subject, cases, fingerprint) do
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
  #
  # A cache file is the recording as JSON (`nous.guard_recording/1`), read
  # back only against the subject and cases being recorded: every item must
  # have exactly the shape `record_case/3` produces for that subject, or the
  # whole file is a miss and the recording is made again. Atoms are never
  # created from it. Cases are not stored; an item names its case by id and
  # the case given to `record/3` is used.

  @cache_schema "nous.guard_recording/1"
  @floors %{"allow" => :allow, "escalate" => :escalate, "deny" => :deny}
  @canaries %{"passed" => :passed, "failed" => :failed}
  @result_severities %{"safe" => :safe, "suspicious" => :suspicious, "blocked" => :blocked}
  @answer_types %{"noul" => :noul, "choice" => :choice, "score" => :score}
  @answer_keys ~w(type noul choice score confidence probabilities)
  @item_keys ~w(case_id decision pattern strategies error)

  defp cached(nil, _subject, _cases, _fingerprint), do: :miss

  defp cached(dir, subject, cases, fingerprint) do
    with {:ok, text} <- File.read(cache_path(dir, fingerprint)),
         {:ok, data} <- JSON.decode(text),
         {:ok, recording} <- decode_cache(data, subject, cases, fingerprint) do
      {:ok, recording}
    else
      _ -> :miss
    end
  end

  defp store(nil, _recording), do: :ok

  defp store(dir, recording) do
    path = cache_path(dir, recording.fingerprint)
    # `JSON` keeps `1.0` a float, so a cached recording replays identically.
    json = JSON.encode!(encode_cache(recording))

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path <> ".tmp", json),
         :ok <- File.rename(path <> ".tmp", path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Nous.Eval.Guard: could not cache a recording in #{dir}: #{inspect(reason)}"
        )
    end
  end

  defp cache_path(dir, "sha256:" <> hex), do: Path.join(dir, hex <> ".guard_recording.json")

  defp encode_cache(%__MODULE__{} = r) do
    %{
      "schema" => @cache_schema,
      "kind" => Atom.to_string(r.kind),
      "surface" => Atom.to_string(r.surface),
      "fingerprint" => r.fingerprint,
      "items" => Enum.map(r.items, &encode_item/1)
    }
  end

  defp encode_item(item) do
    %{
      "case_id" => item.case.id,
      "decision" => item.decision && encode_decision(item.decision),
      "pattern" => item.pattern && encode_result(item.pattern),
      "strategies" =>
        item.strategies &&
          Enum.map(item.strategies, fn
            {:ok, result} -> %{"ok" => encode_result(result)}
            {:error, reason} -> %{"error" => Codec.encode_value(reason)}
          end),
      "error" => Codec.encode_value(item.error)
    }
  end

  defp encode_decision(%{chunks: chunks, floor: floor}) do
    %{
      "floor" => Atom.to_string(floor),
      "chunks" =>
        Enum.map(chunks, fn chunk ->
          %{
            "canary" => chunk.canary && Atom.to_string(chunk.canary),
            "answers" =>
              chunk.answers
              |> Enum.map(fn {id, answer} -> [Codec.encode_value(id), encode_answer(answer)] end)
              |> Enum.sort()
          }
        end)
    }
  end

  defp encode_answer(%Answer{} = a) do
    %{
      "type" => Atom.to_string(a.type),
      "noul" => a.noul,
      "choice" => Codec.encode_value(a.choice),
      "score" => a.score,
      "confidence" => a.confidence,
      "probabilities" => Enum.map(a.probabilities, fn {id, p} -> [Codec.encode_value(id), p] end)
    }
  end

  defp encode_result(%Result{} = r) do
    %{
      "severity" => Atom.to_string(r.severity),
      "reason" => r.reason,
      "strategy" => r.strategy && Atom.to_string(r.strategy),
      "metadata" => Codec.encode_value(r.metadata)
    }
  end

  defp decode_cache(
         %{"schema" => @cache_schema, "fingerprint" => fingerprint, "items" => items} = data,
         %Subject{} = s,
         cases,
         fingerprint
       )
       when is_list(items) and length(items) == length(cases) do
    if data["kind"] == Atom.to_string(s.kind) and data["surface"] == Atom.to_string(s.surface) do
      {:ok,
       %__MODULE__{
         kind: s.kind,
         surface: s.surface,
         fingerprint: fingerprint,
         items: items |> Enum.zip(cases) |> Enum.map(fn {i, c} -> decode_item!(i, c, s) end)
       }}
    else
      :error
    end
  catch
    :invalid_cache -> :error
  end

  defp decode_cache(_data, _subject, _cases, _fingerprint), do: :error

  defp decode_item!(%{"case_id" => id} = item, %Case{id: id} = c, s)
       when map_size(item) == length(@item_keys) do
    unless Enum.all?(@item_keys, &Map.has_key?(item, &1)), do: throw(:invalid_cache)
    error = value!(item["error"])

    case s.kind do
      :decision_guard ->
        decision = if item["decision"], do: decode_decision!(item["decision"], s)
        pattern = if item["pattern"], do: decode_result!(item["pattern"], s)

        # Exactly one of a recorded decision and an error.
        unless item["strategies"] == nil and is_nil(decision) != is_nil(error),
          do: throw(:invalid_cache)

        %{case: c, decision: decision, pattern: pattern, strategies: nil, error: error}

      :input_guard ->
        strategies = decode_strategies!(item["strategies"], s)

        first_error =
          Enum.find_value(strategies, fn
            {:error, reason} -> reason
            _ -> nil
          end)

        unless item["decision"] == nil and item["pattern"] == nil and error == first_error,
          do: throw(:invalid_cache)

        %{case: c, decision: nil, pattern: nil, strategies: strategies, error: error}
    end
  end

  defp decode_item!(_item, _case, _subject), do: throw(:invalid_cache)

  defp decode_decision!(%{"floor" => floor, "chunks" => chunks} = d, s)
       when map_size(d) == 2 and is_list(chunks) do
    questions = Map.new(s.decision.questions, &{Codec.encode_value(&1.id), &1})
    %{floor: lookup!(@floors, floor), chunks: Enum.map(chunks, &decode_chunk!(&1, questions))}
  end

  defp decode_decision!(_decision, _subject), do: throw(:invalid_cache)

  defp decode_chunk!(%{"canary" => canary, "answers" => answers} = chunk, questions)
       when map_size(chunk) == 2 and is_list(answers) do
    decoded =
      Map.new(answers, fn
        [id, answer] ->
          case Map.fetch(questions, id) do
            {:ok, q} -> {q.id, decode_answer!(answer, q)}
            :error -> throw(:invalid_cache)
          end

        _ ->
          throw(:invalid_cache)
      end)

    if map_size(decoded) != length(answers), do: throw(:invalid_cache)
    %{answers: decoded, canary: if(canary, do: lookup!(@canaries, canary))}
  end

  defp decode_chunk!(_chunk, _questions), do: throw(:invalid_cache)

  defp decode_answer!(%{"probabilities" => probabilities} = a, q)
       when map_size(a) == length(@answer_keys) and is_list(probabilities) do
    unless Enum.all?(@answer_keys, &Map.has_key?(a, &1)), do: throw(:invalid_cache)
    type = lookup!(@answer_types, a["type"])
    if type != q.type, do: throw(:invalid_cache)

    %Answer{
      type: type,
      noul: number!(a["noul"]),
      choice: value!(a["choice"]),
      score: number!(a["score"]),
      confidence: number!(a["confidence"]),
      probabilities:
        Enum.map(probabilities, fn
          [id, p] when is_number(p) -> {value!(id), p}
          _ -> throw(:invalid_cache)
        end)
    }
  end

  defp decode_answer!(_answer, _question), do: throw(:invalid_cache)

  defp decode_strategies!(entries, s)
       when is_list(entries) and length(entries) == length(s.strategies) do
    Enum.map(entries, fn
      %{"ok" => result} = entry when map_size(entry) == 1 -> {:ok, decode_result!(result, s)}
      %{"error" => reason} = entry when map_size(entry) == 1 -> {:error, value!(reason)}
      _ -> throw(:invalid_cache)
    end)
  end

  defp decode_strategies!(_entries, _subject), do: throw(:invalid_cache)

  # A strategy module is matched against the subject's own modules (and
  # Pattern, DecisionGuard's ensemble), never turned into an atom.
  defp decode_result!(%{"reason" => reason} = r, s)
       when map_size(r) == 4 and (is_binary(reason) or is_nil(reason)) do
    unless Enum.all?(~w(severity strategy metadata), &Map.has_key?(r, &1)),
      do: throw(:invalid_cache)

    %{"severity" => severity, "strategy" => strategy, "metadata" => meta} = r

    modules =
      Map.new([Pattern | Enum.map(s.strategies, &elem(&1, 0))], &{Atom.to_string(&1), &1})

    metadata =
      case value!(meta) do
        %{} = map -> map
        _ -> throw(:invalid_cache)
      end

    %Result{
      severity: lookup!(@result_severities, severity),
      reason: reason,
      strategy: if(strategy, do: lookup!(modules, strategy)),
      metadata: metadata
    }
  end

  defp decode_result!(_result, _subject), do: throw(:invalid_cache)

  defp lookup!(table, key) when is_binary(key) do
    case Map.fetch(table, key) do
      {:ok, value} -> value
      :error -> throw(:invalid_cache)
    end
  end

  defp lookup!(_table, _key), do: throw(:invalid_cache)

  defp number!(v) when is_number(v) or is_nil(v), do: v
  defp number!(_v), do: throw(:invalid_cache)

  defp value!(v) do
    case Codec.decode_value(v) do
      {:ok, value} -> value
      {:error, _} -> throw(:invalid_cache)
    end
  end

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
