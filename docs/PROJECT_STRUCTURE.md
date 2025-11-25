# Yggdrasil AI - Complete Project Structure

## Overview

This document defines the **complete folder structure, module organization, and architecture** before we write any code. This is our blueprint.

---

## Directory Structure

```
exadantic/
├── lib/
│   ├── exadantic.ex                          # Main module, public API facade
│   │
│   ├── exadantic/
│   │   ├── application.ex                    # OTP Application
│   │   │
│   │   ├── types.ex                          # Core type definitions
│   │   ├── usage.ex                          # Token/cost tracking
│   │   ├── run_context.ex                    # Context for tools/prompts
│   │   │
│   │   ├── agent.ex                          # Agent definition (public API)
│   │   ├── agent_runner.ex                   # Agent execution engine (GenServer)
│   │   │
│   │   ├── model.ex                          # Model configuration struct
│   │   ├── model_parser.ex                   # Parse "provider:model" strings
│   │   │
│   │   ├── messages.ex                       # Message construction & conversion
│   │   │
│   │   ├── tool.ex                           # Tool definition struct
│   │   ├── tool_schema.ex                    # JSON schema generation
│   │   ├── tool_executor.ex                  # Tool execution with retries
│   │   │
│   │   ├── output.ex                         # Output extraction & validation
│   │   │
│   │   ├── models/
│   │   │   ├── behaviour.ex                  # Model behaviour definition
│   │   │   └── openai_compatible.ex          # OpenAI API implementation
│   │   │
│   │   ├── telemetry.ex                      # Telemetry events
│   │   │
│   │   ├── errors.ex                         # Custom error types
│   │   │
│   │   └── testing/
│   │       ├── mock_model.ex                 # Mock model for tests
│   │       └── test_helpers.ex               # Test utilities
│   │
│   └── mix/
│       └── tasks/
│           └── exadantic.ex                  # Mix tasks (if needed)
│
├── test/
│   ├── test_helper.exs                       # Test configuration
│   │
│   ├── exadantic_test.exs                    # Main module tests
│   │
│   ├── exadantic/
│   │   ├── agent_test.exs                    # Agent tests
│   │   ├── agent_runner_test.exs             # AgentRunner tests
│   │   ├── model_test.exs                    # Model config tests
│   │   ├── model_parser_test.exs             # Parser tests
│   │   ├── messages_test.exs                 # Message tests
│   │   ├── tool_test.exs                     # Tool tests
│   │   ├── tool_executor_test.exs            # Tool executor tests
│   │   ├── usage_test.exs                    # Usage tracking tests
│   │   │
│   │   └── models/
│   │       └── openai_compatible_test.exs    # Integration tests
│   │
│   └── support/
│       ├── fixtures.ex                       # Test fixtures
│       └── test_tools.ex                     # Tools for testing
│
├── examples/
│   ├── simple.exs                            # Basic example
│   ├── with_tools.exs                        # Tools example
│   ├── local_lm_studio.exs                   # LM Studio example
│   ├── comparing_providers.exs               # Multi-provider example
│   ├── local_vs_cloud.exs                    # Routing example
│   ├── streaming.exs                         # Streaming example
│   ├── conversation.exs                      # Multi-turn conversation
│   └── structured_output.exs                 # Ecto validation example
│
├── config/
│   ├── config.exs                            # Base config
│   ├── dev.exs                               # Development config
│   ├── test.exs                              # Test config
│   └── runtime.exs                           # Runtime config
│
├── docs/
│   ├── guides/
│   │   ├── getting_started.md
│   │   ├── tools.md
│   │   ├── local_llms.md
│   │   ├── structured_outputs.md
│   │   └── multi_agent.md
│   │
│   └── architecture.md
│
├── .formatter.exs                            # Code formatting
├── .gitignore
├── .credo.exs                                # Code quality
├── .dialyzer_ignore.exs                      # Dialyzer config
├── mix.exs                                   # Project definition
├── README.md                                 # Main documentation
├── CHANGELOG.md                              # Version history
└── LICENSE                                   # MIT License
```

---

