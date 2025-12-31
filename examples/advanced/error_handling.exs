#!/usr/bin/env elixir

# Nous AI - Error Handling
# Graceful failures, retries, and fallback patterns

IO.puts("=== Nous AI - Error Handling ===\n")

# ============================================================================
# Basic Error Handling
# ============================================================================

IO.puts("--- Basic Error Handling ---")

agent = Nous.new("lmstudio:qwen3",
  instructions: "You are a helpful assistant."
)

case Nous.run(agent, "Hello!") do
  {:ok, result} ->
    IO.puts("Success: #{result.output}")

  {:error, :connection_refused} ->
    IO.puts("Connection failed - is LM Studio running?")

  {:error, :timeout} ->
    IO.puts("Request timed out")

  {:error, {:http_error, 401}} ->
    IO.puts("Authentication failed - check your API key")

  {:error, {:http_error, 429}} ->
    IO.puts("Rate limit exceeded - wait before retrying")

  {:error, reason} ->
    IO.puts("Unexpected error: #{inspect(reason)}")
end

IO.puts("")

# ============================================================================
# Retry Pattern
# ============================================================================

IO.puts("--- Retry Pattern ---")

defmodule Retry do
  def run(agent, message, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    base_delay = Keyword.get(opts, :base_delay_ms, 1000)

    do_retry(agent, message, max_retries, base_delay, 1)
  end

  defp do_retry(agent, message, max_retries, base_delay, attempt) do
    IO.puts("Attempt #{attempt}/#{max_retries + 1}")

    case Nous.run(agent, message) do
      {:ok, result} ->
        IO.puts("Success on attempt #{attempt}")
        {:ok, result}

      {:error, reason} when attempt <= max_retries ->
        IO.puts("Attempt #{attempt} failed: #{inspect(reason)}")
        delay = base_delay * round(:math.pow(2, attempt - 1))
        IO.puts("Waiting #{delay}ms before retry...")
        Process.sleep(delay)
        do_retry(agent, message, max_retries, base_delay, attempt + 1)

      {:error, reason} ->
        IO.puts("All retries exhausted")
        {:error, {:max_retries_exceeded, reason}}
    end
  end
end

case Retry.run(agent, "Hello!", max_retries: 2, base_delay_ms: 500) do
  {:ok, result} -> IO.puts("Final: #{String.slice(result.output, 0, 50)}...")
  {:error, reason} -> IO.puts("Failed: #{inspect(reason)}")
end

IO.puts("")

# ============================================================================
# Fallback Providers
# ============================================================================

IO.puts("--- Fallback Providers ---")

defmodule Fallback do
  def run(message, providers) do
    attempt_providers(message, providers, 1)
  end

  defp attempt_providers(message, [%{model: model} = config | rest], attempt) do
    IO.puts("Attempt #{attempt}: #{model}")

    opts = [instructions: Map.get(config, :instructions, "You are helpful.")]
    opts = if config[:api_key], do: Keyword.put(opts, :api_key, config.api_key), else: opts

    agent = Nous.new(model, opts)

    case Nous.run(agent, message) do
      {:ok, result} ->
        IO.puts("Success with #{model}")
        {:ok, result, model}

      {:error, reason} ->
        IO.puts("#{model} failed: #{inspect(reason)}")
        if rest != [] do
          attempt_providers(message, rest, attempt + 1)
        else
          {:error, :all_providers_failed}
        end
    end
  end

  defp attempt_providers(_message, [], _attempt), do: {:error, :no_providers}
end

providers = [
  %{model: "lmstudio:qwen3"},  # Try local first
  %{model: "anthropic:claude-sonnet-4-5-20250929", api_key: System.get_env("ANTHROPIC_API_KEY")},
  %{model: "openai:gpt-4", api_key: System.get_env("OPENAI_API_KEY")}
]

case Fallback.run("What is 2+2?", providers) do
  {:ok, result, provider} ->
    IO.puts("Answer from #{provider}: #{result.output}")
  {:error, reason} ->
    IO.puts("All failed: #{inspect(reason)}")
end

IO.puts("")

# ============================================================================
# Tool Error Handling
# ============================================================================

IO.puts("--- Tool Error Handling ---")

defmodule FlakeyTools do
  def unreliable_api(_ctx, %{"query" => query}) do
    # Simulate unreliable external API
    case :rand.uniform(3) do
      1 -> {:error, "Connection timeout"}
      2 -> {:error, "Service unavailable"}
      3 -> %{query: query, results: ["Result 1", "Result 2"]}
    end
  end

  def validate_input(_ctx, %{"number" => n}) when is_number(n) and n > 0 do
    %{valid: true, number: n}
  end

  def validate_input(_ctx, %{"number" => n}) do
    {:error, "Invalid number: #{inspect(n)} - must be positive"}
  end

  def validate_input(_ctx, args) do
    {:error, "Missing 'number' parameter. Got: #{inspect(args)}"}
  end
end

tool_agent = Nous.new("lmstudio:qwen3",
  instructions: """
  You have tools that might fail. When a tool returns an error:
  1. Acknowledge the failure
  2. Explain what went wrong
  3. Try an alternative approach or ask the user for help
  """,
  tools: [
    &FlakeyTools.unreliable_api/2,
    &FlakeyTools.validate_input/2
  ]
)

IO.puts("Testing unreliable tool...")
case Nous.run(tool_agent, "Search for 'elixir'") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tool calls: #{result.usage.tool_calls}")
  {:error, error} ->
    IO.puts("Agent error: #{inspect(error)}")
end

IO.puts("")

# ============================================================================
# Max Iterations
# ============================================================================

IO.puts("--- Max Iterations ---")
IO.puts("""
Prevent infinite tool loops with max_iterations:

  {:ok, result} = Nous.run(agent, message,
    max_iterations: 10  # Default is 10
  )

When exceeded:
  {:error, %Nous.Errors.MaxIterationsReached{iterations: 10}}
""")

# ============================================================================
# Timeouts
# ============================================================================

IO.puts("--- Timeouts ---")
IO.puts("""
Configure timeouts at multiple levels:

  # Agent-level timeout (entire run)
  agent = Nous.new("openai:gpt-4",
    timeout: 30_000  # 30 seconds
  )

  # Tool-level timeout
  slow_tool = fn _ctx, _args ->
    Process.sleep(5000)
    %{result: "done"}
  end

  agent = Nous.new("openai:gpt-4",
    tools: [slow_tool],
    tool_timeout: 10_000  # 10 seconds per tool
  )

When timeout occurs:
  {:error, :timeout}
""")

# ============================================================================
# Circuit Breaker Pattern
# ============================================================================

IO.puts("--- Circuit Breaker Pattern ---")

defmodule CircuitBreaker do
  defstruct [:threshold, :timeout_ms, :state, :failures, :last_failure]

  def new(threshold \\ 3, timeout_ms \\ 30_000) do
    %__MODULE__{
      threshold: threshold,
      timeout_ms: timeout_ms,
      state: :closed,
      failures: 0,
      last_failure: nil
    }
  end

  def call(cb, fun) do
    case cb.state do
      :closed -> execute(cb, fun)
      :open -> maybe_half_open(cb, fun)
      :half_open -> execute(cb, fun)
    end
  end

  defp execute(cb, fun) do
    case fun.() do
      {:ok, result} ->
        {:ok, result, reset(cb)}

      {:error, reason} ->
        failures = cb.failures + 1
        state = if failures >= cb.threshold, do: :open, else: :closed
        if state == :open, do: IO.puts("Circuit breaker OPENED after #{failures} failures")
        {:error, reason, %{cb | failures: failures, state: state, last_failure: now()}}
    end
  end

  defp maybe_half_open(cb, fun) do
    if now() - cb.last_failure >= cb.timeout_ms do
      IO.puts("Circuit breaker: trying half-open")
      execute(%{cb | state: :half_open}, fun)
    else
      IO.puts("Circuit breaker: OPEN - failing fast")
      {:error, :circuit_open, cb}
    end
  end

  defp reset(cb), do: %{cb | state: :closed, failures: 0, last_failure: nil}
  defp now, do: System.monotonic_time(:millisecond)
end

# Example usage
cb = CircuitBreaker.new(2, 5000)
unreliable = fn -> if :rand.uniform(3) == 1, do: {:ok, "success"}, else: {:error, :failed} end

{_final_cb, _results} = Enum.reduce(1..5, {cb, []}, fn i, {current_cb, acc} ->
  IO.puts("Attempt #{i}:")
  case CircuitBreaker.call(current_cb, unreliable) do
    {:ok, result, updated_cb} ->
      IO.puts("  Success: #{result}")
      {updated_cb, [result | acc]}
    {:error, reason, updated_cb} ->
      IO.puts("  Failed: #{inspect(reason)}")
      {updated_cb, acc}
  end
end)

IO.puts("")

# ============================================================================
# Best Practices
# ============================================================================

IO.puts("""
--- Best Practices ---

1. Always pattern match on results:
   case Nous.run(agent, message) do
     {:ok, result} -> handle_success(result)
     {:error, reason} -> handle_error(reason)
   end

2. Retry transient failures:
   - Connection timeouts
   - Rate limits (with backoff)
   - Temporary service issues

3. Use fallback providers:
   - Local first (fast, free)
   - Cloud backup (reliable)
   - Different models for different needs

4. Handle tool errors gracefully:
   - Validate inputs
   - Return {:error, reason} for failures
   - Instruct agent how to handle failures

5. Prevent infinite loops:
   - Set max_iterations
   - Set timeouts
   - Use circuit breakers for external services

6. Log and monitor:
   - Use telemetry events
   - Track error rates
   - Alert on failures
""")
