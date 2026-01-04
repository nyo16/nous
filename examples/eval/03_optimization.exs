# Parameter Optimization Example
#
# This example shows how to use the optimizer to find the best
# configuration for your agent.
#
# Run with: mix run examples/eval/03_optimization.exs

alias Nous.Eval
alias Nous.Eval.{TestCase, Suite}
alias Nous.Eval.Optimizer
alias Nous.Eval.Optimizer.Parameter

# Configure your model
model = System.get_env("NOUS_MODEL") || "lmstudio:ministral-3-14b-reasoning"

IO.puts("Running optimization with model: #{model}\n")

# Create a test suite to optimize
test_cases = [
  TestCase.new(
    id: "creative_writing",
    name: "Creative Writing",
    input: "Write a one-sentence story about a robot",
    expected: %{
      contains: ["robot"],
      patterns: ["\\.$"]  # Must end with period
    },
    eval_type: :contains
  ),
  TestCase.new(
    id: "factual_question",
    name: "Factual Question",
    input: "What planet is known as the Red Planet? One word answer.",
    expected: "Mars",
    eval_type: :fuzzy_match,
    eval_config: %{threshold: 0.8}
  ),
  TestCase.new(
    id: "list_generation",
    name: "List Generation",
    input: "List 3 programming languages",
    expected: %{
      contains: ["Python", "JavaScript", "Java", "Ruby", "Go", "Rust", "C", "Elixir"],
      match_all: false  # Any one is fine
    },
    eval_type: :contains
  )
]

suite = Suite.new(
  name: "optimization_example",
  default_model: model,
  default_instructions: "Be helpful and concise.",
  test_cases: test_cases
)

# Define parameter space
parameters = [
  # Temperature: controls randomness (0.0 = deterministic, 1.0 = creative)
  Parameter.float(:temperature, 0.0, 1.0, step: 0.2),

  # Max tokens: controls response length
  Parameter.integer(:max_tokens, 128, 512, step: 128)
]

IO.puts("=" <> String.duplicate("=", 59))
IO.puts("Parameter Optimization")
IO.puts("=" <> String.duplicate("=", 59))
IO.puts("")
IO.puts("Parameters to optimize:")

Enum.each(parameters, fn param ->
  IO.puts("  - #{param.name}: #{param.type} [#{param.min}, #{param.max}]")
end)

IO.puts("")

# Option 1: Grid Search (exhaustive, good for small spaces)
IO.puts("Running Grid Search optimization...\n")

case Optimizer.optimize(suite, parameters,
  strategy: :grid_search,
  metric: :score,
  maximize: true,
  timeout: 300_000,  # 5 minutes
  verbose: true
) do
  {:ok, result} ->
    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("Grid Search Results")
    IO.puts(String.duplicate("-", 60))
    IO.puts("Best configuration:")
    Enum.each(result.best_config, fn {k, v} ->
      IO.puts("  #{k}: #{v}")
    end)
    IO.puts("\nBest score: #{Float.round(result.best_score, 4)}")
    IO.puts("Avg score: #{Float.round(result.avg_score, 4)}")
    IO.puts("Std dev: #{Float.round(result.std_score, 4)}")
    IO.puts("Total trials: #{result.total_trials}")

  {:error, reason} ->
    IO.puts("Optimization failed: #{inspect(reason)}")
end

# Option 2: Bayesian Optimization (smarter, good for expensive evals)
IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Running Bayesian Optimization...\n")

# For Bayesian, we can use continuous parameters (no step)
bayesian_params = [
  Parameter.float(:temperature, 0.0, 1.0),
  Parameter.integer(:max_tokens, 128, 512)
]

case Optimizer.optimize(suite, bayesian_params,
  strategy: :bayesian,
  n_trials: 10,      # Total trials
  n_initial: 5,      # Random trials before optimization
  gamma: 0.25,       # Top 25% are "good"
  metric: :score,
  maximize: true,
  timeout: 300_000,
  verbose: true
) do
  {:ok, result} ->
    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("Bayesian Optimization Results")
    IO.puts(String.duplicate("-", 60))
    IO.puts("Best configuration:")
    Enum.each(result.best_config, fn {k, v} ->
      formatted = if is_float(v), do: Float.round(v, 3), else: v
      IO.puts("  #{k}: #{formatted}")
    end)
    IO.puts("\nBest score: #{Float.round(result.best_score, 4)}")
    IO.puts("Avg score: #{Float.round(result.avg_score, 4)}")
    IO.puts("Total trials: #{result.total_trials}")

    # Show convergence
    IO.puts("\nScore progression:")
    result.all_trials
    |> Enum.with_index(1)
    |> Enum.each(fn {trial, idx} ->
      bar_len = round(trial.score * 20)
      bar = String.duplicate("█", bar_len) <> String.duplicate("░", 20 - bar_len)
      IO.puts("  #{String.pad_leading("#{idx}", 2)}: #{bar} #{Float.round(trial.score, 3)}")
    end)

  {:error, reason} ->
    IO.puts("Optimization failed: #{inspect(reason)}")
end
