defmodule Nous.Eval.Optimizer.Strategies.GridSearch do
  @moduledoc """
  Exhaustive grid search optimization strategy.

  Grid search evaluates all combinations of parameter values in the search space.
  Best for small search spaces where you want to guarantee finding the global optimum.

  ## Options

    * `:max_trials` - Maximum number of trials (default: unlimited)
    * `:timeout` - Total timeout in ms (default: 3600000 = 1 hour)
    * `:parallel` - Number of parallel trials (default: 1)
    * `:early_stop` - Stop if score reaches threshold
    * `:verbose` - Print progress (default: true)
    * `:shuffle` - Randomize order of configurations (default: false)

  ## Example

      Optimizer.optimize(suite, params,
        strategy: :grid_search,
        metric: :score,
        max_trials: 100,
        verbose: true
      )

  ## Limitations

  Grid search becomes impractical for large search spaces. For N parameters
  with M values each, the total combinations is M^N. Consider using
  `:random` or `:bayesian` strategies for larger spaces.

  """

  @behaviour Nous.Eval.Optimizer.Strategy

  alias Nous.Eval.{Suite, Optimizer}
  alias Nous.Eval.Optimizer.SearchSpace

  @impl true
  def run(%Suite{} = suite, %SearchSpace{} = space, metric, _maximize, opts) do
    max_trials = Keyword.get(opts, :max_trials, :infinity)
    start_time = System.monotonic_time(:millisecond)

    configs =
      space
      |> all_configs(max_trials)
      |> maybe_shuffle(Keyword.get(opts, :shuffle, false))
      |> limit(max_trials)

    loop = Optimizer.trial_loop(opts, length(configs), start_time)

    if loop.verbose do
      IO.puts("Grid Search: #{loop.total} configurations to evaluate")
    end

    {trials, _count} = Optimizer.run_trials(suite, configs, metric, opts, loop)

    if loop.verbose, do: IO.puts("")

    {:ok, trials}
  end

  defp all_configs(space, max_trials) do
    SearchSpace.grid(space)
  rescue
    # A continuous space has no enumerable grid — sample it instead.
    ArgumentError ->
      n = if max_trials == :infinity, do: 100, else: max_trials
      SearchSpace.sample_n(space, n)
  end

  defp maybe_shuffle(configs, true), do: Enum.shuffle(configs)
  defp maybe_shuffle(configs, false), do: configs

  defp limit(configs, :infinity), do: configs
  defp limit(configs, max_trials), do: Enum.take(configs, max_trials)
end
