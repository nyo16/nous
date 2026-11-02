defmodule Nous.Eval.Scoring do
  @moduledoc """
  Runs a sample's scorers and composes their results into a verdict.

      {:ok, scorers} = Nous.Eval.Scoring.init(specs)
      %{verdict: verdict, case_score: score} = Nous.Eval.Scoring.score(scorers, input)

  `init/1` calls every scorer's `c:Nous.Eval.Scorer.init/1` once, so bad
  options fail the eval before any agent runs. `score/3` runs each scorer in
  its own task under `Nous.TaskSupervisor` with a time limit; a scorer that
  raises, throws, exits or times out becomes a `Nous.Eval.ScorerError` and
  never discards another scorer's result.

  ## Result validation

  Every `Nous.Eval.Score` is checked, never coerced: the name must be a
  string, `passed?` a boolean, and the value `:pass`, `:fail`,
  `{:label, string}` or a float in `0.0..1.0`. A float outside that range is
  a `:non_finite` error, any other shape `:invalid_config`. A required
  scorer that skips without being declared `skippable: true` is an
  `:invalid_config` error: "the gate did not look" must not read as "the
  gate passed".

  ## Verdict

  Scores inherit `required` and `weight` from the `Nous.Eval.Scorer.Spec`
  that declared their scorer (a scorer emitting several scores applies its
  declaration to each).

    1. `:error` if any scorer returned an error
    2. `:fail` if any required scorer's score has `passed?: false`
    3. `:fail` if the soft scores (`required: false`, `weight > 0`) exist
       and their weighted mean is below the threshold (the case's
       `threshold`, default `0.5`; `Nous.Eval.run/2` logs one warning per
       run naming the soft-scored cases that rely on the default)
    4. `:pass` otherwise

  `weight: 0` tracks a metric without affecting the verdict. Skipped soft
  scorers are left out of the mean, as are labels without a float mapping
  (see `value_to_float/2`).

  `case_score` is the gated objective for optimizers: `nil` on `:error`,
  `0.0` when a required score failed, else the soft weighted mean, or `1.0`
  without soft scores. It ignores the threshold.
  """

  alias Nous.Eval.{Case, Score, ScoreInput, ScorerError}
  alias Nous.Eval.Scorer.Spec

  defmodule Prepared do
    @moduledoc """
    A scorer ready to run: its `Nous.Eval.Scorer.Spec`, the config its
    `c:Nous.Eval.Scorer.init/1` returned, its `id` and its `kind`. Built by
    `Nous.Eval.Scoring.init/1`.
    """

    @type t :: %__MODULE__{
            spec: Nous.Eval.Scorer.Spec.t(),
            config: term(),
            id: String.t(),
            kind: :deterministic | :model_graded
          }

    @enforce_keys [:spec, :config, :id, :kind]
    defstruct [:spec, :config, :id, :kind]
  end

  @type result :: %{
          scores: [Score.t()],
          scorer_errors: [ScorerError.t()],
          skipped: [{String.t(), String.t()}],
          verdict: :pass | :fail | :error,
          case_score: float() | nil
        }

  @default_timeouts %{deterministic: 5_000, model_graded: 60_000}
  @default_threshold 0.5

  @doc """
  Initializes scorer specs. Calls each scorer's `c:Nous.Eval.Scorer.init/1`
  once and stops at the first failure with `{:error, {module, reason}}`.
  """
  @spec init([Spec.t()]) :: {:ok, [Prepared.t()]} | {:error, {module(), term()}}
  def init(specs) when is_list(specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case prepare(spec) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, module, reason} -> {:halt, {:error, {module, reason}}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp prepare(%Spec{module: module} = spec) do
    with :ok <- check_module(module),
         :ok <- check_composition(spec),
         {:ok, config} <- call_init(module, spec.opts) do
      {:ok, %Prepared{spec: spec, config: config, id: module.id(), kind: kind_of(module)}}
    else
      {:error, reason} -> {:error, module, reason}
    end
  end

  defp prepare(other), do: {:error, nil, {:not_a_spec, other}}

  defp check_module(module) do
    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, :init, 1) and function_exported?(module, :score, 2) and
         function_exported?(module, :id, 0) do
      :ok
    else
      {:error, :not_a_scorer}
    end
  end

  defp check_composition(%Spec{
         required: required,
         skippable: skippable,
         weight: weight,
         opts: opts
       }) do
    cond do
      not is_boolean(required) -> {:error, {:invalid_required, required}}
      not is_boolean(skippable) -> {:error, {:invalid_skippable, skippable}}
      not (is_number(weight) and weight >= 0) -> {:error, {:invalid_weight, weight}}
      not Keyword.keyword?(opts) -> {:error, {:invalid_opts, opts}}
      true -> :ok
    end
  end

  defp call_init(module, opts) do
    case module.init(opts) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_init_return, other}}
    end
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  end

  defp kind_of(module) do
    if function_exported?(module, :kind, 0) and module.kind() == :model_graded,
      do: :model_graded,
      else: :deterministic
  end

  @doc """
  Scores one sample with initialized scorers and composes the verdict.

  Options:

    * `:timeout` - per-scorer limit in ms, either one integer for every
      scorer or `%{deterministic: ms, model_graded: ms}` (default 5 000 ms
      deterministic, 60 000 ms model-graded)
    * `:threshold` - overrides the case's soft-group threshold
    * `:supervisor` - the `Task.Supervisor` to run scorers under (default
      `Nous.TaskSupervisor`)

  Returns every score, scorer error and skip (`{scorer_id, reason}`), the
  verdict and the gated `case_score`.
  """
  @spec score([Prepared.t()], ScoreInput.t(), keyword()) :: result()
  def score(prepared, %ScoreInput{} = input, opts \\ []) when is_list(prepared) do
    timeouts = timeouts(Keyword.get(opts, :timeout))
    supervisor = Keyword.get(opts, :supervisor, Nous.TaskSupervisor)
    threshold = threshold(Keyword.get(opts, :threshold), input.case)

    prepared
    |> Enum.map(fn %Prepared{} = p ->
      task = Task.Supervisor.async_nolink(supervisor, fn -> run_scorer(p, input) end)
      {p, task, System.monotonic_time(:millisecond) + Map.fetch!(timeouts, p.kind)}
    end)
    |> Enum.map(fn {p, task, deadline} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      outcome =
        case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
          {:ok, returned} -> classify(p, returned)
          {:exit, reason} -> {:error, error(p, :raised, "exited: " <> inspect(reason))}
          nil -> {:error, error(p, :timeout, "exceeded #{Map.fetch!(timeouts, p.kind)} ms")}
        end

      {p, outcome}
    end)
    |> compose(threshold)
  end

  defp timeouts(nil), do: @default_timeouts
  defp timeouts(ms) when is_integer(ms) and ms > 0, do: %{deterministic: ms, model_graded: ms}

  defp timeouts(%{} = map) do
    Enum.reduce(map, @default_timeouts, fn
      {kind, ms}, acc
      when kind in [:deterministic, :model_graded] and is_integer(ms) and ms > 0 ->
        Map.put(acc, kind, ms)

      other, _acc ->
        raise ArgumentError, "invalid scorer timeout #{inspect(other)}"
    end)
  end

  defp timeouts(other), do: raise(ArgumentError, "invalid scorer timeout #{inspect(other)}")

  defp threshold(t, _case) when is_number(t), do: t / 1
  defp threshold(nil, %Case{threshold: t}) when is_number(t), do: t / 1
  defp threshold(nil, _case), do: @default_threshold

  # Runs inside the task. Catching here keeps a raising scorer from
  # producing a crash report and lets the error carry the exception text.
  defp run_scorer(%Prepared{spec: %Spec{module: module}, config: config}, input) do
    module.score(input, config)
  rescue
    exception -> {:__raised__, Exception.format_banner(:error, exception)}
  catch
    kind, reason -> {:__raised__, Exception.format_banner(kind, reason)}
  end

  defp classify(p, {:__raised__, banner}), do: {:error, error(p, :raised, banner)}
  defp classify(p, {:ok, %Score{} = score}), do: validate_scores(p, [score])
  defp classify(p, {:ok, [_ | _] = scores}), do: validate_scores(p, scores)

  defp classify(%Prepared{spec: spec} = p, {:skip, reason}) when is_binary(reason) do
    if spec.required and not spec.skippable,
      do: {:error, error(p, :invalid_config, "required scorer skipped: " <> reason)},
      else: {:skip, reason}
  end

  defp classify(p, {:error, %ScorerError{} = e}) do
    if e.kind in ScorerError.kinds() do
      {:error, %ScorerError{e | scorer: e.scorer || p.id, details: e.details || %{}}}
    else
      {:error, error(p, :invalid_config, "unknown scorer error kind #{inspect(e.kind)}")}
    end
  end

  defp classify(p, other),
    do: {:error, error(p, :invalid_config, "invalid scorer result: " <> inspect(other, limit: 5))}

  defp validate_scores(p, scores) do
    Enum.reduce_while(scores, {:scores, []}, fn score, {:scores, acc} ->
      case validate_score(score) do
        :ok -> {:cont, {:scores, [score | acc]}}
        {kind, reason} -> {:halt, {:error, error(p, kind, reason)}}
      end
    end)
    |> case do
      {:scores, valid} -> {:scores, Enum.reverse(valid)}
      error -> error
    end
  end

  defp validate_score(%Score{name: name, passed?: passed?, value: value} = score) do
    cond do
      not is_binary(name) ->
        {:invalid_config, "score name must be a string"}

      not is_boolean(passed?) ->
        {:invalid_config, "score #{name}: passed? must be a boolean"}

      not (is_map(score.details) and is_map(score.metadata)) ->
        {:invalid_config, "score #{name}: details/metadata must be maps"}

      true ->
        validate_value(name, value)
    end
  end

  defp validate_score(other), do: {:invalid_config, "not a score: " <> inspect(other, limit: 5)}

  defp validate_value(_name, value) when value in [:pass, :fail], do: :ok
  defp validate_value(_name, {:label, label}) when is_binary(label), do: :ok

  defp validate_value(_name, value) when is_float(value) and value >= 0.0 and value <= 1.0,
    do: :ok

  defp validate_value(name, value)
       when is_float(value) or value in [:nan, :infinity, :neg_infinity],
       do:
         {:non_finite, "score #{name}: value #{inspect(value)} is not a finite float in 0.0..1.0"}

  defp validate_value(name, value),
    do: {:invalid_config, "score #{name}: invalid value #{inspect(value, limit: 5)}"}

  defp error(%Prepared{id: id}, kind, reason),
    do: %ScorerError{scorer: id, kind: kind, reason: reason}

  # ── composition ────────────────────────────────────────────────────────────

  defp compose(outcomes, threshold) do
    scores = for {_p, {:scores, scores}} <- outcomes, score <- scores, do: score
    errors = for {_p, {:error, error}} <- outcomes, do: error
    skipped = for {p, {:skip, reason}} <- outcomes, do: {p.id, reason}

    gate_failed? =
      Enum.any?(outcomes, fn
        {%Prepared{spec: %Spec{required: true}}, {:scores, scores}} ->
          Enum.any?(scores, &(not &1.passed?))

        _ ->
          false
      end)

    soft =
      for {%Prepared{spec: %Spec{required: false, weight: weight}}, {:scores, scores}} <-
            outcomes,
          weight > 0,
          score <- scores,
          {:ok, value} <- [value_to_float(score.value, label_values(score))],
          do: {weight, value}

    soft_mean = weighted_mean(soft)

    {verdict, case_score} =
      cond do
        errors != [] -> {:error, nil}
        gate_failed? -> {:fail, 0.0}
        soft_mean == nil -> {:pass, 1.0}
        soft_mean < threshold -> {:fail, soft_mean}
        true -> {:pass, soft_mean}
      end

    %{
      scores: scores,
      scorer_errors: errors,
      skipped: skipped,
      verdict: verdict,
      case_score: case_score
    }
  end

  defp weighted_mean([]), do: nil

  defp weighted_mean(pairs) do
    {sum, weights} = Enum.reduce(pairs, {0.0, 0}, fn {w, v}, {s, ws} -> {s + w * v, ws + w} end)
    sum / weights
  end

  defp label_values(%Score{metadata: %{label_values: %{} = values}}), do: values
  defp label_values(_score), do: %{}

  @doc """
  Converts a score value to a float for aggregation.

  `:pass` is `1.0`, `:fail` is `0.0`, a float is itself, and
  `{:label, label}` is `label_values[label]` when the scorer declared a
  mapping (a scorer emitting labels puts it in the score's
  `metadata.label_values`). A label without a mapping returns `:error`: it
  is reported as a distribution, not averaged.

      iex> Nous.Eval.Scoring.value_to_float(:pass)
      {:ok, 1.0}
      iex> Nous.Eval.Scoring.value_to_float({:label, "good"}, %{"good" => 0.75})
      {:ok, 0.75}
      iex> Nous.Eval.Scoring.value_to_float({:label, "odd"}, %{"good" => 0.75})
      :error
  """
  @spec value_to_float(Score.value(), %{optional(String.t()) => number()}) ::
          {:ok, float()} | :error
  def value_to_float(value, label_values \\ %{})
  def value_to_float(:pass, _label_values), do: {:ok, 1.0}
  def value_to_float(:fail, _label_values), do: {:ok, 0.0}
  def value_to_float(value, _label_values) when is_float(value), do: {:ok, value}

  def value_to_float({:label, label}, label_values) when is_map(label_values) do
    case Map.fetch(label_values, label) do
      {:ok, number} when is_number(number) -> {:ok, number / 1}
      _ -> :error
    end
  end

  def value_to_float(_value, _label_values), do: :error
end
