# Nous AI Framework

Elixir AI agent framework with multi-provider LLM support.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Nous.Agent                              │
│  (Configuration: instructions, model, tools, callbacks)         │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Nous.AgentRunner                           │
│  (Execution loop: tool calls, context updates, iterations)      │
└──────────────────────────┬──────────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
    ┌───────────┐   ┌───────────┐   ┌───────────────┐
    │  Provider │   │   Tools   │   │    Context    │
    │ (LLM API) │   │ (Actions) │   │  (State/Deps) │
    └───────────┘   └───────────┘   └───────────────┘
```

## Key Modules

| Module | Purpose |
|--------|---------|
| `Nous` | Main API - `new/2`, `run/3` |
| `Nous.Agent` | Agent struct and configuration |
| `Nous.Agent.Context` | Unified execution context with messages, deps, usage |
| `Nous.AgentRunner` | Execution loop, tool handling, context merging |
| `Nous.Tool` | Tool definitions and schema generation |
| `Nous.Tool.ContextUpdate` | Structured context mutations from tools |
| `Nous.RunContext` | Simplified context passed to tools |

## Tool Development

### Tool Function Signature

```elixir
def my_tool(ctx, args) do
  # ctx: %Nous.RunContext{deps: map(), retry: integer(), usage: Usage.t()}
  # args: %{"param_name" => value} - string keys from LLM

  %{
    success: true,
    result: "value",
    __update_context__: %{key: new_value}  # Optional: updates ctx.deps
  }
end
```

### Pattern: Flexible Parameter Names

Support multiple parameter names for AI flexibility:

```elixir
text = Map.get(args, "text") || Map.get(args, "content") || Map.get(args, "message")
```

### Pattern: Context Updates (Legacy)

Return `__update_context__` map to modify deps:

```elixir
%{
  success: true,
  __update_context__: %{memories: updated_memories}
}
```

### Pattern: Context Updates (New)

Use `ContextUpdate` struct for explicit updates:

```elixir
alias Nous.Tool.ContextUpdate

{:ok, %{success: true},
 ContextUpdate.new() |> ContextUpdate.set(:memories, updated_memories)}
```

### Pattern: Error Returns

```elixir
%{
  success: false,
  error: "Descriptive error message"
}
```

## Testing Conventions

### Tool Tests

```elixir
defmodule Nous.Tools.MyToolsTest do
  use ExUnit.Case, async: true

  alias Nous.Tools.MyTools
  alias Nous.RunContext

  describe "my_function/2" do
    setup do
      ctx = RunContext.new(%{initial_data: []})
      {:ok, ctx: ctx}
    end

    test "succeeds with valid input", %{ctx: ctx} do
      result = MyTools.my_function(ctx, %{"param" => "value"})

      assert result.success == true
      assert result.__update_context__.key == expected_value
    end

    test "fails with missing required param", %{ctx: ctx} do
      result = MyTools.my_function(ctx, %{})

      assert result.success == false
      assert result.error =~ "required"
    end
  end
end
```

### Running Tests

```bash
mix test                              # All tests
mix test test/path/to/test.exs        # Specific file
mix test --only tag:value             # Tagged tests
```

## File Organization

```
lib/nous/
├── agent.ex              # Agent struct
├── agent_runner.ex       # Execution loop
├── agent/
│   ├── context.ex        # Context struct
│   └── context_update.ex # Context mutations
├── tools/
│   ├── todo_tools.ex     # Example: task tracking
│   └── memory_tools.ex   # Example: memory system
├── memory/               # Memory subsystem
│   ├── memory.ex         # Memory struct
│   ├── store.ex          # Storage behaviour
│   ├── search.ex         # Search behaviour
│   ├── manager.ex        # Per-agent GenServer
│   ├── supervisor.ex     # DynamicSupervisor
│   └── stores/           # Storage backends
│       └── agent_store.ex
└── tool/
    ├── context_update.ex # ContextUpdate struct
    └── validator.ex      # Input validation
```

## Dependencies via ctx.deps

Tools access external resources through `ctx.deps`:

```elixir
# In Nous.run call
{:ok, result} = Nous.run(agent, prompt, deps: %{
  database: MyApp.Repo,
  memory_manager: memory_pid,
  api_client: client
})

# In tool function
def search(ctx, %{"query" => query}) do
  repo = ctx.deps[:database]
  results = repo.search(query)
  %{success: true, results: results}
end
```

## Common Patterns

### Generate Unique IDs

```elixir
defp generate_id do
  System.unique_integer([:positive, :monotonic])
end
```

### Find and Replace in List

```elixir
defp find_item(items, id), do: Enum.find(items, &(&1.id == id))

defp replace_item(items, id, new_item) do
  Enum.map(items, fn item ->
    if item.id == id, do: new_item, else: item
  end)
end
```

### Optional Updates

```elixir
defp maybe_update(map, _key, nil), do: map
defp maybe_update(map, key, value), do: Map.put(map, key, value)
```
