# Nous AI Framework

Elixir AI agent framework with multi-provider LLM support.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Nous.Agent                              │
│  (Configuration: instructions, model, tools, behaviour)         │
└──────────────────────────┬──────────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          │                │                │
          ▼                ▼                ▼
   ┌────────────┐  ┌─────────────┐  ┌────────────────┐
   │ Behaviour  │  │ AgentRunner │  │   Nous.LLM     │
   │ (Custom    │  │ (Execution  │  │ (Simple text   │
   │  agents)   │  │  loop)      │  │  generation)   │
   └────────────┘  └──────┬──────┘  └────────────────┘
                          │
         ┌────────────────┼────────────────┐
         ▼                ▼                ▼
   ┌───────────┐   ┌───────────┐   ┌───────────────┐
   │  Provider │   │   Tools   │   │    Context    │
   │ (LLM API) │   │ (Actions) │   │  (State/Deps) │
   └───────────┘   └───────────┘   └───────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                       Nous.Eval                                 │
│  (Testing, evaluation, and optimization framework)              │
└─────────────────────────────────────────────────────────────────┘
```

## Key Modules

| Module | Purpose |
|--------|---------|
| `Nous` | Main API - `new/2`, `run/3`, `generate_text/3`, `stream_text/3` |
| `Nous.Agent` | Agent struct and configuration |
| `Nous.Agent.Behaviour` | Pluggable agent behaviour protocol |
| `Nous.Agent.Context` | Unified execution context with messages, deps, usage |
| `Nous.AgentRunner` | Execution loop, tool handling, context merging |
| `Nous.LLM` | Simple text generation API (no agents) |
| `Nous.Tool` | Tool definitions and schema generation |
| `Nous.Tool.ContextUpdate` | Structured context mutations from tools |
| `Nous.RunContext` | Simplified context passed to tools |
| `Nous.Provider` | Provider behaviour with `use` macro |
| `Nous.Eval` | Evaluation framework for testing agents |
| `Nous.Memory.Manager` | Per-agent memory coordination GenServer |

## Simple LLM API

For quick LLM calls without the full agent machinery:

```elixir
# Basic text generation
{:ok, text} = Nous.generate_text("openai:gpt-4", "What is 2+2?")

# With system prompt and options
text = Nous.generate_text!("anthropic:claude-haiku-4-5", "Hello",
  system: "You are a pirate",
  temperature: 0.7,
  max_tokens: 500
)

# With tools
{:ok, text} = Nous.generate_text("openai:gpt-4", "What's the weather in Paris?",
  tools: [&MyTools.get_weather/2],
  deps: %{api_key: "..."}
)

# Streaming
{:ok, stream} = Nous.stream_text("openai:gpt-4", "Write a story")
stream |> Stream.each(&IO.write/1) |> Stream.run()
```

## Agent Behaviour System

Custom agent implementations for specialized execution logic.

### Required Callbacks

```elixir
defmodule MyApp.CustomAgent do
  @behaviour Nous.Agent.Behaviour

  @impl true
  def build_messages(agent, ctx) do
    # Build messages for the LLM
    system_msg = Message.system(agent.instructions)
    [system_msg | ctx.messages]
  end

  @impl true
  def process_response(agent, message, ctx) do
    # Handle LLM response, execute tools
    ctx = Context.add_message(ctx, message)

    if Message.has_tool_calls?(message) do
      execute_tools_and_continue(ctx, message.tool_calls)
    else
      Context.set_needs_response(ctx, false)
    end
  end

  @impl true
  def extract_output(_agent, ctx) do
    # Extract final output from context
    {:ok, Context.last_message(ctx).content}
  end

  @impl true
  def get_tools(agent) do
    agent.tools
  end
end
```

### Optional Callbacks

- `init_context/2` - Initialize context before execution
- `handle_error/3` - Custom error handling (returns `{:retry, ctx}`, `{:continue, ctx}`, or `{:error, reason}`)
- `before_request/3` - Modify request options before LLM call
- `after_tool/4` - Post-process tool results

### Built-in Implementations

- `Nous.Agents.BasicAgent` - Standard tool-calling agent (default)
- `Nous.Agents.ReActAgent` - Structured reasoning with plan/note/final_answer

### Usage

```elixir
agent = Agent.new("openai:gpt-4",
  behaviour_module: MyApp.CustomAgent,
  tools: [&search/2]
)
```

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

Support multiple parameter names for LLM flexibility:

```elixir
content =
  Map.get(args, "content") ||
    Map.get(args, "text") ||
    Map.get(args, "message")
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

