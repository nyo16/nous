#!/usr/bin/env elixir

# Nous AI - Cost Tracking & Budget Management Example
# Monitor token usage, estimate costs, and implement budget controls

IO.puts("💰 Cost Tracking & Budget Management Demo")
IO.puts("Learn how to monitor and control AI costs!")
IO.puts("")

# ============================================================================
# Cost Calculator Module
# ============================================================================

defmodule CostCalculator do
  @doc """
  Calculate costs for different AI providers based on token usage.
  Prices are approximate and change frequently - always check current pricing.
  """

  # Approximate pricing per 1K tokens (as of 2024)
  @pricing %{
    "anthropic" => %{input: 0.01, output: 0.03},   # Claude Sonnet
    "openai" => %{input: 0.01, output: 0.03},      # GPT-4
    "gemini" => %{input: 0.001, output: 0.003},    # Gemini Pro
    "local" => %{input: 0.0, output: 0.0}          # LM Studio/Ollama
  }

  def calculate_cost(usage, provider_type) do
    pricing = Map.get(@pricing, provider_type, @pricing["openai"])

    input_cost = (usage.input_tokens / 1000) * pricing.input
    output_cost = (usage.output_tokens / 1000) * pricing.output
    total_cost = input_cost + output_cost

    %{
      input_cost: Float.round(input_cost, 6),
      output_cost: Float.round(output_cost, 6),
      total_cost: Float.round(total_cost, 6),
      provider: provider_type
    }
  end

  def format_cost(cost) do
    "$#{:erlang.float_to_binary(cost.total_cost, [{:decimals, 4}])}"
  end

  def get_provider_type(model_string) do
    cond do
      String.starts_with?(model_string, "anthropic:") -> "anthropic"
      String.starts_with?(model_string, "openai:") -> "openai"
      String.starts_with?(model_string, "gemini:") -> "gemini"
      String.starts_with?(model_string, "lmstudio:") -> "local"
      String.starts_with?(model_string, "ollama:") -> "local"
      true -> "openai"  # default assumption
    end
  end
end

# ============================================================================
# Basic Cost Tracking
# ============================================================================

IO.puts("1️⃣  Basic Cost Tracking:")

model = "lmstudio:qwen/qwen3-30b"  # Free local model for demo
agent = Nous.new(model,
  instructions: "You are a helpful assistant. Provide detailed explanations.",
  model_settings: %{temperature: 0.7}
)

test_prompts = [
  "What is artificial intelligence?",
  "Explain machine learning in simple terms.",
  "Tell me about the history of computers."
]

total_usage = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, tool_calls: 0}
total_cost = 0.0

IO.puts("Running multiple queries to track cumulative costs...")
IO.puts("")

{final_usage, final_cost} = Enum.reduce(test_prompts, {total_usage, total_cost}, fn prompt, {usage_acc, cost_acc} ->
  IO.puts("📝 Prompt: #{prompt}")

  case Nous.run(agent, prompt) do
    {:ok, result} ->
      # Calculate cost for this request
      provider_type = CostCalculator.get_provider_type(model)
      cost = CostCalculator.calculate_cost(result.usage, provider_type)

      # Update totals
      updated_usage = %{
        input_tokens: usage_acc.input_tokens + result.usage.input_tokens,
        output_tokens: usage_acc.output_tokens + result.usage.output_tokens,
        total_tokens: usage_acc.total_tokens + result.usage.total_tokens,
        tool_calls: usage_acc.tool_calls + result.usage.tool_calls
      }

      updated_cost = cost_acc + cost.total_cost

      IO.puts("🤖 Response: #{String.slice(result.output, 0, 50)}...")
      IO.puts("📊 Usage: #{result.usage.input_tokens} in + #{result.usage.output_tokens} out = #{result.usage.total_tokens} total")
      IO.puts("💰 Cost: #{CostCalculator.format_cost(cost)}")
      IO.puts("")

      {updated_usage, updated_cost}

    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
      {usage_acc, cost_acc}
  end
end)

