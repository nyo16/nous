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
    timeout = Keyword.get(opts, :timeout, 3_600_000)
    verbose = Keyword.get(opts, :verbose, true)
    shuffle = Keyword.get(opts, :shuffle, false)
    early_stop = Keyword.get(opts, :early_stop)

    start_time = System.monotonic_time(:millisecond)

    # Generate all configurations
    configs =
      try do
        SearchSpace.grid(space)
      rescue
        ArgumentError ->
          # Infinite space - use sampling instead
          n = if max_trials == :infinity, do: 100, else: max_trials
          SearchSpace.sample_n(space, n)
      end

    # Optionally shuffle
    configs = if shuffle, do: Enum.shuffle(configs), else: configs

    # Limit to max_trials
    configs =
      if max_trials != :infinity do
        Enum.take(configs, max_trials)
      else
        configs
      end

    total = length(configs)

    if verbose do
      IO.puts("Grid Search: #{total} configurations to evaluate")
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
            IO.write("\rTrial #{idx + 1}/#{total}")
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
              # Log error but continue
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
