# 🔧 Tool Development Guide

Complete guide for creating powerful, production-ready tools for Yggdrasil AI agents.

## Quick Start

**New to tool development?** Start with:
1. [custom_tools_guide.exs](../custom_tools_guide.exs) - Interactive tutorial
2. [templates/tool_agent.exs](../templates/tool_agent.exs) - Copy-paste starter
3. [by_feature/tools/](../by_feature/tools/) - Working examples

## Table of Contents

- [Tool Fundamentals](#tool-fundamentals)
- [Function Signature](#function-signature)
- [Input Validation](#input-validation)
- [Error Handling](#error-handling)
- [Security Considerations](#security-considerations)
- [Performance Guidelines](#performance-guidelines)
- [Testing Tools](#testing-tools)
- [Advanced Patterns](#advanced-patterns)
- [Production Deployment](#production-deployment)

## Tool Fundamentals

### What Are Tools?

Tools are Elixir functions that AI agents can call to perform actions:
- **Access external APIs** (weather, search, databases)
- **Perform calculations** (math, data processing)
- **File operations** (read, write, analyze)
- **System interactions** (shell commands, monitoring)

### How They Work

1. **AI decides** when to call tools based on user input
2. **Agent calls** your function with structured arguments
3. **Function executes** and returns results
4. **AI uses results** to continue the conversation

```elixir
# AI sees: "What's the weather in Paris?"
# AI calls: get_weather(%{"location" => "Paris"})
# Function returns: "Sunny, 22°C"
# AI responds: "The weather in Paris is sunny and 22°C"
```

## Function Signature

### Standard Pattern

All tools must use this exact signature:

```elixir
def my_tool(context, args) do
  # Your implementation
end
```

### Parameters

#### `context` - Runtime Context
```elixir
%{
  deps: %{                    # Dependencies from caller
    database: MyApp.Repo,
    user_id: 123,
    api_keys: %{...}
  },
  conversation_history: [...], # Previous messages
  request_id: "req_123",      # For logging/tracing
  timestamp: ~U[...]          # Request timestamp
}
```

#### `args` - AI-Provided Arguments
```elixir
%{
  "parameter_name" => "value",  # Always string keys
  "optional_param" => "value",
  # Note: AI determines these based on function name and usage
}
```

### Return Values

#### Success - Return Data Directly
```elixir
# String
"Weather in Paris: Sunny, 22°C"

# Number
42

# Map/Struct
%{temperature: 22, conditions: "sunny", humidity: 65}

# List
["result1", "result2", "result3"]
```

#### Failure - Return Error Tuple
```elixir
{:error, "Weather API is unavailable"}
{:error, "Invalid location: #{location}"}
{:error, %{code: 404, message: "City not found"}}
```

## Input Validation

### Required Parameters

```elixir
def search_database(_ctx, %{"query" => query}) when is_binary(query) and query != "" do
  # Implementation
end

def search_database(_ctx, args) do
  {:error, "query parameter is required and must be a non-empty string"}
end
```

### Type Validation with Guards

```elixir
def calculate(_ctx, %{"operation" => op, "a" => a, "b" => b})
    when is_number(a) and is_number(b) and op in ["add", "subtract", "multiply", "divide"] do
  # Safe to proceed
  perform_calculation(op, a, b)
end

def calculate(_ctx, args) do
  {:error, "Invalid arguments: #{inspect(args)}"}
end
```

### Comprehensive Validation

```elixir
def robust_validator(_ctx, args) do
  with {:ok, email} <- validate_email(args),
       {:ok, age} <- validate_age(args),
       {:ok, preferences} <- validate_preferences(args) do
    # All validations passed
    process_user_data(email, age, preferences)
  else
    {:error, reason} -> {:error, reason}
  end
end

defp validate_email(%{"email" => email}) do
  if String.contains?(email, "@") and String.contains?(email, ".") do
    {:ok, email}
  else
    {:error, "Invalid email format"}
  end
end

defp validate_email(_), do: {:error, "email parameter is required"}

defp validate_age(%{"age" => age}) when is_number(age) and age >= 0 and age <= 150 do
  {:ok, age}
end

defp validate_age(_), do: {:error, "age must be a number between 0 and 150"}
```

## Error Handling

### Error Categories

#### Validation Errors
```elixir
{:error, "Parameter 'location' is required"}
{:error, "Invalid email format: #{email}"}
{:error, "Price must be a positive number"}
```

#### External Service Errors
```elixir
case HTTPoison.get(url) do
  {:ok, %{status_code: 200, body: body}} ->
    body
  {:ok, %{status_code: 404}} ->
    {:error, "Resource not found"}
  {:ok, %{status_code: status}} ->
    {:error, "HTTP #{status}: Request failed"}
  {:error, %{reason: :timeout}} ->
    {:error, "Request timeout - service may be slow"}
  {:error, reason} ->
    {:error, "Network error: #{inspect(reason)}"}
end
```

#### System Errors
```elixir
case File.read(filepath) do
  {:ok, content} ->
    content
  {:error, :enoent} ->
    {:error, "File not found: #{filepath}"}
  {:error, :eacces} ->
    {:error, "Permission denied: #{filepath}"}
  {:error, reason} ->
    {:error, "File error: #{reason}"}
end
```

### Exception Handling

```elixir
def safe_tool(ctx, args) do
  try do
    risky_operation(args)
  rescue
    ArgumentError -> {:error, "Invalid arguments provided"}
    RuntimeError -> {:error, "Operation failed"}
    e -> {:error, "Unexpected error: #{Exception.message(e)}"}
  catch
    :throw, reason -> {:error, "Operation aborted: #{reason}"}
  end
end
```

## Security Considerations

### Input Sanitization

```elixir
def secure_file_reader(_ctx, %{"filepath" => path}) do
  # Prevent path traversal
  if String.contains?(path, ["../", "..\\"]) do
    {:error, "Path traversal not allowed"}
  end

  # Restrict to allowed directories
  safe_base = "/allowed/directory"
  if not String.starts_with?(Path.expand(path), safe_base) do
    {:error, "Access denied: path outside safe directory"}
  end

  File.read(path)
end
```

### Permission Checks

```elixir
def authorized_operation(ctx, args) do
  user_permissions = get_user_permissions(ctx)
  required_permission = :admin_access

  if required_permission in user_permissions do
    perform_sensitive_operation(args)
  else
    {:error, "Insufficient permissions: #{required_permission} required"}
  end
end

defp get_user_permissions(ctx) do
  ctx.deps[:user_permissions] || []
end
```

### Rate Limiting

```elixir
defmodule RateLimiter do
  use GenServer

  def check_rate_limit(user_id, limit_per_minute \\ 60) do
    GenServer.call(__MODULE__, {:check_limit, user_id, limit_per_minute})
  end

  # Implementation details...
end

def rate_limited_tool(ctx, args) do
  user_id = ctx.deps[:user_id]

  case RateLimiter.check_rate_limit(user_id) do
    :ok -> perform_operation(args)
    {:error, :rate_limited} -> {:error, "Rate limit exceeded. Please try again later."}
  end
end
```

## Performance Guidelines

### Response Time Limits

- **Target:** < 2 seconds for most tools
- **Maximum:** < 10 seconds (AI may timeout)
- **Long operations:** Use async patterns or streaming

### Memory Usage

```elixir
def memory_efficient_processor(_ctx, %{"data" => large_dataset}) do
  # Process in chunks instead of loading everything
  large_dataset
  |> Stream.chunk_every(1000)
  |> Stream.map(&process_chunk/1)
  |> Enum.reduce([], &combine_results/2)
end
```

### Caching

```elixir
defmodule ToolCache do
  @ttl 300_000  # 5 minutes

  def cached_api_call(url) do
    case :ets.lookup(:tool_cache, url) do
      [{^url, result, timestamp}] ->
        if System.system_time(:millisecond) - timestamp < @ttl do
          result
        else
          fetch_and_cache(url)
        end
      [] ->
        fetch_and_cache(url)
    end
  end

  defp fetch_and_cache(url) do
    result = HTTPoison.get!(url).body
    :ets.insert(:tool_cache, {url, result, System.system_time(:millisecond)})
    result
  end
end
```

## Testing Tools

### Unit Testing

```elixir
defmodule MyToolsTest do
  use ExUnit.Case

  describe "weather_tool/2" do
    test "returns weather for valid location" do
      ctx = %{}
      args = %{"location" => "Paris"}

      result = MyTools.weather_tool(ctx, args)

      assert is_binary(result)
      assert String.contains?(result, "Paris")
    end

    test "returns error for empty location" do
      ctx = %{}
      args = %{"location" => ""}

      result = MyTools.weather_tool(ctx, args)

      assert {:error, _reason} = result
    end

    test "handles missing location parameter" do
      ctx = %{}
      args = %{}

      result = MyTools.weather_tool(ctx, args)

      assert {:error, reason} = result
      assert String.contains?(reason, "location")
    end
  end
end
```

### Integration Testing

```elixir
defmodule ToolIntegrationTest do
  use ExUnit.Case

  test "tool works with AI agent" do
    agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
      tools: [&MyTools.weather_tool/2]
    )

    {:ok, result} = Yggdrasil.run(agent, "What's the weather in Tokyo?")

    assert String.contains?(result.output, "Tokyo")
    assert result.usage.tool_calls > 0
  end
end
```

### Performance Testing

```elixir
defmodule ToolBenchmark do
  def benchmark_tool(tool_function, args, iterations \\ 100) do
    ctx = %{}

    {time_microseconds, _results} = :timer.tc(fn ->
      Enum.map(1..iterations, fn _ ->
        tool_function.(ctx, args)
      end)
    end)

    avg_time_ms = time_microseconds / iterations / 1000
    IO.puts("Average execution time: #{Float.round(avg_time_ms, 2)}ms")
  end
end
```

## Advanced Patterns

### Tool Composition

```elixir
def composite_research_tool(ctx, %{"topic" => topic}) do
  with {:ok, search_results} <- search_web(ctx, %{"query" => topic}),
       {:ok, summary} <- summarize_content(ctx, %{"content" => search_results}),
       {:ok, questions} <- generate_questions(ctx, %{"summary" => summary}) do
    %{
      topic: topic,
      summary: summary,
      related_questions: questions,
      timestamp: DateTime.utc_now()
    }
  else
    {:error, reason} -> {:error, "Research failed: #{reason}"}
  end
end
```

### Context-Aware Tools

```elixir
def contextual_assistant(ctx, args) do
  # Analyze conversation history
  history = ctx.conversation_history || []
  user_preferences = ctx.deps[:user_preferences] || %{}

  # Adapt behavior based on context
  response_style = determine_response_style(history, user_preferences)

  # Generate contextual response
  generate_response(args, response_style)
end

defp determine_response_style(history, preferences) do
  cond do
    length(history) < 3 -> :formal
    Map.get(preferences, :style) == "casual" -> :casual
    detect_technical_conversation(history) -> :technical
    true -> :balanced
  end
end
```

### Streaming Tools

```elixir
def streaming_analysis_tool(ctx, args) do
  # For tools that produce streaming output
  # Note: This is a conceptual example - actual streaming
  # implementation depends on Yggdrasil's streaming capabilities

  {:stream, fn ->
    # Yield partial results as they become available
    Stream.unfold({:start, args}, fn
      {:start, args} ->
        result = perform_initial_analysis(args)
        {{:partial, result}, {:continue, args}}

      {:continue, args} ->
        result = perform_detailed_analysis(args)
        {{:final, result}, :done}

      :done -> nil
    end)
  end}
end
```

## Production Deployment

### Environment Configuration

```elixir
defmodule ProductionTools do
  @api_key System.get_env("WEATHER_API_KEY") ||
           raise "WEATHER_API_KEY environment variable is required"

  @rate_limits %{
    default: 100,
    premium: 1000
  }

  def weather_service(ctx, args) do
    user_tier = ctx.deps[:user_tier] || :default
    rate_limit = @rate_limits[user_tier]

    with :ok <- check_rate_limit(ctx.deps[:user_id], rate_limit),
         {:ok, weather} <- fetch_weather_data(args, @api_key) do
      format_weather_response(weather)
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Monitoring and Logging

```elixir
def monitored_tool(ctx, args) do
  start_time = System.monotonic_time(:millisecond)
  tool_name = "my_important_tool"

  # Emit telemetry event for monitoring
  :telemetry.execute([:yggdrasil, :tool, :start], %{}, %{
    tool: tool_name,
    user_id: ctx.deps[:user_id],
    args: sanitize_args_for_logging(args)
  })

  result = try do
    perform_tool_operation(args)
  rescue
    error ->
      Logger.error("Tool #{tool_name} failed", error: error, args: args)
      {:error, "Internal tool error"}
  end

  duration = System.monotonic_time(:millisecond) - start_time

  :telemetry.execute([:yggdrasil, :tool, :complete], %{duration: duration}, %{
    tool: tool_name,
    status: elem(result, 0),
    user_id: ctx.deps[:user_id]
  })

  result
end

defp sanitize_args_for_logging(args) do
  # Remove sensitive data from logs
  Map.drop(args, ["password", "api_key", "secret"])
end
```

### Health Checks

```elixir
def health_check_tool(_ctx, _args) do
  checks = [
    {:database, check_database_connection()},
    {:api, check_external_api()},
    {:cache, check_cache_system()},
    {:disk_space, check_disk_space()}
  ]

  failed_checks = Enum.filter(checks, fn {_name, status} -> status != :ok end)

  if failed_checks == [] do
    %{status: "healthy", timestamp: DateTime.utc_now()}
  else
    %{
      status: "degraded",
      failed_checks: failed_checks,
      timestamp: DateTime.utc_now()
    }
  end
end
```

## Common Patterns

### File Processing Tool
```elixir
def process_file(ctx, %{"filepath" => path, "operation" => op}) do
  with :ok <- validate_file_access(ctx, path),
       {:ok, content} <- File.read(path),
       {:ok, result} <- apply_operation(op, content) do
    result
  else
    {:error, reason} -> {:error, reason}
  end
end
```

### Database Query Tool
```elixir
def query_database(ctx, %{"query" => query, "params" => params}) do
  repo = ctx.deps[:database]

  case Ecto.Adapters.SQL.query(repo, query, params) do
    {:ok, %{rows: rows}} -> format_query_results(rows)
    {:error, reason} -> {:error, "Database error: #{inspect(reason)}"}
  end
end
```

### API Integration Tool
```elixir
def call_external_api(ctx, %{"endpoint" => endpoint, "data" => data}) do
  api_key = ctx.deps[:api_key]
  base_url = ctx.deps[:base_url]

  case HTTPoison.post("#{base_url}/#{endpoint}", Jason.encode!(data), [
    {"Authorization", "Bearer #{api_key}"},
    {"Content-Type", "application/json"}
  ]) do
    {:ok, %{status_code: 200, body: body}} -> Jason.decode!(body)
    {:ok, %{status_code: status}} -> {:error, "API returned #{status}"}
    {:error, reason} -> {:error, "Network error: #{inspect(reason)}"}
  end
end
```

## Best Practices Summary

### ✅ Do This
- Validate all inputs thoroughly
- Use descriptive error messages
- Handle all failure modes gracefully
- Keep responses concise but informative
- Add comprehensive documentation
- Test tools independently
- Monitor performance and errors
- Follow security best practices

### ❌ Avoid This
- Returning complex nested structures
- Long-running operations without timeouts
- Ignoring error cases
- Exposing sensitive information in errors
- Performing dangerous operations without validation
- Blocking operations without async patterns

## Next Steps

1. **Start with examples**: Try [custom_tools_guide.exs](../custom_tools_guide.exs)
2. **Use templates**: Copy [templates/tool_agent.exs](../templates/tool_agent.exs)
3. **Study production tools**: Check [trading_desk/](../trading_desk/)
4. **Read related guides**:
   - [best_practices.md](best_practices.md) - Production deployment
   - [troubleshooting.md](troubleshooting.md) - Common issues
5. **Join the community**: Share your tools and learn from others

---

**Remember**: Great tools make great AI agents. Invest time in making them robust, secure, and user-friendly!