IO.puts("📈 Session Summary:")
IO.puts("   Total tokens: #{final_usage.total_tokens}")
IO.puts("   Input tokens: #{final_usage.input_tokens}")
IO.puts("   Output tokens: #{final_usage.output_tokens}")
IO.puts("   Tool calls: #{final_usage.tool_calls}")
IO.puts("   Total cost: $#{Float.round(final_cost, 4)}")

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Budget Manager
# ============================================================================

defmodule BudgetManager do
  @doc """
  Manage and enforce budget limits for AI usage
  """
  defstruct [:daily_limit, :session_limit, :daily_spent, :session_spent, :start_time]

  def new(opts \\ []) do
    %__MODULE__{
      daily_limit: Keyword.get(opts, :daily_limit, 10.0),      # $10/day default
      session_limit: Keyword.get(opts, :session_limit, 1.0),   # $1/session default
      daily_spent: Keyword.get(opts, :daily_spent, 0.0),
      session_spent: 0.0,
      start_time: DateTime.utc_now()
    }
  end

  def check_budget(budget_manager, estimated_cost) do
    cond do
      budget_manager.session_spent + estimated_cost > budget_manager.session_limit ->
        {:error, :session_budget_exceeded, budget_manager}

      budget_manager.daily_spent + estimated_cost > budget_manager.daily_limit ->
        {:error, :daily_budget_exceeded, budget_manager}

      true ->
        {:ok, budget_manager}
    end
  end

  def record_cost(budget_manager, actual_cost) do
    %{budget_manager |
      session_spent: budget_manager.session_spent + actual_cost,
      daily_spent: budget_manager.daily_spent + actual_cost
    }
  end

  def get_budget_status(budget_manager) do
    session_remaining = budget_manager.session_limit - budget_manager.session_spent
    daily_remaining = budget_manager.daily_limit - budget_manager.daily_spent

    %{
      session_spent: budget_manager.session_spent,
      session_remaining: max(0, session_remaining),
      daily_spent: budget_manager.daily_spent,
      daily_remaining: max(0, daily_remaining),
      session_utilization: (budget_manager.session_spent / budget_manager.session_limit * 100),
      daily_utilization: (budget_manager.daily_spent / budget_manager.daily_limit * 100)
    }
  end

  def print_budget_status(budget_manager) do
    status = get_budget_status(budget_manager)

    IO.puts("💳 Budget Status:")
    IO.puts("   Session: $#{Float.round(status.session_spent, 4)} / $#{budget_manager.session_limit} (#{Float.round(status.session_utilization, 1)}%)")
    IO.puts("   Daily: $#{Float.round(status.daily_spent, 4)} / $#{budget_manager.daily_limit} (#{Float.round(status.daily_utilization, 1)}%)")
    IO.puts("   Remaining: $#{Float.round(status.session_remaining, 4)} session, $#{Float.round(status.daily_remaining, 4)} daily")
  end
end

IO.puts("2️⃣  Budget Management Demo:")

# Create a budget manager with low limits for demo
budget = BudgetManager.new(daily_limit: 0.50, session_limit: 0.10)

IO.puts("Initial budget:")
BudgetManager.print_budget_status(budget)
IO.puts("")

# Simulate running requests within budget constraints
test_agent = Nous.new("lmstudio:qwen/qwen3-30b")
budget_prompts = [
  "Hello, how are you?",
  "What's 2+2?",
  "Tell me a short joke.",
  "Explain photosynthesis briefly."
]

final_budget = Enum.reduce(budget_prompts, budget, fn prompt, current_budget ->
  IO.puts("📝 Prompt: #{prompt}")

  # Estimate cost (rough pre-check)
  estimated_tokens = String.length(prompt) + 50  # rough estimate
  estimated_cost = (estimated_tokens / 1000) * 0.01  # rough cost estimate

  case BudgetManager.check_budget(current_budget, estimated_cost) do
    {:ok, _} ->
      case Nous.run(test_agent, prompt) do
        {:ok, result} ->
          provider_type = CostCalculator.get_provider_type("lmstudio:qwen/qwen3-30b")
          cost = CostCalculator.calculate_cost(result.usage, provider_type)
          updated_budget = BudgetManager.record_cost(current_budget, cost.total_cost)

          IO.puts("✅ Success - Cost: #{CostCalculator.format_cost(cost)}")
          updated_budget

        {:error, reason} ->
          IO.puts("❌ Request failed: #{inspect(reason)}")
          current_budget
      end

    {:error, :session_budget_exceeded, _} ->
      IO.puts("🚫 Session budget exceeded - skipping request")
      current_budget

    {:error, :daily_budget_exceeded, _} ->
      IO.puts("🚫 Daily budget exceeded - skipping request")
      current_budget
  end
end)

