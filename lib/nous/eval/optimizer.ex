defmodule Nous.Eval.Optimizer do
  @moduledoc """
  Optimization engine for finding optimal agent configurations.

  The optimizer runs evaluation suites with different parameter combinations
  to find configurations that maximize performance metrics.

  ## Supported Strategies

  - `:grid_search` - Exhaustive search over parameter grid
  - `:bayesian` - Bayesian optimization with TPE (Tree-structured Parzen Estimator)
  - `:random` - Random search over parameter space

  ## Example

      # Define parameter space
      params = [
        Optimizer.Parameter.float(:temperature, 0.0, 1.0, step: 0.1),
        Optimizer.Parameter.integer(:max_tokens, 100, 1000, step: 100),
        Optimizer.Parameter.choice(:model, [
          "lmstudio:ministral-3-14b-reasoning",
          "lmstudio:qwen-7b"
        ])
      ]

      # Run optimization
      {:ok, result} = Optimizer.optimize(suite, params,
        strategy: :grid_search,
        metric: :score,
        maximize: true
      )

      IO.inspect(result.best_config)
      IO.inspect(result.best_score)

  ## Bayesian Optimization

  For expensive evaluations, use Bayesian optimization which learns from
  previous trials to focus on promising regions:

      {:ok, result} = Optimizer.optimize(suite, params,
        strategy: :bayesian,
        n_trials: 50,
        metric: :score
      )

  ## Metrics

  Optimization can target different metrics:

  - `:score` - Aggregate evaluation score (default)
  - `:pass_rate` - Percentage of tests passing
  - `:latency_p50` - Median latency
  - `:latency_p95` - 95th percentile latency
  - `:total_tokens` - Token efficiency
  - `:cost` - Estimated cost

  """

  alias Nous.Eval.{Suite, Runner, SuiteResult}
  alias Nous.Eval.Optimizer.{Parameter, SearchSpace}

  @type optimization_result :: %{
          best_config: map(),
          best_score: float(),
          all_trials: [trial()],
          total_trials: non_neg_integer(),
          duration_ms: non_neg_integer(),
          strategy: atom(),
          metric: atom(),
          avg_score: float(),
          std_score: float()
        }

  @type trial :: %{
          config: map(),
          score: float(),
          metrics: map(),
          duration_ms: non_neg_integer()
        }

  @type metric ::
          :score
          | :pass_rate
          | :latency_p50
          | :latency_p95
          | :latency_p99
          | :total_tokens
          | :cost

  @doc """
  Run optimization to find best configuration.

  ## Options

    * `:strategy` - Optimization strategy (`:grid_search`, `:bayesian`, `:random`)
    * `:metric` - Metric to optimize (default: `:score`)
    * `:maximize` - Whether to maximize metric (default: `true`)
    * `:n_trials` - Max trials for bayesian/random (default: 100)
    * `:timeout` - Total timeout in ms (default: 3600000 = 1 hour)
    * `:parallel` - Run trials in parallel (default: false)
    * `:early_stop` - Stop if score reaches threshold
    * `:verbose` - Print progress (default: true)

  ## Returns

      {:ok, %{
        best_config: %{temperature: 0.3, max_tokens: 500},
        best_score: 0.95,
        all_trials: [...],
        total_trials: 50,
        duration_ms: 120000,
        strategy: :bayesian,
        metric: :score
      }}

  """
  @spec optimize(Suite.t(), [Parameter.t()], keyword()) ::
          {:ok, optimization_result()} | {:error, term()}
  def optimize(%Suite{} = suite, parameters, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :grid_search)
    metric = Keyword.get(opts, :metric, :score)
    maximize = Keyword.get(opts, :maximize, true)
    verbose = Keyword.get(opts, :verbose, true)

    # Build search space
    search_space = SearchSpace.from_parameters(parameters)

    # Get strategy module
    strategy_module = get_strategy_module(strategy)

    if verbose do
      IO.puts("\n=== Nous Optimizer ===")
      IO.puts("Strategy: #{strategy}")
      IO.puts("Metric: #{metric}")
      IO.puts("Parameters: #{length(parameters)}")
      IO.puts("Search space size: #{SearchSpace.size(search_space)}")
      IO.puts("")
    end

    start_time = System.monotonic_time(:millisecond)

    # Run optimization
    result = strategy_module.run(suite, search_space, metric, maximize, opts)

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    case result do
      {:ok, trials} ->
        # Find best trial
        {best_trial, best_score} = find_best(trials, maximize)

        # Calculate statistics
        {avg_score, std_score} = calculate_stats(trials)

        if verbose do
          IO.puts("\n=== Optimization Complete ===")
          IO.puts("Total trials: #{length(trials)}")
          IO.puts("Duration: #{Float.round(duration_ms / 1000, 1)}s")
          IO.puts("Best score: #{Float.round(best_score, 4)}")
          IO.puts("Avg score: #{Float.round(avg_score, 4)}")
          IO.puts("Best config: #{inspect(best_trial.config)}")
        end

        {:ok,
         %{
           best_config: best_trial.config,
           best_score: best_score,
           all_trials: trials,
           total_trials: length(trials),
           duration_ms: duration_ms,
           strategy: strategy,
           metric: metric,
           avg_score: avg_score,
           std_score: std_score
         }}
    end
  end

  @doc """
  Run a single trial with given configuration.
  """
  @spec run_trial(Suite.t(), map(), atom(), keyword()) :: {:ok, trial()} | {:error, term()}
  def run_trial(%Suite{} = suite, config, metric, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    # Apply config to suite
    configured_suite = apply_config(suite, config)

    # Run evaluation
    case Runner.run(configured_suite, opts) do
      {:ok, result} ->
        end_time = System.monotonic_time(:millisecond)
        score = extract_metric(result, metric)

        {:ok,
         %{
           config: config,
           score: score,
           metrics: extract_all_metrics(result),
           duration_ms: end_time - start_time
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extract a specific metric from an evaluation result.

  Returns `0.0` when the suite produced no metrics summary — which is what
  happens when every case errored, so an objective never crashes a search.
  """
  @spec extract_metric(SuiteResult.t(), metric()) :: float()
  def extract_metric(result, :score), do: result.aggregate_score || 0.0
  def extract_metric(result, :pass_rate), do: result.pass_rate || 0.0
  def extract_metric(result, :latency_p50), do: summary_value(result, :p50_latency_ms)
  def extract_metric(result, :latency_p95), do: summary_value(result, :p95_latency_ms)
  def extract_metric(result, :latency_p99), do: summary_value(result, :p99_latency_ms)
  def extract_metric(result, :total_tokens), do: summary_value(result, :total_tokens)
  def extract_metric(result, :cost), do: summary_value(result, :total_estimated_cost)
  def extract_metric(_result, _), do: 0.0

  # `%Nous.Eval.SuiteResult{}` and `%Nous.Eval.Metrics.Summary{}` are plain
  # structs and implement no Access behaviour, so `get_in/2` on them raises
  # UndefinedFunctionError rather than returning nil. Read the fields.
  defp summary_value(%{metrics_summary: nil}, _field), do: 0.0

  defp summary_value(%{metrics_summary: summary}, field) do
    case Map.get(summary, field) do
      nil -> 0.0
      value -> value / 1
    end
  end

  # Private helpers

  defp get_strategy_module(:grid_search), do: Nous.Eval.Optimizer.Strategies.GridSearch
  defp get_strategy_module(:bayesian), do: Nous.Eval.Optimizer.Strategies.Bayesian
  defp get_strategy_module(:random), do: Nous.Eval.Optimizer.Strategies.Random

  defp find_best(trials, maximize) do
    comparator = if maximize, do: &>=/2, else: &<=/2

    best =
      Enum.reduce(trials, {nil, if(maximize, do: -999_999.0, else: 999_999.0)}, fn trial,
                                                                                   {best_trial,
                                                                                    best_score} ->
        if comparator.(trial.score, best_score) do
          {trial, trial.score}
        else
          {best_trial, best_score}
        end
      end)

    best
  end

  defp apply_config(suite, config) do
    # Apply model if specified
    suite =
      if Map.has_key?(config, :model) do
        %{suite | default_model: config.model}
      else
        suite
      end

    # Apply instructions if specified
    suite =
      if Map.has_key?(config, :instructions) do
        %{suite | default_instructions: config.instructions}
      else
        suite
      end

    # Apply model settings to all test cases
    if has_model_settings?(config) do
      model_settings = extract_model_settings(config)

      updated_cases =
        Enum.map(suite.test_cases, fn tc ->
          existing = tc.agent_config[:model_settings] || %{}
          merged = Map.merge(existing, model_settings)
          updated_config = Keyword.put(tc.agent_config || [], :model_settings, merged)
          %{tc | agent_config: updated_config}
        end)

      %{suite | test_cases: updated_cases}
    else
      suite
    end
  end

  defp has_model_settings?(config) do
    Enum.any?([:temperature, :max_tokens, :top_p, :top_k], &Map.has_key?(config, &1))
  end

  defp extract_model_settings(config) do
    [:temperature, :max_tokens, :top_p, :top_k, :frequency_penalty, :presence_penalty]
    |> Enum.filter(&Map.has_key?(config, &1))
    |> Enum.map(fn key -> {key, Map.get(config, key)} end)
    |> Map.new()
  end

  defp extract_all_metrics(result) do
    %{
      score: result.aggregate_score,
      pass_rate: result.pass_rate,
      pass_count: result.pass_count,
      fail_count: result.fail_count,
      latency: latency_metrics(result.metrics_summary),
      tokens: token_metrics(result.metrics_summary),
      cost: cost_metrics(result.metrics_summary)
    }
  end

  defp latency_metrics(nil), do: %{}

  defp latency_metrics(summary) do
    %{
      mean: summary.mean_latency_ms,
      p50: summary.p50_latency_ms,
      p95: summary.p95_latency_ms,
      p99: summary.p99_latency_ms
    }
  end

  defp token_metrics(nil), do: %{}

  defp token_metrics(summary) do
    %{
      total: summary.total_tokens,
      mean: summary.mean_tokens,
      p50: summary.p50_tokens,
      p95: summary.p95_tokens,
      p99: summary.p99_tokens
    }
  end

  defp cost_metrics(nil), do: %{}

  defp cost_metrics(summary) do
    %{total: summary.total_estimated_cost, mean_per_run: summary.mean_cost_per_run}
  end

  defp calculate_stats([]), do: {0.0, 0.0}

  defp calculate_stats(trials) do
    scores = Enum.map(trials, & &1.score)
    n = length(scores)

    # Mean
    avg = Enum.sum(scores) / n

    # Standard deviation
    variance =
      scores
      |> Enum.map(fn s -> (s - avg) * (s - avg) end)
      |> Enum.sum()
      |> Kernel./(n)

    std = :math.sqrt(variance)

    {avg, std}
  end
end