Use `ContextUpdate` struct for explicit, composable updates:

```elixir
alias Nous.Tool.ContextUpdate

# Set a key
{:ok, %{success: true},
 ContextUpdate.new() |> ContextUpdate.set(:memories, updated_memories)}

# Append to a list
{:ok, %{added: note},
 ContextUpdate.new() |> ContextUpdate.append(:notes, note)}

# Merge into a map
{:ok, %{updated: true},
 ContextUpdate.new() |> ContextUpdate.merge(:settings, %{theme: "dark"})}

# Delete a key
{:ok, %{cleared: true},
 ContextUpdate.new() |> ContextUpdate.delete(:temp_data)}
```

### Pattern: Error Returns

```elixir
%{
  success: false,
  error: "Descriptive error message"
}
```

### Pattern: Fallback Storage (Manager vs Context)

```elixir
def store_data(ctx, args) do
  case ctx.deps[:memory_manager] do
    nil ->
      # Context-only storage (session-based)
      store_in_context(ctx, args)

    manager ->
      # Persistent storage via GenServer
      store_in_manager(manager, args)
  end
end
```

## Provider Development

### Using the Provider Macro

```elixir
defmodule Nous.Providers.MyProvider do
  use Nous.Provider,
    id: :my_provider,
    default_base_url: "https://api.example.com",
    default_env_key: "MY_API_KEY"

  @impl true
  def chat(params, opts \\ []) do
    # Low-level HTTP request
    # params: %{"model" => ..., "messages" => ...}
    # opts: [api_key: ..., base_url: ..., timeout: ...]
    {:ok, response}
  end

  @impl true
  def chat_stream(params, opts \\ []) do
    # Low-level streaming HTTP request
    {:ok, stream}
  end
end
```

### Injected Functions

The `use Nous.Provider` macro injects:

- `provider_id/0` - Returns the provider atom ID
- `default_base_url/0` - Returns the default API base URL
- `default_env_key/0` - Returns the env var name for API key
- `api_key/1` - Gets API key from opts → env → config
- `base_url/1` - Gets base URL from opts → config → default
- `request/3` - High-level request with telemetry (overridable)
- `request_stream/3` - High-level streaming (overridable)
- `count_tokens/1` - Token estimation (overridable)

### API Key Lookup Order

1. `:api_key` option passed directly
2. Environment variable (e.g., `OPENAI_API_KEY`)
3. Application config: `config :nous, :openai, api_key: "..."`

## Evaluation Framework

### Quick Start

```elixir
# Define a test suite programmatically
suite = Nous.Eval.Suite.new(
  name: "my_agent_tests",
  default_model: "lmstudio:ministral-3b",
  test_cases: [
    Nous.Eval.TestCase.new(
      id: "greeting",
      input: "Say hello",
      expected: %{contains: ["hello", "hi"]},
      eval_type: :contains
    )
  ]
)

# Run the evaluation
{:ok, result} = Nous.Eval.run(suite)

# Print results
Nous.Eval.Reporter.print(result)
```

### Loading from YAML

```yaml
# test/eval/suites/basic.yaml
name: basic_tests
default_model: openai:gpt-4
test_cases:
  - id: greeting
    input: Say hello
    expected:
      contains: [hello, hi]
    eval_type: contains
```

```elixir
{:ok, suite} = Nous.Eval.Suite.from_yaml("test/eval/suites/basic.yaml")
{:ok, result} = Nous.Eval.run(suite)
```

### Built-in Evaluators

| Type | Description |
|------|-------------|
| `:exact_match` | Output must exactly match expected |
| `:fuzzy_match` | String similarity above threshold |
| `:contains` | Output must contain expected substrings |
| `:tool_usage` | Verify correct tools were called |
| `:schema` | Validate structured output against schema |
| `:llm_judge` | Use an LLM to judge output quality |

### Custom Evaluators

