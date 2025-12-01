#!/usr/bin/env elixir

# Yggdrasil AI - Error Handling Example
# Graceful failures, retry patterns, and fallback providers

IO.puts("🛡️  Error Handling & Resilience Demo")
IO.puts("Learn how to handle failures gracefully in production!")
IO.puts("")

# ============================================================================
# Basic Error Handling
# ============================================================================

defmodule ErrorHandlingDemo do
  @doc """
  Demonstrate basic error handling patterns
  """
  def basic_error_handling do
    IO.puts("1️⃣  Basic Error Handling:")

    # Create agent with potentially problematic configuration
    agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
      instructions: "You are a helpful assistant"
    )

    case Yggdrasil.run(agent, "Hello, how are you?") do
      {:ok, result} ->
        IO.puts("✅ Success: #{result.output}")

      {:error, :connection_refused} ->
        IO.puts("❌ Connection failed - is LM Studio running?")
        IO.puts("💡 Solution: Start LM Studio and load a model")

      {:error, :timeout} ->
        IO.puts("❌ Request timed out")
        IO.puts("💡 Solution: Try a smaller prompt or increase timeout")

      {:error, {:http_error, 401}} ->
        IO.puts("❌ Authentication failed")
        IO.puts("💡 Solution: Check your API key")

      {:error, {:http_error, 429}} ->
        IO.puts("❌ Rate limit exceeded")
        IO.puts("💡 Solution: Wait before retrying")

      {:error, reason} ->
        IO.puts("❌ Unexpected error: #{inspect(reason)}")
        IO.puts("💡 This might be a new type of error to handle")
    end

    IO.puts("")
  end
end

ErrorHandlingDemo.basic_error_handling()

# ============================================================================
# Retry Patterns
# ============================================================================