## Module Hierarchy & Responsibilities

### Layer 1: Public API

```
Yggdrasil
├── new/2              # Shorthand for Agent.new/2
├── run/3              # Shorthand for Agent.run/3
└── run_stream/3       # Shorthand for Agent.run_stream/3
```

**Purpose:** Simple, friendly public API for quick usage.

---

### Layer 2: Core Modules

#### `Yggdrasil.Agent`
**File:** `lib/exadantic/agent.ex`

```elixir
defmodule Yggdrasil.Agent do
  @moduledoc "Agent definition and configuration"

  defstruct [
    :model,           # Model.t()
    :output_type,     # :string | module()
    :instructions,    # String.t() | function() | nil
    :system_prompt,   # String.t() | function() | nil
    :deps_type,       # module() | nil
    :name,            # String.t()
    :model_settings,  # map()
    :retries,         # non_neg_integer()
    :tools,           # [Tool.t()]
    :end_strategy     # :early | :exhaustive
  ]

  # Public API
  def new(model_string, opts \\ [])
  def run(agent, prompt, opts \\ [])
  def run_stream(agent, prompt, opts \\ [])
  def tool(agent, tool_fun, opts \\ [])
end
```

**Responsibilities:**
- Agent configuration
- Delegate to AgentRunner for execution
- Tool registration

---

#### `Yggdrasil.AgentRunner`
**File:** `lib/exadantic/agent_runner.ex`

```elixir
defmodule Yggdrasil.AgentRunner do
  @moduledoc "Agent execution engine - handles the agent loop"

  # Public API
  def run(agent, prompt, opts)
  def run_stream(agent, prompt, opts)

  # Private - execution loop
  defp execute_loop(state, messages)
  defp handle_tool_calls(state, messages, response, tool_calls)
  defp build_messages(state, prompt)
  defp extract_output(response, output_type)
end
```

**Responsibilities:**
- Execute agent to completion
- Manage message loop
- Call model
- Execute tools when requested
- Extract final output
- Track usage

**State:**
```elixir
%{
  agent: Agent.t(),
  deps: any(),
  message_history: [message()],
  usage: Usage.t(),
  iteration: non_neg_integer()
}
```

---

### Layer 3: Data Structures

#### `Yggdrasil.Types`
**File:** `lib/exadantic/types.ex`

```elixir
defmodule Yggdrasil.Types do
  @moduledoc "Core type definitions"

  @type content :: String.t() | {:text, String.t()} | {:image_url, String.t()}
  @type system_prompt_part :: {:system_prompt, String.t()}
  @type user_prompt_part :: {:user_prompt, String.t() | [content()]}
  @type tool_return_part :: {:tool_return, tool_return()}
  @type text_part :: {:text, String.t()}
  @type tool_call_part :: {:tool_call, tool_call()}

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}
  @type tool_return :: %{call_id: String.t(), result: any()}

  @type model_response :: %{
    parts: [response_part()],
    usage: Usage.t(),
    model_name: String.t(),
    timestamp: DateTime.t()
  }
end
```

**Responsibilities:**
- Define all type specs
- Documentation for types
- No functions, just types

---

#### `Yggdrasil.Usage`
**File:** `lib/exadantic/usage.ex`

```elixir
defmodule Yggdrasil.Usage do
  @moduledoc "Token and cost tracking"

  defstruct [
    requests: 0,
    tool_calls: 0,
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0
  ]

  def new()
  def add(u1, u2)
  def inc_requests(usage)
  def inc_tool_calls(usage, count \\ 1)
  def from_openai(openai_usage)
end
```

**Responsibilities:**
- Track usage metrics
- Aggregate across runs
- Convert from OpenAI format

---

#### `Yggdrasil.RunContext`
**File:** `lib/exadantic/run_context.ex`

```elixir
defmodule Yggdrasil.RunContext do
  @moduledoc "Context passed to tools and dynamic prompts"

  @type t(deps) :: %__MODULE__{
    deps: deps,
    retry: non_neg_integer(),
    usage: Usage.t()
  }

  defstruct [:deps, retry: 0, usage: %Usage{}]

  def new(deps, opts \\ [])
end
```

