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
    timeout = Keyword.get(opts, :timeout, 3_600_000)
    verbose = Keyword.get(opts, :verbose, true)
    early_stop = Keyword.get(opts, :early_stop)
    latin_hypercube = Keyword.get(opts, :latin_hypercube, false)

    start_time = System.monotonic_time(:millisecond)

    # Generate configurations
    configs =
      if latin_hypercube do
        SearchSpace.latin_hypercube_sample(space, n_trials)
      else
        SearchSpace.sample_n(space, n_trials)
      end

    if verbose do
      sampling = if latin_hypercube, do: "Latin Hypercube", else: "Random"
      IO.puts("#{sampling} Search: #{n_trials} trials")
    end

    # Run trials
    {trials, _} =
      Enum.reduce_while(configs, {[], 0}, fn config, {acc, idx} ->
        # Check timeout
        elapsed = System.monotonic_time(:millisecond) - start_time

        if elapsed > timeout do
          {:halt, {acc, idx}}
        else
          if verbose do
            IO.write("\rTrial #{idx + 1}/#{n_trials}")
          end

          case Optimizer.run_trial(suite, config, metric, opts) do
            {:ok, trial} ->
              # Check early stop
              if early_stop && trial.score >= early_stop do
                if verbose, do: IO.puts("\nEarly stop: score #{trial.score} >= #{early_stop}")
                {:halt, {[trial | acc], idx + 1}}
              else
                {:cont, {[trial | acc], idx + 1}}
              end

            {:error, reason} ->
              if verbose do
                IO.puts("\nTrial #{idx + 1} failed: #{inspect(reason)}")
              end

              failed_trial = %{
                config: config,
                score: 0.0,
                metrics: %{error: reason},
                duration_ms: 0
              }

              {:cont, {[failed_trial | acc], idx + 1}}
          end
        end
      end)

    if verbose, do: IO.puts("")

    {:ok, Enum.reverse(trials)}
  end
end