defmodule RetryPatterns do
  @doc """
  Implement retry logic with backoff
  """
  def run_with_retry(agent, message, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    base_delay = Keyword.get(opts, :base_delay_ms, 1000)
    backoff_factor = Keyword.get(opts, :backoff_factor, 2)

    do_retry(agent, message, max_retries, base_delay, backoff_factor, 1)
  end

  defp do_retry(agent, message, max_retries, base_delay, backoff_factor, attempt) do
    IO.puts("🔄 Attempt #{attempt}/#{max_retries + 1}")

    case Yggdrasil.run(agent, message) do
      {:ok, result} ->
        IO.puts("✅ Success on attempt #{attempt}!")
        {:ok, result}

      {:error, reason} when attempt <= max_retries ->
        IO.puts("❌ Attempt #{attempt} failed: #{inspect(reason)}")

        delay = base_delay * :math.pow(backoff_factor, attempt - 1)
        IO.puts("⏳ Waiting #{round(delay)}ms before retry...")

        Process.sleep(round(delay))
        do_retry(agent, message, max_retries, base_delay, backoff_factor, attempt + 1)

      {:error, reason} ->
        IO.puts("❌ All retries exhausted. Final error: #{inspect(reason)}")
        {:error, {:max_retries_exceeded, reason}}
    end
  end
end

IO.puts("2️⃣  Retry Pattern Demo:")

# Test with a model that might fail
test_agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b")

case RetryPatterns.run_with_retry(test_agent, "Hello!", max_retries: 2, base_delay_ms: 500) do
  {:ok, result} ->
    IO.puts("🎉 Final success: #{String.slice(result.output, 0, 50)}...")

  {:error, reason} ->
    IO.puts("💥 Final failure after retries: #{inspect(reason)}")
end

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Fallback Providers
# ============================================================================

defmodule FallbackProvider do
  @doc """
  Try multiple providers in order until one succeeds
  """
  def run_with_fallback(message, providers, instructions \\ "You are a helpful assistant") do
    IO.puts("🔄 Trying providers in order: #{inspect(Enum.map(providers, & &1.model))}")

    attempt_providers(message, providers, instructions, 1)
  end

  defp attempt_providers(message, [provider_config | remaining], instructions, attempt) do
    IO.puts("🎯 Attempt #{attempt}: #{provider_config.model}")

    agent = Yggdrasil.new(provider_config.model,
      instructions: instructions,
      model_settings: Map.get(provider_config, :settings, %{})
    )

    case Yggdrasil.run(agent, message) do
      {:ok, result} ->
        IO.puts("✅ Success with #{provider_config.model}!")
        {:ok, result, provider_config.model}

      {:error, reason} ->
        IO.puts("❌ #{provider_config.model} failed: #{inspect(reason)}")

        if remaining != [] do
          IO.puts("🔄 Trying next provider...")
          attempt_providers(message, remaining, instructions, attempt + 1)
        else
          IO.puts("💥 All providers failed")
          {:error, :all_providers_failed}
        end
    end
  end

  defp attempt_providers(_message, [], _instructions, _attempt) do
    {:error, :no_providers}
  end
end

IO.puts("3️⃣  Fallback Provider Demo:")

# Define provider priority list
fallback_providers = [
  # Try local first (free and fast)
  %{model: "lmstudio:qwen/qwen3-30b", settings: %{temperature: 0.7}},

  # Fallback to cloud providers
  %{model: "anthropic:claude-sonnet-4-5-20250929", settings: %{temperature: 0.7}},
  %{model: "openai:gpt-4", settings: %{temperature: 0.7}}
]

case FallbackProvider.run_with_fallback(
  "Explain what makes a good error handling strategy.",
  fallback_providers
) do
  {:ok, result, provider} ->
    IO.puts("🎉 Final answer from #{provider}:")
    IO.puts(result.output)

  {:error, reason} ->
    IO.puts("💥 All providers failed: #{inspect(reason)}")
end

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Tool Error Handling
# ============================================================================

defmodule ErrorProneTools do
  @doc """
  Example tools that can fail in various ways
  """
  def reliable_tool(_ctx, _args) do
    "This tool always works!"
  end

  def network_tool(_ctx, %{"url" => url}) do
    # Simulate network request that might fail
    case :rand.uniform(3) do
      1 -> {:error, :connection_timeout}
      2 -> {:error, :dns_failure}
      3 -> "Successfully fetched data from #{url}"
    end
  end

  def rate_limited_tool(_ctx, _args) do
    # Simulate rate limiting
    case :rand.uniform(2) do
      1 -> {:error, :rate_limit_exceeded}
      2 -> "Rate limit OK, tool executed successfully"
    end
  end

  def validation_tool(_ctx, %{"number" => n}) when is_number(n) and n > 0 do
    "Valid number: #{n}"
  end

  def validation_tool(_ctx, %{"number" => n}) do
    {:error, "Invalid number: #{inspect(n)}"}
  end

  def validation_tool(_ctx, args) do
    {:error, "Missing required 'number' parameter. Got: #{inspect(args)}"}
  end
end

defmodule RobustAgent do
  @doc """
  Agent that handles tool errors gracefully
  """
  def create_robust_agent do
    Yggdrasil.new("lmstudio:qwen/qwen3-30b",
      instructions: """
      You are a helpful assistant with access to tools that might sometimes fail.

      When tools fail:
      1. Acknowledge the failure to the user
      2. Explain what went wrong if possible
      3. Suggest alternatives or retry if appropriate
      4. Don't let tool failures stop you from being helpful

      Available tools can fail with these errors:
      - connection_timeout: Network issues
      - rate_limit_exceeded: Too many requests
      - validation errors: Invalid input
      """,
      tools: [
        &ErrorProneTools.reliable_tool/2,
        &ErrorProneTools.network_tool/2,
        &ErrorProneTools.rate_limited_tool/2,
        &ErrorProneTools.validation_tool/2
      ]
    )
  end

  def test_tool_error_handling(agent) do
    test_cases = [
      "Use the reliable tool to test basic functionality",
      "Try to fetch data from https://api.example.com using the network tool",
      "Use the rate limited tool - it might be busy",
      "Validate the number 42 using the validation tool",
      "Validate the number -5 using the validation tool"
    ]

    IO.puts("4️⃣  Tool Error Handling Demo:")
    IO.puts("")

    Enum.with_index(test_cases, 1)
    |> Enum.each(fn {test, index} ->
      IO.puts("Test #{index}: #{test}")

      case Yggdrasil.run(agent, test) do
        {:ok, result} ->
          IO.puts("🤖 Response: #{result.output}")
          if result.usage.tool_calls > 0 do
            IO.puts("🔧 Tools called: #{result.usage.tool_calls}")
          end

        {:error, reason} ->
          IO.puts("❌ Agent error: #{inspect(reason)}")
      end

      IO.puts("")
    end)
  end
end

robust_agent = RobustAgent.create_robust_agent()
RobustAgent.test_tool_error_handling(robust_agent)

IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Circuit Breaker Pattern
# ============================================================================

defmodule CircuitBreaker do
  @doc """
  Implement circuit breaker pattern to prevent cascading failures
  """
  defstruct [:failure_threshold, :timeout_ms, :state, :failures, :last_failure_time]

  def new(failure_threshold \\ 3, timeout_ms \\ 30_000) do
    %__MODULE__{
      failure_threshold: failure_threshold,
      timeout_ms: timeout_ms,
      state: :closed,  # :closed, :open, :half_open
      failures: 0,
      last_failure_time: nil
    }
  end

  def call(circuit_breaker, fun) do
    case circuit_breaker.state do
      :closed ->
        execute_and_update(circuit_breaker, fun)

      :open ->
        if should_try_half_open?(circuit_breaker) do
          circuit_breaker = %{circuit_breaker | state: :half_open}
          IO.puts("🔄 Circuit breaker: Trying half-open")
          execute_and_update(circuit_breaker, fun)
        else
          IO.puts("🚫 Circuit breaker: OPEN - failing fast")
          {:error, :circuit_breaker_open, circuit_breaker}
        end

      :half_open ->
        execute_and_update(circuit_breaker, fun)
    end
  end

  defp execute_and_update(circuit_breaker, fun) do
    case fun.() do
      {:ok, result} ->
        # Success - reset circuit breaker
        updated_circuit = %{circuit_breaker |
          state: :closed,
          failures: 0,
          last_failure_time: nil
        }
        {:ok, result, updated_circuit}

      {:error, reason} ->
        # Failure - update circuit breaker
        failures = circuit_breaker.failures + 1
        state = if failures >= circuit_breaker.failure_threshold, do: :open, else: :closed

        updated_circuit = %{circuit_breaker |
          failures: failures,
          state: state,
          last_failure_time: System.monotonic_time(:millisecond)
        }

        if state == :open do
          IO.puts("⚠️  Circuit breaker: OPENED after #{failures} failures")
        end

        {:error, reason, updated_circuit}
    end
  end

  defp should_try_half_open?(circuit_breaker) do
    current_time = System.monotonic_time(:millisecond)
    current_time - circuit_breaker.last_failure_time >= circuit_breaker.timeout_ms
  end
end

IO.puts("5️⃣  Circuit Breaker Pattern Demo:")

# Simulate unreliable service
unreliable_service = fn ->
  case :rand.uniform(4) do
    1 -> {:ok, "Service success!"}
    _ -> {:error, :service_unavailable}
  end
end

circuit = CircuitBreaker.new(2, 5000)  # Open after 2 failures, retry after 5s

# Test circuit breaker
{_final_circuit, results} = Enum.reduce(1..8, {circuit, []}, fn attempt, {current_circuit, acc} ->
  IO.puts("Attempt #{attempt}:")

  case CircuitBreaker.call(current_circuit, unreliable_service) do
    {:ok, result, updated_circuit} ->
      IO.puts("✅ Success: #{result}")
      {updated_circuit, [result | acc]}

    {:error, reason, updated_circuit} ->
      IO.puts("❌ Failed: #{inspect(reason)}")
      {updated_circuit, acc}
  end

  Process.sleep(1000)  # Small delay between attempts
  IO.puts("")
end)

IO.puts("Circuit breaker protected us from cascading failures!")
IO.puts("")

# ============================================================================
# Error Handling Best Practices
# ============================================================================

IO.puts("💡 Error Handling Best Practices Summary:")
IO.puts("")
IO.puts("✅ Always use pattern matching:")
IO.puts("   case Yggdrasil.run(agent, message) do")
IO.puts("     {:ok, result} -> handle_success(result)")
IO.puts("     {:error, reason} -> handle_error(reason)")
IO.puts("   end")
IO.puts("")
IO.puts("✅ Implement retry logic for transient failures:")
IO.puts("   • Connection timeouts")
IO.puts("   • Rate limits")
IO.puts("   • Temporary service unavailability")
IO.puts("")
IO.puts("✅ Use fallback providers:")
IO.puts("   • Local → Cloud fallback")
IO.puts("   • Primary → Secondary provider")
IO.puts("   • Expensive → Cheap model fallback")
IO.puts("")
IO.puts("✅ Handle tool errors gracefully:")
IO.puts("   • Validate tool inputs")
IO.puts("   • Catch and report tool failures")
IO.puts("   • Provide fallback behavior")
IO.puts("")
IO.puts("✅ Implement circuit breakers for:")
IO.puts("   • External service calls")
IO.puts("   • Expensive operations")
IO.puts("   • Cascading failure prevention")
IO.puts("")
IO.puts("✅ Monitor and log errors:")
IO.puts("   • Track error rates")
IO.puts("   • Set up alerting")
IO.puts("   • Analyze failure patterns")

# ============================================================================
# Next Steps
# ============================================================================

IO.puts("")
IO.puts("🚀 Next Steps:")
IO.puts("1. Try breaking the examples above (stop LM Studio, wrong API key)")
IO.puts("2. Implement error handling in your own agents")
IO.puts("3. See telemetry_demo.exs for error monitoring")
IO.puts("4. Check cost_tracking_example.exs for budget-based error handling")
IO.puts("5. Explore production patterns in trading_desk/ and genserver_agent_example.ex")