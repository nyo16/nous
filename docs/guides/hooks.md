# 🪝 Hooks Guide

Hooks are lifecycle interceptors that let you block, modify, or audit agent actions at specific events.

## Quick Start

```elixir
agent = Nous.new("openai:gpt-4",
  tools: [&MyTools.delete_file/2, &MyTools.read_file/2],
  hooks: [
    %Nous.Hook{
      event: :pre_tool_use,
      matcher: "delete_file",
      type: :function,
      handler: fn _event, %{arguments: %{"path" => path}} ->
        if String.starts_with?(path, "/etc"), do: :deny, else: :allow
      end
    }
  ]
)
```

## Hook Events

| Event | When Fired | Can Block? | Payload |
|-------|-----------|-----------|---------|
| `:session_start` | Agent run begins | No | `%{agent_name}` |
| `:pre_request` | Before LLM API call | Yes | `%{agent_name, tool_count, iteration}` |
| `:post_response` | After LLM response | No | `%{agent_name, iteration}` |
| `:pre_tool_use` | Before each tool call | Yes | `%{tool_name, tool_id, arguments}` |
| `:post_tool_use` | After each tool call | No (modify) | `%{tool_name, tool_id, arguments, result}` |
| `:session_end` | After run completes | No | `%{agent_name, output}` |

## Handler Types

### Function Hooks

Inline functions — simplest for quick logic:

```elixir
%Nous.Hook{
  event: :pre_tool_use,
  type: :function,
  handler: fn _event, %{tool_name: name, arguments: args} ->
    # Return :allow, :deny, {:deny, reason}, or {:modify, changes}
    :allow
  end
}
```

### Module Hooks

Implement the `Nous.Hook` behaviour for reusable, testable hooks:

```elixir
defmodule MyApp.Hooks.RateLimit do
  @behaviour Nous.Hook

  @impl true
  def handle(:pre_tool_use, %{tool_name: name}) do
    if rate_limited?(name), do: {:deny, "Rate limited"}, else: :allow
  end

  def handle(_event, _payload), do: :allow
end

# Usage
%Nous.Hook{
  event: :pre_tool_use,
  type: :module,
  handler: MyApp.Hooks.RateLimit
}
```

### Command Hooks

Execute external shell commands via NetRunner (zero-zombie-process guarantee):

```elixir
%Nous.Hook{
  event: :pre_tool_use,
  matcher: ~r/^(write|delete)/,
  type: :command,
  handler: "python3 scripts/policy_check.py",
  timeout: 5_000
}
```

Command hooks receive JSON on stdin and use exit codes:
- **Exit 0**: Allow (stdout parsed as JSON for `{:modify, ...}`)
- **Exit 2**: Deny
- **Other**: Allow with warning (fail-open)

JSON stdout format:
```json
{"result": "allow"}
{"result": "deny", "reason": "Not permitted"}
{"result": "modify", "changes": {"arguments": {"path": "/safe/path"}}}
```

## Matchers

Filter hooks to specific tools (for `pre_tool_use` / `post_tool_use`):

```elixir
# Match all tools (default)
matcher: nil

# Exact tool name
matcher: "delete_file"

# Regex pattern
matcher: ~r/^(write|delete|execute)/

# Custom predicate
matcher: fn %{tool_name: name} -> String.starts_with?(name, "dangerous_") end
```

## Hook Results

| Result | Effect |
|--------|--------|
| `:allow` | Proceed normally |
| `:deny` | Block the action (blocking events only) |
| `{:deny, reason}` | Block with reason message |
| `{:modify, changes}` | Modify payload and continue |
| `{:error, reason}` | Log warning, fail-open (proceed) |

### Modifying Tool Arguments (pre_tool_use)

```elixir
%Nous.Hook{
  event: :pre_tool_use,
  type: :function,
  handler: fn _event, %{arguments: args} ->
    # Sanitize file path
    {:modify, %{arguments: Map.put(args, "path", sanitize(args["path"]))}}
  end
}
```

### Modifying Tool Results (post_tool_use)

```elixir
%Nous.Hook{
  event: :post_tool_use,
  type: :function,
  handler: fn _event, %{result: result} ->
    # Redact sensitive data from tool output
    {:modify, %{result: redact_pii(result)}}
  end
}
```

## Priority

Hooks execute in priority order (lower number = earlier):

```elixir
hooks: [
  %Nous.Hook{event: :pre_tool_use, priority: 10, ...},   # Runs first
  %Nous.Hook{event: :pre_tool_use, priority: 100, ...},  # Runs second
  %Nous.Hook{event: :pre_tool_use, priority: 200, ...}   # Runs third
]
```

For blocking events, execution short-circuits on the first `:deny`.

## Execution Order

Hooks integrate with the existing plugin system:

```
Plugin.before_request → Hook(:pre_request) → LLM call → Hook(:post_response) → Plugin.after_response
                                                           ↓
                                             For each tool call:
                                               Hook(:pre_tool_use) → approval check → ToolExecutor → Hook(:post_tool_use)
```

## Telemetry

Hook execution emits telemetry events:

```elixir
# Attach to hook events
:telemetry.attach("hook-monitor", [:nous, :hook, :execute, :stop], fn _name, measurements, metadata, _config ->
  Logger.info("Hook #{metadata.hook_name} (#{metadata.hook_type}) took #{measurements.duration}ns")
end, nil)

:telemetry.attach("hook-denials", [:nous, :hook, :denied], fn _name, _measurements, metadata, _config ->
  Logger.warning("Hook denied #{metadata.event}: #{metadata.hook_name}")
end, nil)
```

## Common Patterns

### Audit Logging

```elixir
%Nous.Hook{
  event: :post_tool_use,
  type: :function,
  name: "audit_log",
  handler: fn _event, %{tool_name: name, arguments: args, result: result} ->
    Logger.info("Tool #{name} called", args: args, result_size: byte_size(to_string(result)))
    :allow
  end
}
```

### Policy Enforcement

```elixir
%Nous.Hook{
  event: :pre_tool_use,
  matcher: ~r/^(write|delete|execute)/,
  type: :function,
  name: "write_protection",
  handler: fn _event, %{tool_name: _name} ->
    if Application.get_env(:my_app, :read_only_mode), do: :deny, else: :allow
  end
}
```

## Related Resources

- [Examples: 16_hooks.exs](../../examples/16_hooks.exs)
- [Skills Guide](skills.md) — reusable instruction packages
- [Tool Development Guide](tool_development.md) — creating tools
