# 🔧 Troubleshooting Guide

Common issues and solutions for Nous AI development and deployment.

## Quick Diagnostics

**Having issues?** Start here:
1. Check [Connection Problems](#connection-problems) - Most common issues
2. Run [Health Check Script](#health-check-script) - Automated diagnostics
3. Enable [Debug Logging](#debug-logging) - See what's happening
4. Try [Minimal Test](#minimal-test-case) - Isolate the problem

## Table of Contents

- [Connection Problems](#connection-problems)
- [API Key Issues](#api-key-issues)
- [Tool Failures](#tool-failures)
- [Performance Issues](#performance-issues)
- [Memory & Resource Issues](#memory--resource-issues)
- [Configuration Problems](#configuration-problems)
- [Development Issues](#development-issues)
- [Production Troubleshooting](#production-troubleshooting)

## Connection Problems

### Issue: "Connection refused" or "econnrefused"

**Symptoms:**
```
** (MatchError) no match of right hand side value:
   {:error, %HTTPoison.Error{reason: :econnrefused}}
```

**Solutions:**

#### For Local Models (LM Studio)
```bash
# 1. Check if LM Studio is running
curl http://localhost:1234/v1/models

# 2. If not running:
# - Open LM Studio
# - Go to "Local Server" tab
# - Load a model (e.g., qwen3-vl-4b-thinking-mlx)
# - Click "Start Server"

# 3. Verify server is responding
curl http://localhost:1234/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-vl-4b-thinking-mlx","prompt":"test","max_tokens":5}'
```

#### For Cloud Providers
```elixir
# Test API connectivity
case HTTPoison.get("https://api.anthropic.com/v1/messages",
                   [{"Authorization", "Bearer #{api_key}"}]) do
  {:ok, response} -> IO.inspect(response.status_code)
  {:error, reason} -> IO.inspect(reason)
end
```

### Issue: "Timeout" or Request Hangs

**Symptoms:**
- Requests never return
- Process hangs indefinitely
- Timeout errors after 30+ seconds

**Solutions:**

```elixir
# 1. Set explicit timeouts
agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
  http_options: [
    timeout: 30_000,      # 30 seconds
    recv_timeout: 30_000
  ]
)

# 2. For long-running operations, use streaming
{:ok, stream} = Nous.run_stream(agent, long_prompt)

# 3. Implement timeout wrapper
def run_with_timeout(agent, prompt, timeout_ms \\ 60_000) do
  task = Task.async(fn -> Nous.run(agent, prompt) end)

  case Task.yield(task, timeout_ms) do
    {:ok, result} -> result
    nil ->
      Task.shutdown(task, :brutal_kill)
      {:error, :timeout}
  end
end
```

### Issue: SSL/TLS Certificate Errors

**Symptoms:**
```
{:error, %HTTPoison.Error{reason: {:tls_alert, {:certificate_verify_failed, ...}}}}
```

**Solutions:**

```elixir
# For development only - DO NOT use in production
agent = Nous.new("openai:gpt-4",
  http_options: [
    ssl: [{:verify, :verify_none}]  # DEVELOPMENT ONLY
  ]
)

# For production - update certificates
# On Ubuntu/Debian:
sudo apt-get update && sudo apt-get install ca-certificates

# On macOS:
brew install ca-certificates

# In Docker:
RUN apk add --no-cache ca-certificates
```

## API Key Issues

### Issue: "Invalid API Key" or 401 Unauthorized

**Symptoms:**
- 401 HTTP status codes
- "Invalid API key" error messages
- Authentication failures

**Diagnostic Steps:**

```bash
# 1. Check if API key is set
echo $ANTHROPIC_API_KEY
echo $OPENAI_API_KEY

# 2. Verify key format
# Anthropic: sk-ant-api03-...
# OpenAI: sk-...
# Gemini: AI...

# 3. Test key directly
curl -X POST https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
  -d '{
    "model": "claude-3-sonnet-20240229",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 10
  }'
```

**Solutions:**

```elixir
# 1. Proper environment variable setup
# In your shell startup file (.bashrc, .zshrc):
export ANTHROPIC_API_KEY="sk-ant-your-actual-key"
export OPENAI_API_KEY="sk-your-actual-key"

# 2. Runtime configuration in Elixir
config :nous,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY") ||
    raise("ANTHROPIC_API_KEY environment variable not set")

# 3. Validate API keys at startup
defmodule MyApp.APIKeyValidator do
  def validate_keys! do
    required_keys = [
      {"ANTHROPIC_API_KEY", ~r/^sk-ant-/},
      {"OPENAI_API_KEY", ~r/^sk-/}
    ]

    Enum.each(required_keys, fn {env_var, pattern} ->
      case System.get_env(env_var) do
        nil ->
          raise "Missing required environment variable: #{env_var}"
        key ->
          unless Regex.match?(pattern, key) do
            raise "Invalid format for #{env_var}"
          end
      end
    end)
  end
end
```

### Issue: Rate Limiting (429 Too Many Requests)

**Symptoms:**
```
{:error, %HTTPoison.Error{status_code: 429}}
```

**Solutions:**

```elixir
defmodule RateLimitHandler do
  def run_with_backoff(agent, prompt, max_retries \\ 3) do
    attempt_with_exponential_backoff(agent, prompt, 1, max_retries)
  end

  defp attempt_with_exponential_backoff(agent, prompt, attempt, max_retries) do
    case Nous.run(agent, prompt) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{status_code: 429}} when attempt <= max_retries ->
        delay = min(1000 * :math.pow(2, attempt), 30_000)
        IO.puts("Rate limited, waiting #{round(delay)}ms...")
        Process.sleep(round(delay))
        attempt_with_exponential_backoff(agent, prompt, attempt + 1, max_retries)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

## Tool Failures

### Issue: "Tool not found" or Function Undefined

**Symptoms:**
- AI tries to call tools that don't exist
- `UndefinedFunctionError`
- Tools not being recognized

**Diagnostic Steps:**

```elixir
# 1. Verify tool is properly defined
defmodule MyTools do
  @doc "Get weather information"  # Documentation helps AI understand
  def get_weather(_ctx, %{"location" => location}) do
    "Weather in #{location}: Sunny, 22°C"
  end
end

# 2. Check tool is added to agent
agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
  tools: [&MyTools.get_weather/2]  # Must be function reference
)

# 3. Test tool directly
MyTools.get_weather(%{}, %{"location" => "Paris"})
```

**Solutions:**

```elixir
# 1. Correct function signature (always context, args)
def correct_tool(context, args) do
  # Implementation
end

# 2. Proper error handling
def robust_tool(_ctx, args) do
  case Map.get(args, "required_param") do
    nil -> {:error, "required_param is missing"}
    value -> process_value(value)
  end
end

# 3. Validate tools at startup
defmodule ToolValidator do
  def validate_tools(tools) do
    Enum.each(tools, fn tool_ref ->
      {module, function, arity} = Function.info(tool_ref, :mfa)

      unless arity == 2 do
        raise "Tool #{module}.#{function} must have arity 2 (context, args)"
      end

      # Test with empty args
      case apply(module, function, [%{}, %{}]) do
        {:error, _} -> :ok  # Expected for empty args
        _ -> :ok
      rescue
        error -> raise "Tool #{module}.#{function} validation failed: #{inspect(error)}"
      end
    end)
  end
end
```

### Issue: Tool Returns Invalid Data

**Symptoms:**
- AI gets confused by tool responses
- "Cannot process tool result" errors
- Malformed JSON or data structures

**Solutions:**

```elixir
# 1. Return simple data types
def good_tool(_ctx, args) do
  # ✅ Good: Simple string
  "Weather in Paris: Sunny, 22°C"

  # ✅ Good: Simple map
  %{temperature: 22, condition: "sunny"}

  # ❌ Bad: Complex nested structure
  %{
    data: %{
      weather: %{
        location: %{...},
        details: %{...}
      }
    }
  }
end

# 2. Sanitize output
def sanitized_tool(_ctx, args) do
  result = fetch_external_data(args)

  # Remove problematic characters
  result
  |> String.replace(~r/[^\x00-\x7F]/, "")  # Remove non-ASCII
  |> String.slice(0, 1000)  # Limit length
end

# 3. Validate return values
def validated_tool(_ctx, args) do
  result = process_request(args)

  case validate_tool_result(result) do
    :ok -> result
    {:error, reason} -> {:error, "Tool result invalid: #{reason}"}
  end
end

defp validate_tool_result(result) do
  cond do
    is_binary(result) and String.valid?(result) -> :ok
    is_number(result) -> :ok
    is_map(result) and map_size(result) <= 10 -> :ok
    is_list(result) and length(result) <= 100 -> :ok
    true -> {:error, "Unsupported result type or too large"}
  end
end
```

## Performance Issues

### Issue: Slow Response Times

**Symptoms:**
- Requests take > 10 seconds
- UI becomes unresponsive
- Timeouts in production

**Diagnostic Steps:**

```elixir
# 1. Measure performance
def timed_run(agent, prompt) do
  start_time = System.monotonic_time(:millisecond)

  result = case Nous.run(agent, prompt) do
    {:ok, response} -> response
    {:error, reason} -> reason
  end

  end_time = System.monotonic_time(:millisecond)
  duration = end_time - start_time

  IO.puts("Request took #{duration}ms")
  IO.puts("Tokens used: #{result.usage.total_tokens rescue 'N/A'}")

  result
end

# 2. Profile token usage
def analyze_token_usage(agent, prompt) do
  {:ok, result} = Nous.run(agent, prompt)

  IO.puts("Input tokens: #{result.usage.input_tokens}")
  IO.puts("Output tokens: #{result.usage.output_tokens}")
  IO.puts("Total tokens: #{result.usage.total_tokens}")
  IO.puts("Tool calls: #{result.usage.tool_calls}")

  # Check if context is too long
  if result.usage.input_tokens > 10_000 do
    IO.puts("⚠️  High input token count - consider trimming context")
  end
end
```

**Solutions:**

```elixir
# 1. Optimize prompts
def optimized_prompt(verbose_prompt) do
  # Instead of: "Please provide a very detailed, comprehensive analysis..."
  # Use: "Analyze and summarize key points:"
  String.replace(verbose_prompt, ~r/very detailed|comprehensive|thorough/, "")
end

# 2. Use streaming for long responses
def handle_long_query(agent, complex_query) do
  {:ok, stream} = Nous.run_stream(agent, complex_query)

  stream
  |> Stream.each(fn
    {:text_delta, text} -> send_to_ui(text)
    {:finish, _} -> complete_response()
  end)
  |> Stream.run()
end

# 3. Implement caching
defmodule ResponseCache do
  def cached_run(agent, prompt) do
    cache_key = generate_cache_key(prompt, agent.model)

    case get_cached_response(cache_key) do
      {:hit, response} -> response
      :miss ->
        response = Nous.run(agent, prompt)
        cache_response(cache_key, response)
        response
    end
  end
end
```

### Issue: High Memory Usage

**Symptoms:**
- Process memory keeps growing
- Out of memory errors
- System becomes slow

**Solutions:**

```elixir
# 1. Limit conversation history
def trim_conversation_history(messages, max_messages \\ 20) do
  if length(messages) > max_messages do
    # Keep system messages + recent messages
    system_messages = Enum.filter(messages, & &1.role == "system")
    recent_messages = Enum.take(messages, -max_messages)

    Enum.uniq(system_messages ++ recent_messages)
  else
    messages
  end
end

# 2. Clean up after each request
def handle_request_with_cleanup(request) do
  try do
    result = process_request(request)
    {:ok, result}
  after
    # Force garbage collection
    :erlang.garbage_collect()
  end
end

# 3. Monitor memory usage
def memory_aware_processing(data) do
  if :erlang.memory(:total) > 1_000_000_000 do  # 1GB
    Logger.warning("High memory usage detected")
    :erlang.garbage_collect()
    Process.sleep(100)  # Brief pause
  end

  process_data(data)
end
```

## Configuration Problems

### Issue: Model Not Found or Unsupported

**Symptoms:**
- "Model not available" errors
- Unexpected model behavior
- Configuration not being loaded

**Solutions:**

```elixir
# 1. Verify model availability
def check_model_availability(model_string) do
  case String.split(model_string, ":") do
    ["lmstudio", model_name] ->
      # Check if LM Studio has the model loaded
      case HTTPoison.get("http://localhost:1234/v1/models") do
        {:ok, %{body: body}} ->
          models = Jason.decode!(body)["data"]
          if Enum.any?(models, &String.contains?(&1["id"], model_name)) do
            :ok
          else
            {:error, "Model #{model_name} not loaded in LM Studio"}
          end
        _ -> {:error, "LM Studio not running"}
      end

    [provider, model_name] ->
      # For cloud providers, models are usually available
      # but check provider-specific model lists
      :ok
  end
end

# 2. Configuration validation
defmodule ConfigValidator do
  def validate_config do
    required_configs = [
      :anthropic_api_key,
      :openai_api_key,
      :default_model
    ]

    missing = Enum.filter(required_configs, fn key ->
      is_nil(Application.get_env(:myapp, key))
    end)

    if missing != [] do
      raise "Missing configuration: #{inspect(missing)}"
    end
  end
end

# 3. Runtime configuration
config :nous,
  default_model: System.get_env("DEFAULT_MODEL", "lmstudio:qwen3-vl-4b-thinking-mlx"),
  providers: %{
    anthropic: [
      api_key: System.get_env("ANTHROPIC_API_KEY"),
      base_url: "https://api.anthropic.com"
    ],
    openai: [
      api_key: System.get_env("OPENAI_API_KEY"),
      base_url: "https://api.openai.com"
    ]
  }
```

## Development Issues

### Issue: Hot Code Reloading Problems

**Symptoms:**
- Changes not reflected after recompilation
- Stale agent configurations
- Inconsistent behavior in development

**Solutions:**

```elixir
# 1. Proper module reloading
defmodule DevHelpers do
  def reload_agent_modules do
    # Recompile and reload modules
    IEx.Helpers.recompile()

    # Clear any cached agents
    :persistent_term.erase(:cached_agents)

    # Restart any GenServers holding agent state
    Supervisor.terminate_child(MyApp.Supervisor, MyApp.AgentManager)
    Supervisor.restart_child(MyApp.Supervisor, MyApp.AgentManager)
  end
end

# 2. Development-friendly configuration
if Mix.env() == :dev do
  config :nous,
    cache_enabled: false,  # Disable caching in development
    debug_logging: true
end

# 3. Clear state between tests
defmodule MyAppTest do
  use ExUnit.Case

  setup do
    # Clear any global state
    :ets.delete_all_objects(:agent_cache)
    :ok
  end
end
```

### Issue: LiveView Integration Problems

**Symptoms:**
- WebSocket connections dropping
- Agent state not syncing with UI
- Memory leaks in LiveView processes

**Solutions:**

```elixir
# 1. Proper process linking
def mount(_params, _session, socket) do
  # Link agent to LiveView process
  {:ok, agent_pid} = MyApp.AgentManager.start_agent(
    user_id: socket.assigns.user_id,
    owner_pid: self()  # Link to LiveView
  )

  Process.monitor(agent_pid)

  {:ok, assign(socket, agent_pid: agent_pid)}
end

# 2. Handle agent process deaths
def handle_info({:DOWN, _ref, :process, agent_pid, reason}, socket) do
  Logger.warning("Agent process died: #{inspect(reason)}")

  # Attempt to restart agent
  case MyApp.AgentManager.restart_agent(socket.assigns.user_id) do
    {:ok, new_agent_pid} ->
      Process.monitor(new_agent_pid)
      {:noreply, assign(socket, agent_pid: new_agent_pid)}

    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Agent unavailable")}
  end
end

# 3. Async message handling
def handle_event("send_message", %{"message" => message}, socket) do
  # Don't block LiveView process
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    case MyApp.AgentManager.chat(socket.assigns.agent_pid, message) do
      {:ok, response} ->
        send(socket.transport_pid, {:agent_response, response})
      {:error, error} ->
        send(socket.transport_pid, {:agent_error, error})
    end
  end)

  {:noreply, socket}
end
```

## Production Troubleshooting

### Issue: High Error Rates in Production

**Diagnostic Steps:**

```bash
# 1. Check logs
tail -f /var/log/myapp/error.log | grep -i "agent\|nous"

# 2. Check system resources
htop
df -h
free -h

# 3. Test external dependencies
curl -I https://api.anthropic.com/v1/messages
curl -I https://api.openai.com/v1/completions
```

**Monitoring Setup:**

```elixir
defmodule ProductionMonitoring do
  def setup_alerts do
    # Set up alerts for:
    alerts = [
      %{
        name: "high_error_rate",
        condition: "error_rate > 0.05",  # 5%
        duration: "5m"
      },
      %{
        name: "slow_responses",
        condition: "response_time_p95 > 30s",
        duration: "2m"
      },
      %{
        name: "ai_provider_down",
        condition: "provider_success_rate < 0.8",
        duration: "1m"
      }
    ]

    Enum.each(alerts, &configure_alert/1)
  end

  def health_check do
    checks = %{
      database: check_database(),
      ai_providers: check_ai_providers(),
      external_apis: check_external_apis(),
      memory_usage: check_memory_usage(),
      error_rate: check_error_rate()
    }

    overall_status = if Enum.all?(checks, fn {_, status} -> status == :ok end) do
      :healthy
    else
      :degraded
    end

    %{status: overall_status, checks: checks, timestamp: DateTime.utc_now()}
  end
end
```

## Debug Logging

Enable detailed logging to understand what's happening:

```elixir
# 1. Enable debug logging
Logger.configure(level: :debug)

# 2. Add custom logging to your agents
defmodule DebugAgent do
  def run_with_debug(agent, prompt) do
    Logger.debug("Starting agent run", prompt: prompt, model: agent.model)

    start_time = System.monotonic_time(:millisecond)

    result = case Nous.run(agent, prompt) do
      {:ok, response} ->
        Logger.debug("Agent run successful",
          tokens: response.usage.total_tokens,
          tool_calls: response.usage.tool_calls
        )
        response

      {:error, reason} ->
        Logger.error("Agent run failed", error: inspect(reason))
        reason
    end

    duration = System.monotonic_time(:millisecond) - start_time
    Logger.debug("Agent run completed", duration_ms: duration)

    result
  end
end

# 3. Debug tool execution
def debug_tool(ctx, args) do
  Logger.debug("Tool called", tool: __MODULE__, args: args)

  try do
    result = perform_tool_operation(args)
    Logger.debug("Tool succeeded", result: inspect(result))
    result
  rescue
    error ->
      Logger.error("Tool failed", error: inspect(error), stacktrace: __STACKTRACE__)
      {:error, "Tool execution failed"}
  end
end
```

## Health Check Script

Create an automated diagnostic script:

```elixir
#!/usr/bin/env elixir

defmodule HealthCheck do
  def run_full_diagnostics do
    IO.puts("🔍 Nous Health Check")
    IO.puts("========================")

    checks = [
      {"Environment Variables", &check_environment/0},
      {"Local LM Studio", &check_lm_studio/0},
      {"AI Provider APIs", &check_ai_providers/0},
      {"Network Connectivity", &check_network/0},
      {"System Resources", &check_resources/0}
    ]

    results = Enum.map(checks, fn {name, check_fn} ->
      IO.puts("\n#{name}:")
      result = check_fn.()
      {name, result}
    end)

    print_summary(results)
  end

  defp check_environment do
    env_vars = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY"]

    Enum.each(env_vars, fn var ->
      case System.get_env(var) do
        nil -> IO.puts("  ❌ #{var} not set")
        key -> IO.puts("  ✅ #{var} present (#{String.slice(key, 0, 10)}...)")
      end
    end)

    :ok
  end

  defp check_lm_studio do
    case HTTPoison.get("http://localhost:1234/v1/models") do
      {:ok, %{status_code: 200, body: body}} ->
        models = Jason.decode!(body)["data"]
        IO.puts("  ✅ LM Studio running with #{length(models)} models")

      {:error, %{reason: :econnrefused}} ->
        IO.puts("  ❌ LM Studio not running")
        IO.puts("     Start LM Studio and load a model")

      {:error, reason} ->
        IO.puts("  ❌ LM Studio error: #{inspect(reason)}")
    end
  rescue
    _ -> IO.puts("  ❌ HTTPoison not available")
  end

  defp check_ai_providers do
    providers = [
      {"Anthropic", "https://api.anthropic.com/v1/messages", System.get_env("ANTHROPIC_API_KEY")},
      {"OpenAI", "https://api.openai.com/v1/completions", System.get_env("OPENAI_API_KEY")}
    ]

    Enum.each(providers, fn {name, url, api_key} ->
      if api_key do
        case HTTPoison.get(url, [{"Authorization", "Bearer #{api_key}"}]) do
          {:ok, %{status_code: status}} when status < 500 ->
            IO.puts("  ✅ #{name} API reachable")
          {:error, reason} ->
            IO.puts("  ❌ #{name} API error: #{inspect(reason)}")
        end
      else
        IO.puts("  ⚠️  #{name} API key not configured")
      end
    end)
  rescue
    _ -> IO.puts("  ❌ Network check failed")
  end

  defp check_network do
    case :inet.gethostbyname('google.com') do
      {:ok, _} -> IO.puts("  ✅ Internet connectivity OK")
      {:error, _} -> IO.puts("  ❌ No internet connectivity")
    end
  end

  defp check_resources do
    memory = :erlang.memory()
    total_mb = div(memory[:total], 1024 * 1024)
    IO.puts("  Memory usage: #{total_mb}MB")

    if total_mb > 1000 do
      IO.puts("  ⚠️  High memory usage")
    else
      IO.puts("  ✅ Memory usage normal")
    end
  end

  defp print_summary(results) do
    IO.puts("\n" <> String.duplicate("=", 40))
    IO.puts("Summary:")

    passed = Enum.count(results, fn {_, result} -> result == :ok end)
    total = length(results)

    IO.puts("#{passed}/#{total} checks passed")

    if passed == total do
      IO.puts("🎉 All systems operational!")
    else
      IO.puts("⚠️  Some issues detected - see details above")
    end
  end
end

# Run the health check
HealthCheck.run_full_diagnostics()
```

## Minimal Test Case

When reporting issues, provide a minimal test case:

```elixir
#!/usr/bin/env elixir

# Minimal test case for troubleshooting
# Replace with your specific issue

# 1. Simple agent test
IO.puts("Testing basic agent creation...")

agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
  instructions: "You are a helpful assistant"
)

case Nous.run(agent, "Say hello") do
  {:ok, result} ->
    IO.puts("✅ Basic test passed: #{result.output}")
  {:error, reason} ->
    IO.puts("❌ Basic test failed: #{inspect(reason)}")
end

# 2. Tool test (if relevant)
defmodule TestTool do
  def simple_tool(_ctx, args) do
    "Tool called with: #{inspect(args)}"
  end
end

IO.puts("\nTesting tool functionality...")

tool_agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
  tools: [&TestTool.simple_tool/2]
)

case Nous.run(tool_agent, "Use the simple tool with test data") do
  {:ok, result} ->
    IO.puts("✅ Tool test passed")
    IO.puts("Tools called: #{result.usage.tool_calls}")
  {:error, reason} ->
    IO.puts("❌ Tool test failed: #{inspect(reason)}")
end
```

## Getting Help

When seeking help, include:

1. **Environment details:**
   - Elixir version: `elixir --version`
   - Nous version
   - Operating system
   - AI provider being used

2. **Error messages:**
   - Complete error with stacktrace
   - Debug logs if available

3. **Minimal reproduction case:**
   - Simplest code that reproduces the issue
   - Configuration being used

4. **What you've tried:**
   - Solutions attempted
   - Results of diagnostic steps

5. **Expected vs actual behavior:**
   - What should happen
   - What actually happens

---

**Still stuck?** Check the [GitHub issues](https://github.com/nyo16/nous/issues) or create a new issue with your diagnostic information.