IO.puts("")
IO.puts("Final budget status:")
BudgetManager.print_budget_status(final_budget)

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Cost Comparison Between Providers
# ============================================================================

defmodule CostComparison do
  @doc """
  Compare costs across different providers for the same task
  """
  def compare_providers(prompt, providers) do
    IO.puts("🔍 Cost Comparison for prompt: \"#{prompt}\"")
    IO.puts("")

    results = Enum.map(providers, fn provider ->
      agent = Nous.new(provider.model,
        instructions: "You are a helpful assistant",
        model_settings: provider.settings || %{}
      )

      case Nous.run(agent, prompt) do
        {:ok, result} ->
          provider_type = CostCalculator.get_provider_type(provider.model)
          cost = CostCalculator.calculate_cost(result.usage, provider_type)

          %{
            provider: provider.model,
            status: :success,
            usage: result.usage,
            cost: cost,
            response_length: String.length(result.output),
            response_preview: String.slice(result.output, 0, 100) <> "..."
          }

        {:error, reason} ->
          %{
            provider: provider.model,
            status: :error,
            error: reason
          }
      end
    end)

    # Print comparison table
    successful_results = Enum.filter(results, & &1.status == :success)

    if length(successful_results) > 0 do
      IO.puts("Provider Comparison:")
      IO.puts("#{String.pad_trailing("Provider", 30)} | #{String.pad_trailing("Tokens", 10)} | #{String.pad_trailing("Cost", 8)} | Quality")
      IO.puts(String.duplicate("-", 70))

      successful_results
      |> Enum.sort_by(& &1.cost.total_cost)
      |> Enum.each(fn result ->
        provider_name = String.slice(result.provider, 0, 28)
        tokens = "#{result.usage.total_tokens}"
        cost_str = "$#{:erlang.float_to_binary(result.cost.total_cost, [{:decimals, 4}])}"
        quality = "#{result.response_length} chars"

        IO.puts("#{String.pad_trailing(provider_name, 30)} | #{String.pad_trailing(tokens, 10)} | #{String.pad_trailing(cost_str, 8)} | #{quality}")
      end)

      # Find best value
      best_value = successful_results
      |> Enum.min_by(fn result ->
        if result.cost.total_cost == 0 do
          0  # Local models win on cost
        else
          result.cost.total_cost / result.response_length  # Cost per character
        end
      end)

      IO.puts("")
      IO.puts("🏆 Best value: #{best_value.provider} (#{CostCalculator.format_cost(best_value.cost)})")
    end

    results
  end
end

IO.puts("3️⃣  Provider Cost Comparison:")

comparison_providers = [
  %{model: "lmstudio:qwen/qwen3-30b"},
  # %{model: "anthropic:claude-sonnet-4-5-20250929"},  # Uncomment if you have API key
  # %{model: "openai:gpt-4"},                           # Uncomment if you have API key
  # %{model: "gemini:gemini-2.0-flash-exp"}            # Uncomment if you have API key
]

CostComparison.compare_providers(
  "Explain the benefits of renewable energy in 2 sentences.",
  comparison_providers
)

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Advanced: Token Prediction and Cost Optimization
# ============================================================================

