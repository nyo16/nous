# Yggdrasil AI - Telemetry Instrumentation Plan

## Overview

This document outlines where and how to add Telemetry events to Yggdrasil AI for monitoring, metrics, and observability.

## Event Naming Convention

Following Telemetry best practices:
```
[:yggdrasil, :agent, :run, :start]
[:yggdrasil, :agent, :run, :stop]
[:yggdrasil, :agent, :run, :exception]
```

Format: `[:app_name, :component, :action, :event_type]`

---

## 🎯 Recommended Telemetry Events

### 1. Agent Execution Events

**Location:** `lib/exadantic/agent_runner.ex`

#### Event: Agent Run Start
```elixir
# In: Yggdrasil.AgentRunner.run/3 (at the beginning)

:telemetry.execute(
  [:yggdrasil, :agent, :run, :start],
  %{system_time: System.system_time()},
  %{
    agent_name: agent.name,
    model_provider: agent.model.provider,
    model_name: agent.model.model,
    has_tools: length(agent.tools) > 0,
    tool_count: length(agent.tools)
  }
)
```

#### Event: Agent Run Stop (Success)
```elixir
# In: Yggdrasil.AgentRunner.execute_loop/2 (when returning {:ok, result})

:telemetry.execute(
  [:yggdrasil, :agent, :run, :stop],
  %{
    duration: duration_ms,
    total_tokens: result.usage.total_tokens,
    input_tokens: result.usage.input_tokens,
    output_tokens: result.usage.output_tokens,
    requests: result.usage.requests,
    tool_calls: result.usage.tool_calls,
    iterations: state.iteration
  },
  %{
    agent_name: state.agent.name,
    model_provider: state.agent.model.provider,
    model_name: state.agent.model.model
  }
)
```

#### Event: Agent Run Exception
```elixir
# In: Yggdrasil.AgentRunner.execute_loop/2 (on error)

:telemetry.execute(
  [:yggdrasil, :agent, :run, :exception],
  %{duration: duration_ms},
  %{
    agent_name: state.agent.name,
    error_type: error.__struct__,
    reason: inspect(error)
  }
)
```

---

### 2. Model Request Events

**Location:** `lib/exadantic/models/openai_compatible.ex`, `anthropic.ex`, `gemini.ex`

#### Event: Model Request Start
```elixir
# In: Models.*.request/3 (at the beginning)

:telemetry.execute(
  [:yggdrasil, :model, :request, :start],
  %{system_time: System.system_time()},
  %{
    provider: model.provider,
    model_name: model.model,
    message_count: length(messages)
  }
)
```

#### Event: Model Request Stop
```elixir
# In: Models.*.request/3 (on success)

:telemetry.execute(
  [:yggdrasil, :model, :request, :stop],
  %{
    duration: duration_ms,
    input_tokens: response.usage.input_tokens,
    output_tokens: response.usage.output_tokens,
    total_tokens: response.usage.total_tokens
  },
  %{
    provider: model.provider,
    model_name: model.model,
    has_tool_calls: has_tool_calls?(response)
  }
)
```

#### Event: Model Request Exception
```elixir
# In: Models.*.request/3 (on error)

:telemetry.execute(
  [:yggdrasil, :model, :request, :exception],
  %{duration: duration_ms},
  %{
    provider: model.provider,
    model_name: model.model,
    error_type: inspect(error)
  }
)
```

---

### 3. Tool Execution Events

**Location:** `lib/exadantic/tool_executor.ex`

#### Event: Tool Execution Start
```elixir
# In: ToolExecutor.execute/3

:telemetry.execute(
  [:yggdrasil, :tool, :execute, :start],
  %{system_time: System.system_time()},
  %{
    tool_name: tool.name,
    attempt: attempt + 1,
    max_retries: tool.retries
  }
)
```

#### Event: Tool Execution Stop
```elixir
# In: ToolExecutor.do_execute/4 (on success)

:telemetry.execute(
  [:yggdrasil, :tool, :execute, :stop],
  %{
    duration: duration_ms,
    success: true
  },
  %{
    tool_name: tool.name,
    attempt: attempt + 1
  }
)
```

#### Event: Tool Execution Exception
```elixir
# In: ToolExecutor.do_execute/4 (on retry/failure)

:telemetry.execute(
  [:yggdrasil, :tool, :execute, :exception],
  %{duration: duration_ms},
  %{
    tool_name: tool.name,
    attempt: attempt + 1,
    will_retry: attempt < tool.retries,
    error_type: error.__struct__
  }
)
```

---

### 4. Streaming Events (Optional)

**Location:** `lib/exadantic/agent_runner.ex` (run_stream)

#### Event: Stream Start
```elixir
:telemetry.execute(
  [:yggdrasil, :agent, :stream, :start],
  %{system_time: System.system_time()},
  %{agent_name: agent.name, model: agent.model.model}
)
```

#### Event: Stream Chunk
```elixir
:telemetry.execute(
  [:yggdrasil, :agent, :stream, :chunk],
  %{chunk_size: byte_size(text)},
  %{agent_name: agent.name}
)
```

---

## 📋 Implementation Priority

