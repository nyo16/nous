# Context & Dependencies

How state flows through the agent loop. Two context types serve different roles: `RunContext` (what tools see) and `Agent.Context` (internal loop state).

## RunContext

`Nous.RunContext` is the struct passed to every tool function during execution. It carries user-provided dependencies and runtime metadata.

### Struct Fields

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `deps` | `any()` | (required) | User-provided data: DB connections, API keys, session state |
| `retry` | `non_neg_integer()` | `0` | How many times this tool call has been retried |
| `usage` | `Usage.t()` | `%Usage{}` | Token and request counts so far |

### Passing deps to an agent

Provide a `deps` map when calling `Nous.run/3`. Everything in `deps` becomes available to every tool:

```elixir
deps = %{
  database: MyApp.Repo,
  user_id: 123,
  api_key: System.get_env("WEATHER_API_KEY")
}

{:ok, result} = Nous.run(agent, "Look up recent orders", deps: deps)
```

### Accessing deps in tools

The first argument to every tool function is the `RunContext`. Access deps as fields on `ctx.deps`:

```elixir
defmodule MyTools do
  def lookup_orders(ctx, %{"limit" => limit}) do
    repo = ctx.deps.database
    user_id = ctx.deps.user_id

    repo
    |> Ecto.Query.from(o in Order, where: o.user_id == ^user_id, limit: ^limit)
    |> repo.all()
    |> Enum.map(&Map.take(&1, [:id, :total, :status]))
  end
end
```

Wire it together:

```elixir
agent = Nous.new("openai:gpt-4",
  tools: [&MyTools.lookup_orders/2]
)

{:ok, result} = Nous.run(agent, "Show my last 5 orders",
  deps: %{database: MyApp.Repo, user_id: 42}
)
```

## ContextUpdate

Tools often need to modify the agent's deps mid-run -- for example, incrementing a counter or appending to a log. `Nous.Tool.ContextUpdate` provides a structured way to do this.

### Operations

| Operation | Function | Effect |
|-----------|----------|--------|
| Set | `ContextUpdate.set(update, :key, value)` | Replace a key's value |
| Merge | `ContextUpdate.merge(update, :key, %{...})` | Deep-merge into an existing map |
| Append | `ContextUpdate.append(update, :key, item)` | Append to a list (creates list if nil) |
| Delete | `ContextUpdate.delete(update, :key)` | Remove a key from deps |

### Returning a ContextUpdate from a tool

Return a three-element tuple `{:ok, result, context_update}` from your tool function. The agent runner applies the operations to `deps` after the tool completes:

```elixir
alias Nous.Tool.ContextUpdate

def increment_counter(ctx, _args) do
  count = (ctx.deps[:counter] || 0) + 1

  {:ok, %{count: count},
   ContextUpdate.new() |> ContextUpdate.set(:counter, count)}
end
```

### Chaining operations

Operations are applied in order, so you can chain multiple updates:

```elixir
def process_item(ctx, %{"item" => item}) do
  update =
    ContextUpdate.new()
    |> ContextUpdate.append(:processed_items, item)
    |> ContextUpdate.set(:last_processed, item)
    |> ContextUpdate.merge(:stats, %{total: (ctx.deps[:stats][:total] || 0) + 1})

  {:ok, %{processed: item}, update}
end
```

### Legacy pattern: `__update_context__`

Before `ContextUpdate` existed, tools returned a map with a special `__update_context__` key. This still works but `ContextUpdate` is preferred:

```elixir
# Legacy (still supported)
def add_note(ctx, %{"note" => note}) do
  notes = [note | ctx.deps[:notes] || []]
  %{success: true, __update_context__: %{notes: notes}}
end

# Preferred
def add_note(ctx, %{"note" => note}) do
  {:ok, %{success: true},
   ContextUpdate.new() |> ContextUpdate.append(:notes, note)}
end
```

## Walkthrough: Stateful Agent

Build an agent that tracks state across tool calls using `ContextUpdate`.

### Step 1: Create a counter tool

```elixir
defmodule StatefulTools do
  alias Nous.Tool.ContextUpdate

  @doc """
  Increment a named counter. Creates it at 0 if it doesn't exist.
  """
  def increment(ctx, %{"name" => name}) do
    counters = ctx.deps[:counters] || %{}
    new_value = Map.get(counters, name, 0) + 1
    updated = Map.put(counters, name, new_value)

    {:ok, %{counter: name, value: new_value},
     ContextUpdate.new() |> ContextUpdate.set(:counters, updated)}
  end

  @doc """
  Append a note to the agent's scratchpad.
  """
  def add_note(ctx, %{"text" => text}) do
    {:ok, %{added: text, total: length(ctx.deps[:notes] || []) + 1},
     ContextUpdate.new() |> ContextUpdate.append(:notes, text)}
  end

  @doc """
  Show the current counters and notes.
  """
  def show_state(ctx, _args) do
    %{
      counters: ctx.deps[:counters] || %{},
      notes: ctx.deps[:notes] || []
    }
  end
end
```

### Step 2: Wire up the agent

```elixir
agent = Nous.new("openai:gpt-4",
  system_prompt: """
  You have tools to track counters and notes.
  Use increment to count things and add_note to record observations.
  """,
  tools: [
    &StatefulTools.increment/2,
    &StatefulTools.add_note/2,
    &StatefulTools.show_state/2
  ]
)
```

### Step 3: Run and observe state evolving