**Responsibilities:**
- Provide context to tools
- Track retry count
- Access to dependencies

---

### Layer 4: Model Abstraction

#### `Yggdrasil.Model`
**File:** `lib/exadantic/model.ex`

```elixir
defmodule Yggdrasil.Model do
  @moduledoc "Model configuration"

  @type provider :: :openai | :groq | :ollama | :lmstudio | :custom

  defstruct [
    :provider,          # provider()
    :model,             # String.t()
    :base_url,          # String.t() | nil
    :api_key,           # String.t() | nil
    :organization,      # String.t() | nil
    default_settings: %{}
  ]

  def to_client(model)  # Create OpenaiEx client
end
```

**Responsibilities:**
- Store model configuration
- Convert to OpenaiEx client

---

#### `Yggdrasil.ModelParser`
**File:** `lib/exadantic/model_parser.ex`

```elixir
defmodule Yggdrasil.ModelParser do
  @moduledoc "Parse model strings like 'openai:gpt-4'"

  def parse(model_string, opts \\ [])
  # Returns Model.t()
end
```

**Responsibilities:**
- Parse "provider:model" format
- Extract provider and model name
- Apply defaults and options
- Return Model struct

**Supported formats:**
- `"openai:gpt-4"`
- `"groq:llama-3.1-70b-versatile"`
- `"ollama:llama2"`
- `"lmstudio:qwen/qwen3-30b-a3b-2507"`
- `"custom:my-model"` (requires base_url)

---

#### `Yggdrasil.Models.Behaviour`
**File:** `lib/exadantic/models/behaviour.ex`

```elixir
defmodule Yggdrasil.Models.Behaviour do
  @moduledoc "Behaviour for model implementations"

  @callback request(Model.t(), [message()], map()) ::
    {:ok, model_response()} | {:error, term()}

  @callback request_stream(Model.t(), [message()], map()) ::
    {:ok, Enumerable.t()} | {:error, term()}

  @callback count_tokens([message()]) :: integer()

  @optional_callbacks count_tokens: 1
end
```

---

#### `Yggdrasil.Models.OpenAICompatible`
**File:** `lib/exadantic/models/openai_compatible.ex`

```elixir
defmodule Yggdrasil.Models.OpenAICompatible do
  @moduledoc "OpenAI-compatible API implementation using openai_ex"

  @behaviour Yggdrasil.Models.Behaviour

  def request(model, messages, settings)
  def request_stream(model, messages, settings)
  def count_tokens(messages)

  # Private
  defp build_request_params(model, messages, settings)
  defp parse_stream_chunk(chunk)
  defp format_error(error)
end
```

**Responsibilities:**
- Use OpenaiEx to call models
- Convert our messages to OpenAI format
- Parse OpenAI responses
- Handle streaming
- Error handling

---

### Layer 5: Messages

#### `Yggdrasil.Messages`
**File:** `lib/exadantic/messages.ex`

```elixir
defmodule Yggdrasil.Messages do
  @moduledoc "Message construction and conversion"

  # Constructors
  def system_prompt(text)
  def user_prompt(content)
  def tool_return(call_id, result)

  # Extractors
  def extract_text(parts)
  def extract_tool_calls(parts)

  # Conversion
  def to_openai_messages(messages)
  def from_openai_response(response)
end
```

**Responsibilities:**
- Create message parts
- Extract data from responses
- Convert to/from OpenAI format

---

### Layer 6: Tools

#### `Yggdrasil.Tool`
**File:** `lib/exadantic/tool.ex`

```elixir
defmodule Yggdrasil.Tool do
  @moduledoc "Tool definition"

  defstruct [
    :name,           # String.t()
    :description,    # String.t()
    :parameters,     # map() - JSON schema
    :function,       # function()
    takes_ctx: true, # boolean()
    retries: 1       # non_neg_integer()
  ]

  def from_function(fun, opts \\ [])
  def to_openai_schema(tool)
end
```

**Responsibilities:**
- Define tool structure
- Create from function
- Generate OpenAI function schema

