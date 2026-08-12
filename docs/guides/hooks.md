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
| `:pre_node` | Before each workflow node | Yes | `%{node_id, node_type, state}` |
| `:post_node` | After each workflow node succeeds | No (modify) | `%{node_id, result, state}` |
| `:session_end` | After run completes | No | `%{agent_name, output}` |

`:pre_node` and `:post_node` are dispatched by `Nous.Workflow.Engine` for graphs run with
`hooks: [...]`, not by the agent loop. The engine calls the hook's `handler` function
directly, so only `:function` hooks fire there: `matcher`, `timeout` and `fail_closed` are
ignored, and a raised exception is logged and treated as `:allow`.

`:pre_node` runs before the node executes and understands three non-`:allow` verdicts:
`{:pause, reason}` suspends the workflow with a resumable checkpoint, `:deny` aborts the run
with `{:error, {:hook_denied, hook_name, node_id}}`, and `{:modify, new_state}` replaces the
state handed to the node. `:post_node` runs only after the node completes successfully and
can return `{:modify, new_state}` to rewrite the workflow state before the next node.

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
  handler: ["python3", "scripts/policy_check.py"],
  timeout: 5_000
}
```

The handler must be an argv list — `["python3", "scripts/policy_check.py"]`, not a shell
string. Command hooks never go through a shell, so nothing in the handler is expanded; a raw
string handler is rejected with `{:error, :invalid_command_handler}`.

Command hooks receive JSON on stdin and use exit codes:
- **Exit 0**: Allow (stdout parsed as JSON for `{:modify, ...}`)
- **Exit 2**: Deny
- **Other exit codes**: Allow with a logged warning (fail-open), unless the hook sets
  [`fail_closed: true`](#fail-closed-hooks)
- **Timeout** (the `:timeout` field, default `10_000` ms): treated as a hook error — same
  fail-open default, same `fail_closed` override

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
| `{:error, reason}` | Log warning; fail-open by default, deny when the hook sets `fail_closed: true` (see [Fail-Closed Hooks](#fail-closed-hooks)) |

### Fail-Closed Hooks

`%Nous.Hook{}` carries a `fail_closed` field that defaults to `false`. It does not change what
a hook *decides* — it changes what happens when a hook *fails*: raises, returns
`{:error, reason}`, or (for command hooks) times out or exits with a code other than 0 or 2.

| `fail_closed` | A hook error on a blocking event means |
|---------------|----------------------------------------|
| `false` (default) | Warning logged, error ignored, remaining hooks run — a broken hook **allows** the action |
| `true` | Error becomes `{:deny, "hook errored (fail_closed): ..."}` — a broken hook **blocks** the action |

The field only has an effect on the blocking events (`:pre_tool_use`, `:pre_request`). On
non-blocking events a hook error is always logged and skipped, because there is nothing left
to block.

Set it on any hook that gates a security-sensitive operation. Without it, crashing the policy
hook is enough to bypass the policy:

```elixir
%Nous.Hook{
  event: :pre_tool_use,
  matcher: ~r/^(write|delete|execute)/,
  type: :function,
  name: "filesystem_policy",
  fail_closed: true,
  handler: fn _event, %{tool_name: tool, arguments: args} ->
    # Raises if the policy service is unreachable — fail_closed turns that into a deny
    # instead of an unchecked write.
    if MyApp.Policy.allow?(tool, args), do: :allow, else: {:deny, "blocked by policy"}
  end
}
```

The tradeoff is availability. With `fail_closed: true`, a bug in the hook — or an unreachable
service behind it — blocks tool execution rather than silently permitting it. That is the
correct posture for security gates and the wrong one for audit, metrics or notification hooks;
leave those at `fail_closed: false` so a logging failure never stalls the agent.

A denial produced this way still emits `[:nous, :hook, :denied]`, with
`reason: {:fail_closed, reason}` in the metadata, so it is distinguishable from a deliberate
`:deny`.

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
hooks = [
  # Runs first
  %Nous.Hook{event: :pre_tool_use, type: :function, priority: 10, handler: &MyApp.Hooks.rate_limit/2},
  # Runs second
  %Nous.Hook{event: :pre_tool_use, type: :function, priority: 100, handler: &MyApp.Hooks.policy/2},
  # Runs third
  %Nous.Hook{event: :pre_tool_use, type: :function, priority: 200, handler: &MyApp.Hooks.audit/2}
]

agent = Nous.new("openai:gpt-4", tools: [&MyTools.write_file/2], hooks: hooks)
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
