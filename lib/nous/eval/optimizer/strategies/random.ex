defmodule Nous.Eval.Optimizer.Strategies.Random do
  @moduledoc """
  Random search optimization strategy.

  Random search samples configurations randomly from the search space.
  Often surprisingly effective and much faster than grid search for
  high-dimensional spaces.

  ## Options

    * `:n_trials` - Number of trials to run (default: 100)
    * `:timeout` - Total timeout in ms (default: 3600000 = 1 hour)
    * `:early_stop` - Stop if score reaches threshold
    * `:verbose` - Print progress (default: true)
    * `:latin_hypercube` - Use Latin Hypercube Sampling for better coverage (default: false)

  ## Example

      Optimizer.optimize(suite, params,
        strategy: :random,
        n_trials: 50,
        metric: :score
      )

  ## When to Use

  Random search is recommended when:
  - Search space is large (many parameters or wide ranges)
  - Some parameters are more important than others (random search explores all)
  - You have limited time/budget for optimization
  - Grid search would take too long

  ## Latin Hypercube Sampling

  Enable `latin_hypercube: true` for better coverage of the search space.
  LHS ensures samples are spread evenly across each parameter's range.

  """

  @behaviour Nous.Eval.Optimizer.Strategy

  alias Nous.Eval.{Suite, Optimizer}
  alias Nous.Eval.Optimizer.SearchSpace

  @impl true
  def run(%Suite{} = suite, %SearchSpace{} = space, metric, _maximize, opts) do
    n_trials = Keyword.get(opts, :n_trials, 100)
    latin_hypercube = Keyword.get(opts, :latin_hypercube, false)

    start_time = System.monotonic_time(:millisecond)

    configs =
      if latin_hypercube do
        SearchSpace.latin_hypercube_sample(space, n_trials)
      else
        SearchSpace.sample_n(space, n_trials)
      end

    loop = Optimizer.trial_loop(opts, n_trials, start_time)

    if loop.verbose do
      sampling = if latin_hypercube, do: "Latin Hypercube", else: "Random"
      IO.puts("#{sampling} Search: #{n_trials} trials")
    end

    {trials, _count} = Optimizer.run_trials(suite, configs, metric, opts, loop)

    if loop.verbose, do: IO.puts("")

    {:ok, trials}
  end
end