---

#### `Yggdrasil.ToolSchema`
**File:** `lib/exadantic/tool_schema.ex`

```elixir
defmodule Yggdrasil.ToolSchema do
  @moduledoc "Generate JSON schemas for tools"

  def from_function(fun)
  def from_module_docs(module, function, arity)

  # Private
  defp extract_parameter_info(doc_string)
  defp generate_schema(param_info)
end
```

**Responsibilities:**
- Extract function metadata
- Parse docstrings
- Generate JSON schema for parameters

---

#### `Yggdrasil.ToolExecutor`
**File:** `lib/exadantic/tool_executor.ex`

```elixir
defmodule Yggdrasil.ToolExecutor do
  @moduledoc "Execute tools with retry logic"

  def execute(tool, arguments, ctx)

  # Private
  defp do_execute(tool, arguments, ctx, attempt)
  defp apply_tool(fun, args)
  defp apply_tool_with_ctx(fun, ctx, args)
end
```

**Responsibilities:**
- Execute tool functions
- Handle retries on failure
- Pass context when needed
- Log execution

---

### Layer 7: Output

#### `Yggdrasil.Output`
**File:** `lib/exadantic/output.ex`

```elixir
defmodule Yggdrasil.Output do
  @moduledoc "Output extraction and validation"

  def extract(response, output_type)
  def validate_with_ecto(data, module)
  def generate_schema(module)

  # Private
  defp ecto_type_to_json_schema(type)
end
```

**Responsibilities:**
- Extract output from response
- Validate with Ecto schemas
- Generate JSON schemas from Ecto

---

### Layer 8: Infrastructure

#### `Yggdrasil.Application`
**File:** `lib/exadantic/application.ex`

```elixir
defmodule Yggdrasil.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Finch, name: Yggdrasil.Finch, pools: pools()},
      Yggdrasil.Telemetry.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp pools() # HTTP connection pools
end
```

---

#### `Yggdrasil.Telemetry`
**File:** `lib/exadantic/telemetry.ex`

```elixir
defmodule Yggdrasil.Telemetry do
  @moduledoc "Telemetry events"

  def agent_run_start(agent_name, model)
  def agent_run_stop(agent_name, duration, usage)
  def model_request(model, tokens)
  def tool_execute(tool_name, duration, success)
end
```

---

#### `Yggdrasil.Errors`
**File:** `lib/exadantic/errors.ex`

```elixir
defmodule Yggdrasil.Errors do
  @moduledoc "Custom error types"

  defmodule ModelError do
    defexception [:message, :provider, :status_code]
  end

  defmodule ToolError do
    defexception [:message, :tool_name, :attempt]
  end

  defmodule ValidationError do
    defexception [:message, :errors]
  end

  defmodule UsageLimitExceeded do
    defexception [:message, :limit_type]
  end
end
```

---

### Layer 9: Testing

#### `Yggdrasil.Testing.MockModel`
**File:** `lib/exadantic/testing/mock_model.ex`

```elixir
defmodule Yggdrasil.Testing.MockModel do
  @moduledoc "Mock model for testing"

  @behaviour Yggdrasil.Models.Behaviour

  def request(model, messages, settings)
  def request_stream(model, messages, settings)
  def count_tokens(messages)
end
```

---

## Public API Design

### Simple Usage (via Yggdrasil module)

```elixir
# Quick usage
agent = Yggdrasil.new("openai:gpt-4")
{:ok, result} = Yggdrasil.run(agent, "Hello!")
```

### Full Usage (via Yggdrasil.Agent)

```elixir
# Full control
agent = Yggdrasil.Agent.new("openai:gpt-4",
  instructions: "Be helpful",
  tools: [&MyTools.search/2],
  model_settings: %{temperature: 0.7}
)

{:ok, result} = Yggdrasil.Agent.run(agent, "Search for Elixir")
```

---

## Module Dependencies Graph

