defmodule Mix.Tasks.Nous.Optimize do
  @moduledoc """
  Run parameter optimization for Nous agent configurations.

  ## Usage

      # Optimize with default parameters (temperature, max_tokens)
      mix nous.optimize --suite test/eval/suites/basic.yaml

      # Use different optimization strategy
      mix nous.optimize --suite basic.yaml --strategy bayesian
      mix nous.optimize --suite basic.yaml --strategy random
      mix nous.optimize --suite basic.yaml --strategy grid_search

      # Configure trials and timeout
      mix nous.optimize --suite basic.yaml --trials 50 --timeout 1800000

      # Optimize specific metric
      mix nous.optimize --suite basic.yaml --metric pass_rate
      mix nous.optimize --suite basic.yaml --metric latency_p50 --minimize

      # Custom parameter file
      mix nous.optimize --suite basic.yaml --params params.exs

      # Early stopping
      mix nous.optimize --suite basic.yaml --early-stop 0.95

      # Output results
      mix nous.optimize --suite basic.yaml --output results.json

  ## Options

    * `--suite` - Path to evaluation suite file (required)
    * `--strategy` - Optimization strategy: grid_search, random, bayesian (default: bayesian)
    * `--trials` - Number of trials to run (default: 20)
    * `--metric` - Metric to optimize: score, pass_rate, latency_p50, latency_p95, total_tokens, cost (default: score)
    * `--minimize` - Minimize metric instead of maximize (useful for latency/cost)
    * `--timeout` - Total timeout in ms (default: 3600000 = 1 hour)
    * `--early-stop` - Stop if metric reaches threshold
    * `--params` - Path to parameters file (Elixir script returning list of parameters)
    * `--output` - Output file path for JSON results
    * `--verbose` - Show detailed progress
    * `--quiet` - Suppress progress output

  ## Parameters File

  Create a `.exs` file that returns a list of parameters:

      # params.exs
      alias Nous.Eval.Optimizer.Parameter

      [
        Parameter.float(:temperature, 0.0, 1.0, step: 0.1),
        Parameter.integer(:max_tokens, 100, 1000, step: 100),
        Parameter.choice(:model, ["gpt-4", "gpt-3.5-turbo"])
      ]

  ## Default Parameters

  If no params file is specified, optimizes these parameters:

    * `temperature` - Float from 0.0 to 1.0 (step: 0.1)
    * `max_tokens` - Integer from 256 to 2048 (step: 256)

  ## Example

      # Quick optimization with Bayesian search
      mix nous.optimize --suite test/eval/suites/basic.yaml --trials 30

      # Grid search for small parameter space
      mix nous.optimize --suite basic.yaml --strategy grid_search --max-trials 50

      # Minimize latency
      mix nous.optimize --suite basic.yaml --metric latency_p50 --minimize

  """

  use Mix.Task

  alias Nous.Eval.Optimizer
  alias Nous.Eval.Optimizer.Parameter

  @shortdoc "Run parameter optimization for Nous agents"

  @switches [
    suite: :string,
    strategy: :string,
    trials: :integer,
    metric: :string,
    minimize: :boolean,
    timeout: :integer,
    early_stop: :float,
    params: :string,
    output: :string,
    verbose: :boolean,
    quiet: :boolean,
    max_trials: :integer,
    n_initial: :integer,
    gamma: :float
  ]

  @impl Mix.Task
  def run(args) do
    # Start the application
    {:ok, _} = Application.ensure_all_started(:nous)

    {opts, _remaining, _invalid} = OptionParser.parse(args, switches: @switches)

    # Validate required options
    unless opts[:suite] do
      Mix.shell().error("Error: --suite is required")
      Mix.shell().info("\nUsage: mix nous.optimize --suite <path>")
      exit({:shutdown, 1})
    end

    # Load suite
    suite = load_suite(opts[:suite])

    # Load parameters
    parameters = load_parameters(opts)

    # Build optimization options
    opt_opts = build_opts(opts)

    # Print header
    unless opts[:quiet] do
      print_header(suite, parameters, opts)
    end

    # Run optimization
    {:ok, result} = Optimizer.optimize(suite, parameters, opt_opts)
    output_results(result, opts)
  end

  defp load_suite(path) do
    # Try path as-is first, then with default directory
    full_path =
      cond do
        File.exists?(path) -> path
        File.exists?("test/eval/suites/#{path}") -> "test/eval/suites/#{path}"
        true -> path
      end

    case Nous.Eval.Suite.from_yaml(full_path) do
      {:ok, suite} ->
        suite

      {:error, reason} ->
        Mix.shell().error("Failed to load suite '#{path}': #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp load_parameters(opts) do
    if opts[:params] do
      # Load from file
      case Code.eval_file(opts[:params]) do
        {params, _} when is_list(params) ->
          params

        _ ->
          Mix.shell().error("Parameters file must return a list of parameters")
          exit({:shutdown, 1})
      end
    else
      # Default parameters
      [
        Parameter.float(:temperature, 0.0, 1.0, step: 0.1),
        Parameter.integer(:max_tokens, 256, 2048, step: 256)
      ]
    end
  end

  defp build_opts(opts) do
    strategy =
      case opts[:strategy] do
        "grid_search" -> :grid_search
        "grid" -> :grid_search
        "random" -> :random
        "bayesian" -> :bayesian
        nil -> :bayesian
        other ->
          Mix.shell().error("Unknown strategy: #{other}")
          exit({:shutdown, 1})
      end

    metric =
      case opts[:metric] do
        "score" -> :score
        "pass_rate" -> :pass_rate
        "latency_p50" -> :latency_p50
        "latency_p95" -> :latency_p95
        "latency_p99" -> :latency_p99
        "total_tokens" -> :total_tokens
        "cost" -> :cost
        nil -> :score
        other ->
          Mix.shell().error("Unknown metric: #{other}")
          exit({:shutdown, 1})
      end

    opt_opts = [
      strategy: strategy,
      metric: metric,
      maximize: !opts[:minimize],
      verbose: opts[:verbose] && !opts[:quiet]
    ]

    opt_opts =
      case strategy do
        :grid_search ->
          opt_opts
          |> maybe_add(:max_trials, opts[:trials] || opts[:max_trials])
          |> maybe_add(:timeout, opts[:timeout])
          |> maybe_add(:early_stop, opts[:early_stop])

        :random ->
          opt_opts
          |> maybe_add(:n_trials, opts[:trials] || 20)
          |> maybe_add(:timeout, opts[:timeout])
          |> maybe_add(:early_stop, opts[:early_stop])

        :bayesian ->
          opt_opts
          |> maybe_add(:n_trials, opts[:trials] || 20)
          |> maybe_add(:n_initial, opts[:n_initial])
          |> maybe_add(:gamma, opts[:gamma])
          |> maybe_add(:timeout, opts[:timeout])
          |> maybe_add(:early_stop, opts[:early_stop])
      end

    opt_opts
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_header(suite, parameters, opts) do
    strategy = opts[:strategy] || "bayesian"
    metric = opts[:metric] || "score"
    trials = opts[:trials] || 20

    Mix.shell().info("""

    ╔═══════════════════════════════════════════════════════════╗
    ║               Nous Parameter Optimization                 ║
    ╚═══════════════════════════════════════════════════════════╝

    Suite:      #{suite.name}
    Strategy:   #{strategy}
    Metric:     #{metric} (#{if opts[:minimize], do: "minimize", else: "maximize"})
    Trials:     #{trials}

    Parameters:
    """)

    Enum.each(parameters, fn param ->
      Mix.shell().info("  • #{param.name}: #{format_param(param)}")
    end)

    Mix.shell().info("")
  end

  defp format_param(%Parameter{type: :float, min: min, max: max, step: step}) do
    if step do
      "float [#{min}, #{max}] step=#{step}"
    else
      "float [#{min}, #{max}]"
    end
  end

  defp format_param(%Parameter{type: :integer, min: min, max: max, step: step}) do
    if step do
      "integer [#{min}, #{max}] step=#{step}"
    else
      "integer [#{min}, #{max}]"
    end
  end

  defp format_param(%Parameter{type: :choice, choices: choices}) do
    "choice #{inspect(choices)}"
  end

  defp format_param(%Parameter{type: :bool}) do
    "boolean"
  end

  defp output_results(result, opts) do
    unless opts[:quiet] do
      print_results(result)
    end

    if opts[:output] do
      json = result_to_json(result)
      File.write!(opts[:output], json)
      Mix.shell().info("\nResults written to: #{opts[:output]}")
    end
  end

  defp print_results(result) do
    Mix.shell().info("""

    ════════════════════════════════════════════════════════════
                        OPTIMIZATION RESULTS
    ════════════════════════════════════════════════════════════

    Best Score: #{Float.round(result.best_score, 4)}

    Best Configuration:
    """)

    Enum.each(result.best_config, fn {key, value} ->
      Mix.shell().info("  #{key}: #{inspect(value)}")
    end)

    Mix.shell().info("""

    Statistics:
      Total trials:     #{result.total_trials}
      Duration:         #{format_duration(result.duration_ms)}
      Avg score:        #{Float.round(result.avg_score, 4)}
      Score std dev:    #{Float.round(result.std_score, 4)}

    Top 5 Configurations:
    """)

    result.all_trials
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(5)
    |> Enum.with_index(1)
    |> Enum.each(fn {trial, idx} ->
      config_str =
        trial.config
        |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
        |> Enum.join(", ")

      Mix.shell().info("  #{idx}. #{Float.round(trial.score, 4)} | #{config_str}")
    end)

    Mix.shell().info("")
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}min"

  defp result_to_json(result) do
    %{
      best_config: result.best_config,
      best_score: result.best_score,
      total_trials: result.total_trials,
      duration_ms: result.duration_ms,
      avg_score: result.avg_score,
      std_score: result.std_score,
      all_trials:
        Enum.map(result.all_trials, fn trial ->
          %{
            config: trial.config,
            score: trial.score,
            metrics: trial.metrics,
            duration_ms: trial.duration_ms
          }
        end),
      generated_at: DateTime.to_iso8601(DateTime.utc_now())
    }
    |> Jason.encode!(pretty: true)
  end
end