```elixir
defmodule MyEvaluator do
  @behaviour Nous.Eval.Evaluator

  @impl true
  def evaluate(actual, expected, config) do
    if my_check(actual, expected) do
      %{score: 1.0, passed: true, reason: nil, details: %{}}
    else
      %{score: 0.0, passed: false, reason: "Did not match", details: %{}}
    end
  end
end

# Use in test case
test_case = TestCase.new(
  id: "custom",
  input: "...",
  expected: "...",
  eval_type: :custom,
  eval_config: %{evaluator: MyEvaluator}
)
```

### A/B Testing

```elixir
{:ok, comparison} = Nous.Eval.run_ab(suite,
  config_a: [model_settings: %{temperature: 0.3}],
  config_b: [model_settings: %{temperature: 0.7}]
)

IO.puts("Winner: #{comparison.comparison.winner}")
```

### Mix Tasks

```bash
mix nous.eval                    # Run all suites
mix nous.eval --suite basic      # Run specific suite
mix nous.eval --tags tool        # Filter by tags
```

## Memory System

### Memory Tiers

- `:working` - Active in current session, not yet persisted
- `:short_term` - Recently accessed, persisted but may decay
- `:long_term` - Consolidated important memories
- `:archived` - Low-relevance memories kept for reference

### Importance Levels

- `:low`, `:medium`, `:high`, `:critical`

### Context-based Memory (Session Only)

```elixir
agent = Nous.new("openai:gpt-4",
  tools: Nous.Tools.MemoryTools.all()
)

{:ok, result} = Nous.run(agent, "Remember my name is Alice")
# Memories stored in ctx.deps[:memories]
```

### Persistent Memory with Manager

```elixir
{:ok, manager} = Nous.Memory.Manager.start_link(
  agent_id: "my_assistant",
  store: {Nous.Memory.Stores.AgentStore, []}
)

{:ok, memory} = Nous.Memory.Manager.store(manager, "User prefers dark mode",
  tags: ["preference"],
  importance: :medium
)

{:ok, results} = Nous.Memory.Manager.recall(manager, "user preferences")

# Pass to agent via deps
{:ok, result} = Nous.run(agent, "What are my preferences?",
  deps: %{memory_manager: manager}
)
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

    test "handles flexible parameter names", %{ctx: ctx} do
      # Test that tool accepts multiple param names
      result1 = MyTools.my_function(ctx, %{"content" => "test"})
      result2 = MyTools.my_function(ctx, %{"text" => "test"})

      assert result1.success == true
      assert result2.success == true
    end

    test "fails with missing required param", %{ctx: ctx} do
      result = MyTools.my_function(ctx, %{})

      assert result.success == false
      assert result.error =~ "required"
    end

    test "handles empty string as missing", %{ctx: ctx} do
      result = MyTools.my_function(ctx, %{"content" => ""})

      assert result.success == false
    end
  end
end
```

### Manager Integration Tests

```elixir
defmodule Nous.Memory.ManagerTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Manager

  setup do
    {:ok, manager} = Manager.start_link(agent_id: "test_agent")
    {:ok, manager: manager}
  end

  test "stores and recalls memories", %{manager: manager} do
    {:ok, memory} = Manager.store(manager, "Test content",
      tags: ["test"],
      importance: :high
    )

    {:ok, results} = Manager.recall(manager, "test")

    assert length(results) == 1
    assert hd(results).content == "Test content"
  end
end
```

### Mocking Model Dispatcher

```elixir
test "handles model response" do
  # Store original
  original = Application.get_env(:nous, :model_dispatcher)

  # Set mock
  Application.put_env(:nous, :model_dispatcher, MockDispatcher)

  # Run test
  result = MyModule.call_model(...)

  # Restore
  Application.put_env(:nous, :model_dispatcher, original)

  assert result == expected
end
```

### Test Tags

```elixir
# Tag LLM-dependent tests
@moduletag :llm

# Run only tagged tests
# mix test --only llm

# Exclude slow tests
# mix test --exclude slow
```

### Running Tests

```bash
mix test                              # All tests
mix test test/path/to/test.exs        # Specific file
mix test --only tag:value             # Tagged tests
mix test --exclude llm                # Exclude LLM tests
```

## File Organization