```
Yggdrasil (facade)
    ↓
Yggdrasil.Agent
    ↓
Yggdrasil.AgentRunner
    ↓
├─→ Yggdrasil.Models.OpenAICompatible
│       ↓
│   Yggdrasil.Model
│       ↓
│   OpenaiEx (external)
│
├─→ Yggdrasil.Messages
│
├─→ Yggdrasil.ToolExecutor
│       ↓
│   Yggdrasil.Tool
│       ↓
│   Yggdrasil.ToolSchema
│
├─→ Yggdrasil.Output
│
└─→ Yggdrasil.Usage
```

---

## Configuration Structure

```elixir
# config/config.exs
config :yggdrasil,
  # API Keys
  openai_api_key: {:system, "OPENAI_API_KEY"},
  groq_api_key: {:system, "GROQ_API_KEY"},
  openrouter_api_key: {:system, "OPENROUTER_API_KEY"},

  # Finch pool
  finch: Yggdrasil.Finch,

  # Timeouts
  default_timeout: 60_000,
  stream_timeout: 120_000,

  # Telemetry
  enable_telemetry: true
```

---

## File Size Estimates

| File | Lines | Complexity |
|------|-------|------------|
| exadantic.ex | ~50 | Low |
| agent.ex | ~150 | Medium |
| agent_runner.ex | ~250 | High |
| model.ex | ~100 | Low |
| model_parser.ex | ~120 | Medium |
| messages.ex | ~200 | Medium |
| tool.ex | ~100 | Medium |
| tool_schema.ex | ~150 | High |
| tool_executor.ex | ~80 | Low |
| models/openai_compatible.ex | ~300 | High |
| usage.ex | ~60 | Low |
| run_context.ex | ~30 | Low |
| output.ex | ~120 | Medium |
| types.ex | ~100 | Low |
| telemetry.ex | ~80 | Low |
| errors.ex | ~50 | Low |

**Total:** ~2,000 lines of production code

---

## Implementation Order (with Dependencies)

```
Phase 1: Foundation (No dependencies)
  1. types.ex
  2. usage.ex
  3. run_context.ex
  4. errors.ex

Phase 2: Configuration (Depends on Phase 1)
  5. model.ex
  6. model_parser.ex

Phase 3: Messages (Depends on Phase 1)
  7. messages.ex

Phase 4: Tools (Depends on Phase 1)
  8. tool.ex
  9. tool_schema.ex
  10. tool_executor.ex

Phase 5: Output (Depends on Phase 1, 3)
  11. output.ex

Phase 6: Model Integration (Depends on Phase 1-3)
  12. models/behaviour.ex
  13. models/openai_compatible.ex

Phase 7: Execution (Depends on All Above)
  14. agent_runner.ex

Phase 8: Public API (Depends on All Above)
  15. agent.ex
  16. exadantic.ex

Phase 9: Infrastructure (Depends on All Above)
  17. application.ex
  18. telemetry.ex

Phase 10: Testing (Depends on All Above)
  19. testing/mock_model.ex
  20. testing/test_helpers.ex
```

---

## Key Design Decisions

### 1. **Separation of Concerns**
- Agent = Configuration
- AgentRunner = Execution
- Tool = Definition
- ToolExecutor = Execution

### 2. **No GenServers for Agents**
- Agents are just structs (stateless)
- AgentRunner handles execution (can be sync or async)
- Simpler than making Agent a GenServer

### 3. **Message Format**
- Internal: Tagged tuples `{:system_prompt, text}`
- Easy pattern matching
- Convert to OpenAI format only when calling API

### 4. **Tool Schema Generation**
- Extract from function docs (@doc)
- Fallback to simple schema
- Users can override with explicit parameters

### 5. **Error Handling**
- Custom exception types
- Tagged tuples for results `{:ok, result} | {:error, reason}`
- Telemetry for monitoring

### 6. **Testing Strategy**
- MockModel for unit tests (no API calls)
- Integration tests with real APIs (tagged :integration)
- Test fixtures for common scenarios

---

## Next Steps

1. ✅ Review this structure
2. Create the project skeleton
3. Implement modules in order (Phase 1 → Phase 10)
4. Write tests alongside each module
5. Create examples
6. Document

**Ready to start building?** Let's begin with Phase 1!
