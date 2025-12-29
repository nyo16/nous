# Patterns & Architecture Examples

Advanced reasoning patterns and production architecture examples.

## Learning Path
New to advanced patterns? Follow this progression:
1. **[ReAct Agent](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/04-react-agent.exs)** - Reasoning and acting
2. **[GenServer Integration](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/01-genserver.ex)** - Elixir processes
3. **[Complete Projects](https://github.com/nyo16/nous/tree/master/examples/tutorials/04-projects)** - Production systems

## Reasoning Patterns

### ReAct (Reasoning + Acting)
- **[04-react-agent.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/04-react-agent.exs)** - Basic ReAct pattern
- **[05-react-enhanced.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/05-react-enhanced.exs)** - Enhanced ReAct agent
- **[react_agent_demo.exs](https://github.com/nyo16/nous/blob/master/examples/react_agent_demo.exs)** - Complete ReAct example

ReAct agents think through problems step-by-step:
```elixir
agent = Nous.new("anthropic:claude-3-5-sonnet",
  instructions: """
  You are a ReAct agent. For each user request:
  1. Think: Analyze what needs to be done
  2. Act: Use tools to gather information
  3. Think: Reflect on the results
  4. Act: Take next actions based on analysis
  Continue until you have a complete answer.
  """
)
```

### Conversation Management
- **[02-conversation.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/02-conversation.exs)** - Multi-turn conversations
- **[conversation_history_example.exs](https://github.com/nyo16/nous/blob/master/examples/conversation_history_example.exs)** - State management

### Error Handling
- **[03-error-handling.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/03-error-handling.exs)** - Graceful failures
- **[error_handling_example.exs](https://github.com/nyo16/nous/blob/master/examples/error_handling_example.exs)** - Robust error patterns

## Elixir Integration Patterns

### GenServer Agents
- **[01-genserver.ex](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/01-genserver.ex)** - Agent as GenServer
- **[genserver_agent_example.ex](https://github.com/nyo16/nous/blob/master/examples/genserver_agent_example.ex)** - Production GenServer

```elixir
defmodule MyAgent do
  use GenServer

  def start_link(model) do
    GenServer.start_link(__MODULE__, model, name: __MODULE__)
  end

  def ask(question) do
    GenServer.call(__MODULE__, {:ask, question})
  end

  def init(model) do
    agent = Nous.new(model)
    {:ok, %{agent: agent, history: []}}
  end

  def handle_call({:ask, question}, _from, state) do
    {:ok, result} = Nous.run(state.agent, question)
    new_history = state.history ++ [%{question: question, answer: result.output}]
    {:reply, result.output, %{state | history: new_history}}
  end
end
```

### LiveView Integration
- **[03-liveview.ex](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/03-liveview.ex)** - Phoenix LiveView
- **[02-liveview-streaming.ex](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/02-liveview-streaming.ex)** - Real-time UI
- **[liveview_chat_example.ex](https://github.com/nyo16/nous/blob/master/examples/liveview_chat_example.ex)** - Complete chat app

### Distributed Agents
- **[04-distributed.ex](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/04-distributed.ex)** - Multi-node agents
- **[distributed_agent_example.ex](https://github.com/nyo16/nous/blob/master/examples/distributed_agent_example.ex)** - Registry patterns

## Production Architecture

### Supervision Trees
```elixir
defmodule MyApp.AgentSupervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    children = [
      {MyApp.Agent, "anthropic:claude-3-5-sonnet"},
      {MyApp.AgentPool, pool_size: 5}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### Monitoring & Telemetry
- **[05-telemetry.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/05-telemetry.exs)** - Agent monitoring
- **[telemetry_demo.exs](https://github.com/nyo16/nous/blob/master/examples/telemetry_demo.exs)** - Telemetry events

### Agent Cancellation
- **[cancellation_demo.exs](https://github.com/nyo16/nous/blob/master/examples/cancellation_demo.exs)** - Cancelling long operations
- Useful for user-initiated stops and timeouts

## Multi-Agent Systems

### Agent Council
- **[Council](https://github.com/nyo16/nous/tree/master/examples/tutorials/04-projects/council)** - Multi-LLM deliberation
- Multiple AI models vote on best responses
- 3-stage voting system for consensus

### Trading Desk
- **[Trading Desk](https://github.com/nyo16/nous/tree/master/examples/tutorials/04-projects/trading_desk)** - Enterprise coordination
- 4 specialized agents: Market, Risk, Trading, Research
- Supervisor coordination with 18 tools

### AI Code Editor
- **[Coderex](https://github.com/nyo16/nous/tree/master/examples/tutorials/04-projects/coderex)** - Code generation system
- Complete code editing agent
- SEARCH/REPLACE format with file operations

## Architecture Patterns

### Agent Factory Pattern
```elixir
defmodule AgentFactory do
  def create(:chat_agent), do: Nous.new("anthropic:claude-3-5-sonnet",
    instructions: "You are a helpful chat assistant"
  )

  def create(:code_agent), do: Nous.new("anthropic:claude-3-5-sonnet",
    instructions: "You are a code generation assistant",
    tools: [&CodeTools.read_file/2, &CodeTools.write_file/2]
  )

  def create(:research_agent), do: Nous.new("gemini:gemini-1.5-pro",
    instructions: "You are a research assistant",
    tools: [&SearchTools.web_search/2, &SearchTools.summarize/2]
  )
end
```

### Agent Pool Pattern
```elixir
defmodule AgentPool do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_agent() do
    GenServer.call(__MODULE__, :get_agent)
  end

  def return_agent(agent) do
    GenServer.cast(__MODULE__, {:return_agent, agent})
  end

  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, 3)
    agents = Enum.map(1..pool_size, fn _ ->
      Nous.new("anthropic:claude-3-5-sonnet")
    end)

    {:ok, %{available: agents, in_use: []}}
  end
end
```

### Chain of Responsibility
```elixir
defmodule AgentChain do
  def process(request) do
    request
    |> maybe_handle_with(:research_agent)
    |> maybe_handle_with(:analysis_agent)
    |> maybe_handle_with(:summary_agent)
  end

  defp maybe_handle_with({:handled, result}, _agent), do: {:handled, result}
  defp maybe_handle_with({:continue, request}, agent) do
    case apply_agent(agent, request) do
      {:ok, result} -> {:handled, result}
      {:continue, updated_request} -> {:continue, updated_request}
    end
  end
end
```

## Performance Patterns

### Caching Strategies
```elixir
defmodule CachedAgent do
  use GenServer

  def ask(question) do
    case :ets.lookup(:agent_cache, question) do
      [{^question, cached_answer}] -> cached_answer
      [] ->
        answer = GenServer.call(__MODULE__, {:ask, question})
        :ets.insert(:agent_cache, {question, answer})
        answer
    end
  end
end
```

### Batch Processing
```elixir
defmodule BatchAgent do
  def process_batch(questions) do
    questions
    |> Enum.chunk_every(5)  # Process 5 at a time
    |> Task.async_stream(&process_chunk/1, max_concurrency: 3)
    |> Enum.flat_map(fn {:ok, results} -> results end)
  end

  defp process_chunk(chunk) do
    agent = Nous.new("anthropic:claude-3-5-sonnet")
    Enum.map(chunk, &Nous.run(agent, &1))
  end
end
```

## Error Recovery Patterns

### Circuit Breaker
```elixir
defmodule AgentCircuitBreaker do
  use GenServer

  def ask(question) do
    GenServer.call(__MODULE__, {:ask, question})
  end

  def handle_call({:ask, question}, _from, %{state: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call({:ask, question}, _from, state) do
    case Nous.run(state.agent, question) do
      {:ok, result} ->
        {:reply, {:ok, result}, reset_failures(state)}
      {:error, error} ->
        new_state = increment_failures(state)
        {:reply, {:error, error}, maybe_open_circuit(new_state)}
    end
  end
end
```

### Retry with Backoff
```elixir
defmodule RetryAgent do
  def ask_with_retry(agent, question, max_retries \\ 3) do
    ask_with_retry(agent, question, 0, max_retries, 1000)
  end

  defp ask_with_retry(agent, question, attempt, max_retries, delay) do
    case Nous.run(agent, question) do
      {:ok, result} -> {:ok, result}
      {:error, _} when attempt >= max_retries -> {:error, :max_retries}
      {:error, _} ->
        :timer.sleep(delay)
        ask_with_retry(agent, question, attempt + 1, max_retries, delay * 2)
    end
  end
end
```

## Testing Patterns

### Mock Agents
```elixir
defmodule MockAgent do
  def new(responses) when is_list(responses) do
    Agent.start_link(fn -> responses end)
  end

  def run(mock_agent, _prompt) do
    Agent.get_and_update(mock_agent, fn
      [response | rest] -> {{:ok, response}, rest}
      [] -> {{:error, :no_more_responses}, []}
    end)
  end
end

# In tests
{:ok, mock} = MockAgent.new([
  %{output: "First response"},
  %{output: "Second response"}
])
```

---

**Next Steps:**
- Start with [04-react-agent.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/04-react-agent.exs)
- Try [GenServer integration](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/01-genserver.ex) for stateful agents
- Explore complete [project examples](https://github.com/nyo16/nous/tree/master/examples/tutorials/04-projects) for production patterns