```
lib/nous/
├── agent.ex              # Agent struct
├── agent_runner.ex       # Execution loop
├── agent_server.ex       # Stateful agent GenServer
├── llm.ex                # Simple LLM API
├── model.ex              # Model parsing/config
├── model_dispatcher.ex   # Routes requests to providers
├── provider.ex           # Provider behaviour + macro
├── agent/
│   ├── behaviour.ex      # Agent behaviour protocol
│   ├── callbacks.ex      # Callback hooks
│   └── context.ex        # Context struct
├── agents/
│   ├── basic_agent.ex    # Standard agent implementation
│   └── react_agent.ex    # ReAct reasoning agent
├── eval/
│   ├── config.ex         # Evaluation configuration
│   ├── evaluator.ex      # Evaluator behaviour
│   ├── evaluators/       # Built-in evaluators
│   │   ├── contains.ex
│   │   ├── exact_match.ex
│   │   ├── fuzzy_match.ex
│   │   ├── llm_judge.ex
│   │   ├── schema.ex
│   │   └── tool_usage.ex
│   ├── metrics.ex        # Metrics collection
│   ├── optimizer.ex      # Hyperparameter optimization
│   ├── optimizer/
│   │   ├── parameter.ex
│   │   ├── search_space.ex
│   │   ├── strategy.ex
│   │   └── strategies/
│   │       ├── bayesian.ex
│   │       ├── grid_search.ex
│   │       └── random.ex
│   ├── reporter.ex       # Results reporting
│   ├── reporter/
│   │   ├── console.ex
│   │   └── json.ex
│   ├── result.ex         # Result struct
│   ├── runner.ex         # Suite execution
│   ├── suite.ex          # Suite struct
│   ├── test_case.ex      # TestCase struct
│   └── yaml_loader.ex    # YAML suite loading
├── memory/
│   ├── memory.ex         # Memory struct
│   ├── store.ex          # Storage behaviour
│   ├── search.ex         # Search behaviour
│   ├── manager.ex        # Per-agent GenServer
│   ├── supervisor.ex     # DynamicSupervisor
│   ├── stores/
│   │   └── agent_store.ex
│   └── search/
│       └── simple.ex     # Simple text search
├── messages/
│   ├── anthropic.ex      # Anthropic message format
│   ├── gemini.ex         # Gemini message format
│   └── openai.ex         # OpenAI message format
├── providers/
│   ├── anthropic.ex
│   ├── gemini.ex
│   ├── lmstudio.ex
│   ├── mistral.ex
│   ├── openai.ex
│   ├── openai_compatible.ex
│   ├── sglang.ex
│   └── vllm.ex
├── stream_normalizer/
│   ├── mistral.ex
│   └── openai.ex
├── tool/
│   ├── behaviour.ex      # Tool behaviour
│   ├── context_update.ex # ContextUpdate struct
│   ├── testing.ex        # Test helpers
│   └── validator.ex      # Input validation
└── tools/
    ├── brave_search.ex
    ├── date_time_tools.ex
    ├── memory_tools.ex
    ├── react_tools.ex
    ├── string_tools.ex
    └── todo_tools.ex
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

### Optional Map Updates

```elixir
defp maybe_update(map, _key, nil), do: map
defp maybe_update(map, key, value), do: Map.put(map, key, value)
```

### Optional Keyword List Additions

```elixir
defp maybe_add(opts, _key, nil), do: opts
defp maybe_add(opts, _key, []), do: opts
defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

# Usage
opts =
  [limit: 10]
  |> maybe_add(:tags, tags)
  |> maybe_add(:importance, importance)
```

### Parse Tags from String or List

```elixir
defp parse_tags(nil), do: nil
defp parse_tags(tags) when is_list(tags), do: tags
defp parse_tags(tags) when is_binary(tags), do: String.split(tags, ",", trim: true)
```

### Parse Importance Levels

```elixir
defp parse_importance(nil), do: nil
defp parse_importance("low"), do: :low
defp parse_importance("medium"), do: :medium
defp parse_importance("high"), do: :high
defp parse_importance("critical"), do: :critical
defp parse_importance(atom) when is_atom(atom), do: atom
defp parse_importance(_), do: :medium
```

### Importance Level Ordering

```elixir
defp importance_level(:low), do: 1
defp importance_level(:medium), do: 2
defp importance_level(:high), do: 3
defp importance_level(:critical), do: 4
```

### Truncate Helper

```elixir
defp truncate(string, max_length) do
  if String.length(string) > max_length do
    String.slice(string, 0, max_length) <> "..."
  else
    string
  end
end
```