```elixir
{:ok, result} = Nous.run(agent,
  "Count how many vowels are in the word 'elephant', " <>
  "incrementing a counter named 'vowels' for each one. " <>
  "Also add a note listing the vowels you found. " <>
  "Then show the final state.",
  deps: %{counters: %{}, notes: []}
)

# The agent will:
# 1. Call increment("vowels") three times (e, e, a)
# 2. Call add_note("Found vowels: e, e, a")
# 3. Call show_state() -> %{counters: %{"vowels" => 3}, notes: ["Found vowels: e, e, a"]}
```

Each tool call sees the updated deps from the previous call, so state accumulates naturally across the agent loop.

## Agent.Context (Advanced)

`Nous.Agent.Context` is the internal struct that accumulates all state across the agent loop. You rarely interact with it directly -- it powers the loop behind the scenes.

### Struct Fields

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `messages` | `[Message.t()]` | `[]` | Full conversation history |
| `tool_calls` | `[map()]` | `[]` | Record of all tool invocations |
| `system_prompt` | `String.t() \| nil` | `nil` | System prompt text |
| `deps` | `map()` | `%{}` | User dependencies (same as RunContext.deps) |
| `usage` | `Usage.t()` | `%Usage{}` | Accumulated token/request counts |
| `needs_response` | `boolean()` | `true` | Whether the loop should continue |
| `iteration` | `non_neg_integer()` | `0` | Current loop iteration |
| `max_iterations` | `non_neg_integer()` | `10` | Safety limit |
| `callbacks` | `map()` | `%{}` | Event handler functions |
| `notify_pid` | `pid() \| nil` | `nil` | PID for LiveView integration |
| `agent_name` | `String.t() \| nil` | `nil` | Name for telemetry/logging |
| `cancellation_check` | `fun() \| nil` | `nil` | Function to check for cancellation |
| `approval_handler` | `fun() \| nil` | `nil` | Human-in-the-loop approval |
| `active_skills` | `[Skill.t()]` | `[]` | Currently active skills |

### Creating a context

```elixir
ctx = Nous.Agent.Context.new(
  system_prompt: "You are a helpful assistant",
  deps: %{user_id: 42, session_id: "abc123"},
  max_iterations: 15,
  agent_name: "support_agent"
)
```

### Converting between RunContext and Agent.Context

The agent runner converts `Agent.Context` to `RunContext` before passing it to tools. You can do this conversion manually:

```elixir
# Agent.Context -> RunContext (for tool execution)
run_ctx = Nous.Agent.Context.to_run_context(agent_ctx)

# RunContext -> Agent.Context (for resuming a loop)
agent_ctx = Nous.Agent.Context.from_run_context(run_ctx,
  system_prompt: "You are helpful",
  max_iterations: 10
)
```

### Serialization and Persistence

`Agent.Context` can be serialized to a JSON-encodable map for storage and later resumption. Functions, PIDs, and modules are excluded automatically:

```elixir
# Serialize to a map (store in database, file, etc.)
data = Nous.Agent.Context.serialize(ctx)

# data.version == 1
# data.messages, data.deps, data.usage, etc. are all plain maps

# Later: restore the context
{:ok, restored_ctx} = Nous.Agent.Context.deserialize(data)
```

Note that runtime-only fields are not serialized: `callbacks`, `notify_pid`, `cancellation_check`, `approval_handler`, `pubsub`, `hook_registry`, and `active_skills`. Re-attach these after deserialization if needed.

### Patching dangling tool calls

When a session is interrupted mid-tool-execution, the conversation history will contain assistant messages with `tool_calls` that have no corresponding tool result. This causes API errors on resumption.

`patch_dangling_tool_calls/1` scans messages and injects synthetic tool results for any unmatched calls:

```elixir
# After deserializing a saved context
{:ok, ctx} = Nous.Agent.Context.deserialize(saved_data)

# Patch any tool calls that were interrupted
ctx = Nous.Agent.Context.patch_dangling_tool_calls(ctx)

# Now safe to resume the agent loop
{:ok, result} = Nous.run(agent, "Continue where we left off",
  deps: ctx.deps,
  messages: ctx.messages
)
```

The synthetic results contain the text: `"Tool call was interrupted and not executed. Please retry if needed."`

## Multi-User Context

Use `deps` to scope agent state per user or session.

### Scoping with session and user IDs

```elixir
deps = %{
  user_id: current_user.id,
  session_id: "sess_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}",
  user_name: current_user.name,
  preferences: current_user.settings
}

{:ok, result} = Nous.run(agent, user_message, deps: deps)
```

### Tools that respect user scope

```elixir
def search_documents(ctx, %{"query" => query}) do
  # Automatically scoped to the current user
  user_id = ctx.deps.user_id

  Document
  |> where(user_id: ^user_id)
  |> where([d], ilike(d.content, ^"%#{query}%"))
  |> Repo.all()
  |> format_results()
end
```

### Per-session state with ContextUpdate

```elixir
def record_action(ctx, %{"action" => action}) do
  session_id = ctx.deps.session_id

  {:ok, %{recorded: action},
   ContextUpdate.new()
   |> ContextUpdate.append(:audit_log, %{
     action: action,
     session_id: session_id,
     user_id: ctx.deps.user_id,
     timestamp: DateTime.utc_now()
   })}
end
```

## Related Resources

- [Tool Development Guide](tool_development.md) -- creating tools that use context
- [Skills Guide](skills.md) -- reusable instruction packages
- [Hooks Guide](hooks.md) -- lifecycle interceptors