### Phase 1: Essential Events (Start Here)
1. ✅ **Agent run start/stop/exception** - Most important for monitoring
2. ✅ **Model request start/stop/exception** - Track API calls and costs

### Phase 2: Tool Monitoring
3. ✅ **Tool execution events** - Debug tool failures

### Phase 3: Advanced (Optional)
4. ⭐ **Streaming events** - Monitor real-time performance
5. ⭐ **Message bus events** (for multi-agent systems)

---

## 🔧 Implementation Example

### Step 1: Update AgentRunner

```elixir
# lib/exadantic/agent_runner.ex

defmodule Yggdrasil.AgentRunner do
  # ... existing code ...

  def run(%Agent{} = agent, prompt, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    # Emit start event
    :telemetry.execute(
      [:yggdrasil, :agent, :run, :start],
      %{system_time: System.system_time()},
      %{
        agent_name: agent.name,
        model_provider: agent.model.provider,
        model_name: agent.model.model,
        tool_count: length(agent.tools)
      }
    )

    # Execute
    result = case execute_loop(state, messages) do
      {:ok, result} ->
        duration = System.monotonic_time(:millisecond) - start_time

        # Emit success event
        :telemetry.execute(
          [:yggdrasil, :agent, :run, :stop],
          %{
            duration: duration,
            total_tokens: result.usage.total_tokens,
            input_tokens: result.usage.input_tokens,
            output_tokens: result.usage.output_tokens,
            tool_calls: result.usage.tool_calls,
            requests: result.usage.requests
          },
          %{
            agent_name: agent.name,
            model_provider: agent.model.provider
          }
        )

        {:ok, result}

      {:error, error} ->
        duration = System.monotonic_time(:millisecond) - start_time

        # Emit exception event
        :telemetry.execute(
          [:yggdrasil, :agent, :run, :exception],
          %{duration: duration},
          %{
            agent_name: agent.name,
            error_type: error.__struct__
          }
        )

        {:error, error}
    end

    result
  end
end
```

### Step 2: Update ToolExecutor

```elixir
# lib/exadantic/tool_executor.ex

defp do_execute(tool, arguments, ctx, attempt) do
  start_time = System.monotonic_time(:millisecond)

  :telemetry.execute(
    [:yggdrasil, :tool, :execute, :start],
    %{system_time: System.system_time()},
    %{tool_name: tool.name, attempt: attempt + 1}
  )

  try do
    result = apply_tool_function(tool, arguments, ctx)
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:yggdrasil, :tool, :execute, :stop],
      %{duration: duration},
      %{tool_name: tool.name, attempt: attempt + 1, success: true}
    )

    {:ok, result}
  rescue
    error ->
      duration = System.monotonic_time(:millisecond) - start_time

      :telemetry.execute(
        [:yggdrasil, :tool, :execute, :exception],
        %{duration: duration},
        %{
          tool_name: tool.name,
          attempt: attempt + 1,
          will_retry: attempt < tool.retries
        }
      )

      # ... retry logic
  end
end
```

---

## 📊 Example: Attaching Handlers

```elixir
# In your application or config

# Attach handler for agent runs
:telemetry.attach(
  "exadantic-agent-runs",
  [:yggdrasil, :agent, :run, :stop],
  fn event_name, measurements, metadata, _config ->
    IO.puts """
    Agent completed: #{metadata.agent_name}
    Duration: #{measurements.duration}ms
    Tokens: #{measurements.total_tokens}
    Tool calls: #{measurements.tool_calls}
    """
  end,
  nil
)

# Attach handler for tool execution
:telemetry.attach(
  "exadantic-tool-execution",
  [:yggdrasil, :tool, :execute, :stop],
  fn _event, measurements, metadata, _config ->
    Logger.info("[Tool] #{metadata.tool_name} completed in #{measurements.duration}ms")
  end,
  nil
)

# Send metrics to external system (e.g., StatsD, Prometheus)
:telemetry.attach(
  "exadantic-metrics",
  [:yggdrasil, :agent, :run, :stop],
  fn _event, measurements, metadata, _config ->
    MyApp.Metrics.increment("exadantic.agent.runs")
    MyApp.Metrics.timing("exadantic.agent.duration", measurements.duration)
    MyApp.Metrics.gauge("exadantic.agent.tokens", measurements.total_tokens)
  end,
  nil
)
```

---

## 🎯 Summary: Where to Add Events

| Location | Events | Priority |
|----------|--------|----------|
| `agent_runner.ex` | Agent run lifecycle | 🔥 HIGH |
| `models/*.ex` | Model API calls | 🔥 HIGH |
| `tool_executor.ex` | Tool execution | ⭐ MEDIUM |
| `agent_runner.ex` (streaming) | Streaming chunks | ⭐ MEDIUM |

---

## 💡 Benefits

Once instrumented, you can:
- **Monitor**: Track agent performance in production
- **Debug**: See which tools are slow or failing
- **Optimize**: Identify token usage patterns
- **Alert**: Get notified of errors
- **Metrics**: Export to Prometheus, StatsD, etc.

---

**Want me to implement this?** I can add all the telemetry events to the codebase! 🚀