defmodule CostOptimizer do
  @doc """
  Optimize prompts and models for cost efficiency
  """

  def analyze_prompt_efficiency(prompt, models) do
    IO.puts("📊 Prompt Efficiency Analysis:")
    IO.puts("Prompt: \"#{prompt}\"")
    IO.puts("Length: #{String.length(prompt)} characters")
    IO.puts("")

    # Simple prompt analysis
    word_count = length(String.split(prompt))
    complexity_score = calculate_complexity_score(prompt)

    IO.puts("Word count: #{word_count}")
    IO.puts("Complexity score: #{complexity_score}/10")

    # Suggest optimizations
    suggest_optimizations(prompt, complexity_score)
  end

  defp calculate_complexity_score(prompt) do
    # Simple complexity heuristics
    factors = [
      min(String.length(prompt) / 100, 3),      # Length factor
      length(String.split(prompt)) / 20,         # Word count factor
      count_complex_words(prompt),               # Complex words
      count_questions(prompt) * 0.5              # Questions add complexity
    ]

    factors
    |> Enum.sum()
    |> min(10)
    |> Float.round(1)
  end

  defp count_complex_words(prompt) do
    complex_words = ~w[analyze explain describe comprehensive detailed elaborate sophisticated]
    words = String.split(String.downcase(prompt))

    complex_words
    |> Enum.map(&Enum.count(words, fn word -> String.contains?(word, &1) end))
    |> Enum.sum()
    |> min(3)
  end

  defp count_questions(prompt) do
    String.split(prompt, "?") |> length() |> Kernel.-(1)
  end

  defp suggest_optimizations(prompt, complexity_score) do
    IO.puts("")
    IO.puts("💡 Cost Optimization Suggestions:")

    cond do
      complexity_score > 7 ->
        IO.puts("   • High complexity - consider breaking into smaller prompts")
        IO.puts("   • Use cheaper models for initial exploration")

      complexity_score > 4 ->
        IO.puts("   • Medium complexity - good for standard models")
        IO.puts("   • Consider local models for development")

      true ->
        IO.puts("   • Low complexity - perfect for fast/cheap models")
        IO.puts("   • Use local models or cheaper cloud options")
    end

    if String.length(prompt) > 500 do
      IO.puts("   • Long prompt - will use more input tokens")
      IO.puts("   • Consider summarizing or splitting")
    end

    if String.contains?(prompt, ["detailed", "comprehensive", "explain thoroughly"]) do
      IO.puts("   • Request for detailed response - will use more output tokens")
      IO.puts("   • Be specific about desired length")
    end
  end
end

IO.puts("4️⃣  Cost Optimization Analysis:")

optimization_prompts = [
  "Hi",
  "What is machine learning?",
  "Provide a comprehensive, detailed analysis of the current state of artificial intelligence technology, including its applications across various industries, potential future developments, and societal implications."
]

Enum.each(optimization_prompts, fn prompt ->
  CostOptimizer.analyze_prompt_efficiency(prompt, ["lmstudio", "openai", "anthropic"])
  IO.puts("")
end)

# ============================================================================
# Cost Tracking Best Practices
# ============================================================================

IO.puts("💡 Cost Tracking Best Practices:")
IO.puts("")
IO.puts("✅ Track everything:")
IO.puts("   • Monitor input/output tokens separately")
IO.puts("   • Track tool calls and function execution")
IO.puts("   • Log costs per user/session/feature")
IO.puts("")
IO.puts("✅ Set budget limits:")
IO.puts("   • Daily/monthly spending caps")
IO.puts("   • Per-user usage limits")
IO.puts("   • Feature-specific budgets")
IO.puts("")
IO.puts("✅ Optimize costs:")
IO.puts("   • Use local models for development")
IO.puts("   • Choose appropriate model sizes")
IO.puts("   • Cache common responses")
IO.puts("   • Implement prompt optimization")
IO.puts("")
IO.puts("✅ Monitor trends:")
IO.puts("   • Track cost per user over time")
IO.puts("   • Monitor model performance vs cost")
IO.puts("   • Set up alerts for budget overruns")
IO.puts("")
IO.puts("✅ Cost-aware development:")
IO.puts("   • Test with free local models first")
IO.puts("   • Use cheaper models for non-critical features")
IO.puts("   • Implement fallback to local models")

# ============================================================================
# Next Steps
# ============================================================================

IO.puts("")
IO.puts("🚀 Next Steps:")
IO.puts("1. Implement budget tracking in your applications")
IO.puts("2. Set up cost monitoring and alerting")
IO.puts("3. Compare costs across different providers")
IO.puts("4. See telemetry_demo.exs for advanced monitoring")
IO.puts("5. Try error_handling_example.exs for budget-based fallbacks")
IO.puts("6. Check local_vs_cloud.exs for cost-optimized provider switching")