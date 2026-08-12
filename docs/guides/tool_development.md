# 🔧 Tool Development Guide

Complete guide for creating powerful, production-ready tools for Nous AI agents.

## Quick Start

**New to tool development?** Start with:
1. [02_with_tools.exs](https://github.com/nyo16/nous/blob/master/examples/02_with_tools.exs) - A first tool in ~30 lines
2. [07_module_tools.exs](https://github.com/nyo16/nous/blob/master/examples/07_module_tools.exs) - Module tools with `Nous.Tool.Behaviour`
3. [08_tool_testing.exs](https://github.com/nyo16/nous/blob/master/examples/08_tool_testing.exs) - Mock and spy tools with `Nous.Tool.Testing`

## Table of Contents

- [Tool Fundamentals](#tool-fundamentals)
- [Function Signature](#function-signature)
- [Input Validation](#input-validation)
- [Error Handling](#error-handling)
- [Security Considerations](#security-considerations)
- [Performance Guidelines](#performance-guidelines)
- [Parallel Tool Calls](#parallel-tool-calls)
- [Built-in Todo Tools](#built-in-todo-tools)
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

## Parallel Tool Calls

When a single model response contains several tool calls, Nous executes them one
at a time by default: each call finishes its whole pipeline before the next one
starts. Setting `parallel_tool_calls: true` on the agent fans the executions out
instead.

```elixir
agent =
  Nous.new("openai:gpt-4o",
    tools: [&MyTools.fetch_user/2, &MyTools.fetch_orders/2, &MyTools.fetch_invoices/2],
    parallel_tool_calls: true
  )
```

- **Default: `false`.** `%Nous.Agent{}` is built with `parallel_tool_calls: false`
  and only flips when you pass the option to `Nous.new/2` (`Nous.Agent.new/2`).
- **Applies when** one response carries **two or more** real tool calls. A single
  call — or a response whose only calls are the synthetic ones used for
  structured output — takes the sequential path unchanged.

### What runs concurrently, and what does not

Only the tool executions fan out. Every ordering-sensitive stage stays sequential,
in the model's call order:

1. **Before the fan-out**, per call: the `:on_tool_call` callback, the
   invalid-arguments short-circuit, the `:pre_tool_use` hook, and the
   permission/approval check.
2. **Concurrently**: the approved tool functions, supervised by
   `Nous.TaskSupervisor`.
3. **After the fan-out**, in the original call order: the `:post_tool_use` hook,
   the `:on_tool_response` callback, the agent behaviour's `:after_tool`, and the
   dependency merge.

Tool result messages are appended in the original call order, because providers
require results to line up with the calls they answer.

### When to enable it

Enable it when a turn's tools are independent and I/O-bound: separate HTTP APIs,
separate database reads, unrelated file reads. A turn that issues three 900 ms
lookups then costs about one lookup instead of three.

Leave it off for cheap, CPU-bound tools. Fanning out three map lookups buys
nothing and adds process churn.

### The footgun: interleaved side effects

Tools cannot observe each other's context updates within a turn in *either* mode
— the run context is snapshotted before the tool loop — so `ctx` is not what
changes. What changes is **external** side effects: HTTP requests, database
writes, file writes and shell commands issued by different calls in the same turn
now interleave. `:pre_tool_use` hooks also see the pre-turn context rather than
the post-processing effects of earlier calls in the same batch.

So if a turn's tools depend on sequential side effects — `write_file` then
`run_tests`, `create_order` then `charge_card` — keep the default. That
dependency is precisely why the feature is opt-in.

### Timeouts and crashes

A parallel batch is bounded by a single per-call ceiling, taken as the largest
budget in the batch:

- a tool declaring a positive `timeout:` contributes `timeout * (retries + 1)`
  plus five seconds of headroom — a timeout raised inside `Nous.ToolExecutor`
  goes through the retry path, so every attempt may spend the full budget;
- a tool that declares no positive timeout contributes the module default of five
  minutes, which you can override globally:

```elixir
config :nous, parallel_tool_call_timeout_ms: :timer.minutes(2)
```

A call that blows the ceiling is killed and answered with a timeout tool result
for that call alone; a crashing call becomes a per-call tool error. Neither sinks
the rest of the batch or the turn.

## Built-in Todo Tools

`Nous.Tools.TodoTools` is the built-in task-tracking tool set. It lets an agent
break a multi-step job into todos, record progress, and keep the list in front of
itself instead of losing the plan halfway through a long run.

> **Not to be confused with** the `TodoTools` module defined inline in
> `examples/advanced/context_updates.exs` — that is a user-land, three-function
> demo of `Nous.Tool.ContextUpdate` that happens to share the name. The built-in
> module is `Nous.Tools.TodoTools`.

It is a plain function module (no `Nous.Tool.Behaviour`), so register the captures
you want:

```elixir
alias Nous.Tools.TodoTools

agent =
  Nous.new("openai:gpt-4o",
    instructions: "Plan before you act, and keep the todo list current.",
    enable_todos: true,
    tools: [
      &TodoTools.add_todo/2,
      &TodoTools.update_todo/2,
      &TodoTools.complete_todo/2,
      &TodoTools.list_todos/2
    ]
  )

{:ok, result} = Nous.run(agent, "Analyze this codebase and write a report", deps: %{todos: []})
```

### The five tools

| Function | Arguments | Notes |
|---|---|---|
| `add_todo/2` | `"text"` (also accepts `"title"` or `"description"`), optional `"status"`, `"priority"` | Defaults to `"pending"` / `"medium"`; errors if the text is missing or empty |
| `update_todo/2` | `"id"`, plus any of `"text"`, `"status"`, `"priority"` | Omitted fields are left alone |
| `complete_todo/2` | `"id"` | Sets `status` to `"completed"` and stamps `completed_at` |
| `delete_todo/2` | `"id"` | Removes the entry |
| `list_todos/2` | optional `"status"`, `"priority"` filters | Also returns `total` and `by_status` counts |

Statuses are `"pending"`, `"in_progress"` and `"completed"`; priorities are
`"low"`, `"medium"` and `"high"`. Each stored todo is a map with `:id` (a
process-unique positive integer), `:text`, `:status`, `:priority`, `:created_at`
and `:updated_at` ISO-8601 timestamps.

### Where the state lives

The list lives in `ctx.deps[:todos]`. Every mutating tool returns the full updated
list under `__update_context__`, which the runner merges back into the run's
dependencies after the tool call — so the next model iteration sees it (tools in
the *same* response still see the pre-turn snapshot, as above).

Passing `enable_todos: true` additionally renders the todos from `deps` into the
system prompt when the run context is built, grouped by status and followed by a
short usage note for the four tools above. Continuing a previous run from its
returned context keeps that run's original prompt, so pass `deps: %{todos: [...]}`
on the run that creates the context.

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
    agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
      tools: [&MyTools.weather_tool/2]
    )

    {:ok, result} = Nous.run(agent, "What's the weather in Tokyo?")

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
  # implementation depends on Nous's streaming capabilities

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
  :telemetry.execute([:nous, :tool, :start], %{}, %{
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

  :telemetry.execute([:nous, :tool, :complete], %{duration: duration}, %{
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

  case HTTPoison.post("#{base_url}/#{endpoint}", JSON.encode!(data), [
    {"Authorization", "Bearer #{api_key}"},
    {"Content-Type", "application/json"}
  ]) do
    {:ok, %{status_code: 200, body: body}} -> JSON.decode!(body)
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

1. **Start with examples**: Try [02_with_tools.exs](https://github.com/nyo16/nous/blob/master/examples/02_with_tools.exs)
2. **Move to module tools**: Copy [07_module_tools.exs](https://github.com/nyo16/nous/blob/master/examples/07_module_tools.exs)
3. **Study a production-shaped agent**: Read [19_coding_agent.exs](https://github.com/nyo16/nous/blob/master/examples/19_coding_agent.exs), which wires the built-in file and shell tools to permissions and session guardrails, or browse the [examples index](https://github.com/nyo16/nous/blob/master/examples/README.md)
4. **Read related guides**:
   - [best_practices.md](best_practices.md) - Production deployment
   - [troubleshooting.md](troubleshooting.md) - Common issues
5. **Join the community**: Share your tools and learn from others

---

**Remember**: Great tools make great AI agents. Invest time in making them robust, secure, and user-friendly!