defmodule Nous.Eval.Optimizer.Strategies.Bayesian do
  @moduledoc """
  Bayesian optimization strategy inspired by TPE (Tree-structured Parzen Estimator).

  This strategy learns from previous trials to focus exploration on promising
  regions of the search space. It balances exploration (trying new areas) with
  exploitation (refining good areas).

  ## How It Works

  1. Start with random samples to build initial knowledge
  2. Split trials into "good" (above threshold) and "bad" (below threshold)
  3. Model the distribution of good vs bad configurations
  4. Sample new configurations more likely to be in "good" regions
  5. Repeat until budget exhausted

  ## Options

    * `:n_trials` - Total number of trials (default: 100)
    * `:n_initial` - Initial random trials before optimization (default: 10)
    * `:gamma` - Quantile for splitting good/bad (default: 0.25 = top 25%)
    * `:timeout` - Total timeout in ms (default: 3600000)
    * `:early_stop` - Stop if score reaches threshold
    * `:verbose` - Print progress (default: true)

  ## Example

      Optimizer.optimize(suite, params,
        strategy: :bayesian,
        n_trials: 50,
        n_initial: 10,
        metric: :score
      )

  ## When to Use

  Bayesian optimization is recommended when:
  - Evaluations are expensive (LLM API calls cost time/money)
  - You want to find good configurations with fewer trials
  - The search space is continuous or mixed
  - Some parameter combinations are likely better than others

  ## Limitations

  - More complex than random search
  - May get stuck in local optima
  - Requires enough initial samples to build good model

  """

  @behaviour Nous.Eval.Optimizer.Strategy

  alias Nous.Eval.{Suite, Optimizer}
  alias Nous.Eval.Optimizer.{SearchSpace, Parameter}

  @impl true
  def run(%Suite{} = suite, %SearchSpace{} = space, metric, maximize, opts) do
    n_trials = Keyword.get(opts, :n_trials, 100)
    n_initial = Keyword.get(opts, :n_initial, min(10, n_trials))
    gamma = Keyword.get(opts, :gamma, 0.25)

    start_time = System.monotonic_time(:millisecond)
    loop = Optimizer.trial_loop(opts, n_trials, start_time)

    if loop.verbose do
      IO.puts("Bayesian Optimization: #{n_trials} trials (#{n_initial} initial)")
    end

    # Phase 1: random exploration, to have something to model.
    initial_configs = SearchSpace.latin_hypercube_sample(space, n_initial)
    {initial_trials, _count} = Optimizer.run_trials(suite, initial_configs, metric, opts, loop)

    if should_stop?(initial_trials, loop) do
      {:ok, initial_trials}
    else
      # Phase 2: TPE-guided sampling for whatever budget is left.
      remaining = n_trials - length(initial_trials)

      if remaining > 0 do
        # Everything the recursion needs but never varies, grouped so the loop
        # keeps a workable arity.
        ctx = %{
          suite: suite,
          space: space,
          metric: metric,
          maximize: maximize,
          gamma: gamma,
          opts: opts
        }

        bayesian_trials =
          bayesian_loop(ctx, initial_trials, remaining, %{loop | index: length(initial_trials)})

        {:ok, initial_trials ++ bayesian_trials}
      else
        {:ok, initial_trials}
      end
    end
  end

  # Unlike the other strategies, each candidate depends on the trials before
  # it, so this drives `Optimizer.attempt_trial/5` itself instead of handing a
  # pre-computed list to `Optimizer.run_trials/5`.
  defp bayesian_loop(_ctx, _trials, 0, loop) do
    if loop.verbose, do: IO.puts("")
    []
  end

  defp bayesian_loop(ctx, trials, remaining, loop) do
    if Optimizer.timed_out?(loop) do
      if loop.verbose, do: IO.puts("\nTimeout reached")
      []
    else
      next_config = suggest_next(ctx.space, trials, ctx.gamma, ctx.maximize)

      case Optimizer.attempt_trial(ctx.suite, next_config, ctx.metric, ctx.opts, loop) do
        {:halt, trial} ->
          [trial]

        {:cont, trial} ->
          next_loop = %{loop | index: loop.index + 1}
          [trial | bayesian_loop(ctx, [trial | trials], remaining - 1, next_loop)]
      end
    end
  end

  # TPE-inspired sampling: sample from good region more often
  defp suggest_next(space, trials, gamma, maximize) do
    # Split trials into good and bad
    {good_trials, bad_trials} = split_trials(trials, gamma, maximize)

    # For each parameter, sample from good distribution with higher probability
    space.parameters
    |> Enum.map(fn param ->
      value = sample_parameter_tpe(param, good_trials, bad_trials)
      {param.name, value}
    end)
    |> Map.new()
  end

  # Split trials into good (top gamma %) and bad
  defp split_trials(trials, gamma, maximize) do
    sorted =
      if maximize do
        Enum.sort_by(trials, & &1.score, :desc)
      else
        Enum.sort_by(trials, & &1.score, :asc)
      end

    n_good = max(1, trunc(length(sorted) * gamma))
    {good, bad} = Enum.split(sorted, n_good)
    {good, bad}
  end

  # Sample a parameter value using TPE-inspired approach
  defp sample_parameter_tpe(param, good_trials, bad_trials) do
    good_values =
      Enum.map(good_trials, fn t -> Map.get(t.config, param.name) end) |> Enum.reject(&is_nil/1)

    bad_values =
      Enum.map(bad_trials, fn t -> Map.get(t.config, param.name) end) |> Enum.reject(&is_nil/1)

    cond do
      # Not enough data - random sample
      length(good_values) < 2 ->
        Parameter.sample(param)

      # 70% chance to sample from good region
      :rand.uniform() < 0.7 ->
        sample_from_values(param, good_values)

      # 30% chance to explore (sample from full range but avoid bad region)
      true ->
        sample_avoiding_bad(param, bad_values)
    end
  end

  # Sample near good values
  defp sample_from_values(%Parameter{type: :float} = param, values) do
    # Sample near a random good value with some noise
    base = Enum.random(values)
    range = param.max - param.min
    # 20% noise
    noise = (:rand.uniform() - 0.5) * range * 0.2
    value = base + noise
    # Clamp to valid range
    max(param.min, min(param.max, value))
  end

  defp sample_from_values(%Parameter{type: :integer} = param, values) do
    base = Enum.random(values)
    range = param.max - param.min
    noise = trunc((:rand.uniform() - 0.5) * range * 0.2)
    value = base + noise
    max(param.min, min(param.max, value))
  end

  defp sample_from_values(%Parameter{type: :choice}, values) do
    # For categorical, sample most common in good region
    values
    |> Enum.frequencies()
    |> Enum.max_by(fn {_v, count} -> count + :rand.uniform() end)
    |> elem(0)
  end

  defp sample_from_values(%Parameter{type: :bool}, values) do
    # For boolean, sample most common in good region
    true_count = Enum.count(values, & &1)
    false_count = length(values) - true_count
    if true_count > false_count, do: true, else: false
  end

  # Sample avoiding bad regions
  defp sample_avoiding_bad(%Parameter{type: type} = param, bad_values)
       when type in [:float, :integer] do
    candidate = Parameter.sample(param)

    if bad_values == [] do
      candidate
    else
      nudge_away_from(candidate, Enum.sum(bad_values) / length(bad_values), param)
    end
  end

  defp sample_avoiding_bad(%Parameter{type: :choice} = param, bad_values) do
    # Avoid most common bad choice
    if length(bad_values) > 0 do
      bad_freq = Enum.frequencies(bad_values)
      worst = bad_freq |> Enum.max_by(fn {_v, c} -> c end) |> elem(0)

      other_choices = Enum.reject(param.choices, &(&1 == worst))

      if length(other_choices) > 0 do
        Enum.random(other_choices)
      else
        Enum.random(param.choices)
      end
    else
      Enum.random(param.choices)
    end
  end

  defp sample_avoiding_bad(%Parameter{type: :bool}, bad_values) do
    if length(bad_values) > 0 do
      # Choose opposite of most common bad value
      true_count = Enum.count(bad_values, & &1)
      false_count = length(bad_values) - true_count
      if true_count > false_count, do: false, else: true
    else
      :rand.uniform() > 0.5
    end
  end

  # A candidate landing within a tenth of the parameter's span of the bad
  # region's centre gets pushed a tenth of the span the other way, clamped to
  # the parameter's range.
  defp nudge_away_from(candidate, avg_bad, param) do
    span = param.max - param.min

    cond do
      abs(candidate - avg_bad) >= span * 0.1 -> candidate
      candidate < avg_bad -> max(param.min, candidate - span * 0.1)
      true -> min(param.max, candidate + span * 0.1)
    end
  end

  defp should_stop?(trials, loop) do
    cond do
      loop.early_stop && Enum.any?(trials, fn t -> t.score >= loop.early_stop end) -> true
      Optimizer.timed_out?(loop) -> true
      true -> false
    end
  end
end
