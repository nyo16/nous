# Getting Started with Nous

This guide picks up where the [README Quick Start](../README.md#quick-start)
leaves off. It assumes you already have Nous installed (`{:nous, "~> 0.16.1"}`)
and a provider configured (API key set, or a local LM Studio / Ollama / vLLM
server running).

It covers four real-world building blocks:

1. [Building your first multi-tool agent](#building-your-first-multi-tool-agent)
2. [Handling errors in production](#handling-errors-in-production)
3. [Persisting agent state](#persisting-agent-state)
4. [Wiring up callbacks for observability](#wiring-up-callbacks-for-observability)

Plus two reference patterns at the end:

- [Error handling](#error-handling)
- [Conversation state as a GenServer](#conversation-state-as-a-genserver)

## Building your first multi-tool agent

Most useful agents call more than one tool. The pattern: define each tool
as a plain function (or a module implementing `Nous.Tool.Behaviour`), then
pass them into `Nous.new/2`. The LLM picks which to call.

```elixir
defmodule MyTools do
  def get_weather(_ctx, %{"city" => city}) do
    %{city: city, temperature: 72, conditions: "sunny"}
  end

  def get_forecast(_ctx, %{"city" => city, "days" => days}) do
    %{city: city, days: days, summary: "mild and dry"}
  end

  def list_cities(_ctx, _args) do
    ["Tokyo", "Lisbon", "Berlin", "Buenos Aires"]
  end
end

agent =
  Nous.new("openai:gpt-4o",
    instructions: """
    You are a travel assistant. Use the available tools to answer
    questions about cities. Always cite which tool you used.
    """,
    tools: [
      &MyTools.get_weather/2,
      &MyTools.get_forecast/2,
      &MyTools.list_cities/2
    ]
  )

{:ok, result} = Nous.run(agent, "What's the weather in Tokyo, and what's the 3-day forecast?")
IO.puts(result.output)
```

The agent loop will:

1. Receive your prompt
2. Decide which tool(s) to call (it can chain multiple in one turn)
3. Execute them concurrently where safe
4. Feed the results back to the model
5. Generate the final answer

For a working version of this pattern see
[`examples/02_with_tools.exs`](../examples/02_with_tools.exs) and
[`examples/07_module_tools.exs`](../examples/07_module_tools.exs).

## Handling errors in production

`Nous.run/3` returns `{:ok, result}` or `{:error, reason}`. In production you
typically want three things on top of that: retries on transient errors,
provider fallback, and structured logging.

### Provider fallback

```elixir
agent =
  Nous.new("openai:gpt-4o",
    fallback: ["anthropic:claude-sonnet-4-5-20250929", "groq:llama-3.1-70b-versatile"]
  )

{:ok, result} = Nous.run(agent, "Hello")
```

Fallback triggers on `Nous.Errors.ProviderError` and `Nous.Errors.ModelError`
only — application errors (validation, max iterations, tool errors) return
immediately because a different model wouldn't help.

### Retries on transient errors

```elixir
defmodule Retry do
  def with_backoff(fun, attempts \\ 3, base \\ 200)
  def with_backoff(_fun, 0, _base), do: {:error, :exhausted}

  def with_backoff(fun, attempts, base) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, %Nous.Errors.ProviderError{}} ->
        Process.sleep(base)
        with_backoff(fun, attempts - 1, base * 2)
      {:error, _} = err -> err
    end
  end
end

Retry.with_backoff(fn -> Nous.run(agent, "Hello") end)
```

Working version: [`examples/advanced/error_handling.exs`](../examples/advanced/error_handling.exs).

## Persisting agent state

For agents that live longer than a single request — chatbots, long-running
research jobs, anything user-facing — wire them through
`Nous.AgentDynamicSupervisor` with a persistence backend.

```elixir
# start_agent/3 takes the session_id, an agent_config MAP, then options. The
# supervisor registers the via-tuple for you (no :name option needed).
{:ok, _pid} =
  Nous.AgentDynamicSupervisor.start_agent(
    "user-123",
    %{model: "openai:gpt-4o", instructions: "Be helpful"},
    persistence: Nous.Persistence.ETS
  )

# Context auto-saves as a serialized map; deserialize it to restore on a later run:
{:ok, data} = Nous.Persistence.ETS.load("user-123")
{:ok, context} = Nous.Agent.Context.deserialize(data)
{:ok, result} = Nous.run(agent, "Continue our conversation", context: context)
```

ETS is built in. For SQLite/DuckDB persistence and crash recovery patterns,
see [`examples/09_agent_server.exs`](../examples/09_agent_server.exs) and the
[best practices guide](guides/best_practices.md).

## Wiring up callbacks for observability

Callbacks fire at well-known points in the agent loop. Use them for token
streaming to a UI, structured logging, metrics, or to bridge into PubSub.

```elixir
{:ok, result} =
  Nous.run(agent, "Summarize the latest news on Elixir.",
    callbacks: %{
      on_llm_new_delta:        fn _event, delta -> IO.write(delta) end,
      on_llm_new_thinking_delta: fn _event, t -> IO.write(["[think] ", t]) end,
      on_tool_call:            fn _event, call -> Logger.info("tool: #{call.name}") end,
      on_tool_response:        fn _event, resp -> Logger.info("result: #{inspect(resp)}") end
    }
  )
```

For LiveView you typically prefer `notify_pid:` over inline callbacks — the
agent runs in a Task and sends `{:agent_delta, _}` / `{:agent_complete, _}`
messages to your view process. See
[`examples/05_callbacks.exs`](../examples/05_callbacks.exs) and
[`examples/advanced/liveview_integration.exs`](../examples/advanced/liveview_integration.exs).

For metrics, attach to the built-in telemetry events:

```elixir
Nous.Telemetry.attach_default_handler()
```

See [`examples/advanced/telemetry.exs`](../examples/advanced/telemetry.exs).

## Common Patterns

### Error Handling

```elixir
case Nous.run(agent, prompt) do
  {:ok, result} ->
    IO.puts("Success: #{result.output}")
  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
```

### Conversation State as a GenServer

When you want a process-local chat session with full conversation history:

```elixir
defmodule ChatBot do
  use GenServer

  def start_link(model) do
    GenServer.start_link(__MODULE__, model)
  end

  def ask(pid, question) do
    GenServer.call(pid, {:ask, question})
  end

  def init(model) do
    agent = Nous.new(model)
    {:ok, %{agent: agent, messages: []}}
  end

  def handle_call({:ask, question}, _from, state) do
    # History is a list of %Nous.Message{} structs (not bare maps).
    messages = state.messages ++ [Nous.Message.user(question)]

    # Pass the history under the :messages key — a bare list is not valid input.
    {:ok, result} = Nous.run(state.agent, messages: messages)

    # Update conversation history
    new_messages = messages ++ [Nous.Message.assistant(result.output)]

    {:reply, result.output, %{state | messages: new_messages}}
  end
end
```

For supervised, crash-recoverable versions of this pattern, see
[`examples/09_agent_server.exs`](../examples/09_agent_server.exs).

## What's Next?

- **More examples** → [`examples/`](../examples/README.md) (numbered 01–19, plus
  `providers/`, `memory/`, `advanced/`, `workflow/`, `eval/`)
- **Specific features** → [the guides index](guides/README.md) — tool development,
  structured output, hooks, skills, memory, workflows, knowledge base,
  LiveView integration, evaluation
- **Production deployment** → [Best Practices](guides/best_practices.md)
- **Troubleshooting** → [Troubleshooting Guide](guides/troubleshooting.md)
