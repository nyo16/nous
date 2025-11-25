# Yggdrasil AI - Elixir Port of Pydantic AI

## Executive Summary

This document outlines the design and implementation plan for **Yggdrasil AI**, an Elixir library that ports the core concepts and architecture of [Pydantic AI](https://ai.pydantic.dev/) to the Elixir ecosystem. The goal is to create a type-safe, model-agnostic AI agent framework that leverages Elixir's strengths: concurrent processing, fault tolerance, pattern matching, and the actor model.

## Table of Contents

1. [Overview](#overview)
2. [Core Architecture](#core-architecture)
3. [Key Components](#key-components)
4. [Implementation Details](#implementation-details)
5. [Elixir-Specific Advantages](#elixir-specific-advantages)
6. [API Design](#api-design)
7. [Implementation Roadmap](#implementation-roadmap)
8. [Testing Strategy](#testing-strategy)
9. [Dependencies](#dependencies)

---

## Overview

### What is Pydantic AI?

Pydantic AI is a Python framework for building production-grade applications with Large Language Models (LLMs). Key features include:

- **Model Agnostic**: Support for multiple AI providers (OpenAI, Anthropic, Google, etc.)
- **Type Safe**: Leverages Python's type system for structured outputs
- **Agent-Based**: Sophisticated containers for managing AI interactions
- **Tool Integration**: Functions that LLMs can call to access external data
- **Dependency Injection**: Clean, testable architecture
- **Streaming**: Real-time response streaming
- **Observability**: Built-in instrumentation and monitoring

### Why Port to Elixir?

1. **Concurrency**: Handle multiple AI requests efficiently with lightweight processes
2. **Fault Tolerance**: Supervisor trees for robust error handling
3. **Distribution**: Easy horizontal scaling across nodes
4. **Pattern Matching**: Natural fit for message parsing and routing
5. **Hot Code Reloading**: Update agents without downtime
6. **Telemetry**: Built-in observability with `:telemetry`
7. **Type Safety**: Typespecs and Dialyzer for compile-time checks

---

## Core Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────┐
│                    Application Layer                     │
│  (User Code: Define Agents, Tools, Dependencies)        │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│                    Agent Layer                         │
│  • Agent Behavior Definition                           │
│  • Tool Registration                                   │
│  • Instruction Management                              │
│  • Output Validation                                   │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│                  Execution Layer                       │
│  • GenServer-based Agent Runner                        │
│  • Message History Management                          │
│  • Streaming Coordination                              │
│  • Tool Execution                                      │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│                   Model Layer                          │
│  • Model Abstraction (Behaviour)                       │
│  • Provider-Specific Implementations                   │
│  • HTTP Client Management                              │
│  • Token Counting                                      │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│              External Services Layer                   │
│  • OpenAI, Anthropic, Google, etc.                    │
│  • HTTP APIs                                           │
└─────────────────────────────────────────────────────────┘
```

### Process Architecture

```
                    ┌──────────────────┐
                    │  Supervisor      │
                    │  (AgentSupervisor)│
                    └────────┬─────────┘
                             │
         ┏━━━━━━━━━━━━━━━━━━━┻━━━━━━━━━━━━━━━━━━━┓
         ▼                                        ▼
┌─────────────────┐                     ┌─────────────────┐
│  AgentRunner    │                     │  ModelPool      │
│  (GenServer)    │────────────────────▶│  (Supervisor)   │
│  • Run agents   │                     │  • HTTP pools   │
│  • Manage state │                     │  • Connections  │
└─────────────────┘                     └─────────────────┘
         │
         ▼
┌─────────────────┐
│  ToolExecutor   │
│  (Task.Supervisor)│
│  • Execute tools│
│  • Timeout mgmt │
└─────────────────┘
```

---

## Key Components

### 1. Agent (`Yggdrasil.Agent`)

The primary interface for defining and running AI agents.

**Responsibilities:**
- Define agent configuration (model, instructions, tools)
- Manage agent lifecycle
- Coordinate tool execution
- Handle structured outputs
- Maintain conversation history

**Key Functions:**
```elixir
# Create a new agent
Agent.new(model, opts \\ [])

# Run agent synchronously
Agent.run(agent, prompt, opts \\ [])

# Run agent with streaming
Agent.run_stream(agent, prompt, opts \\ [])

# Register tools
Agent.tool(agent, tool_fun, opts \\ [])
```

### 2. Messages (`Yggdrasil.Messages`)

Structured representation of conversations between user, model, and tools.

**Message Types:**
```elixir
@type model_request :: %{
  parts: [message_part()],
  timestamp: DateTime.t()
}

@type model_response :: %{
  parts: [response_part()],
  usage: usage(),
  model_name: String.t(),
  timestamp: DateTime.t()
}

@type message_part ::
  {:system_prompt, String.t()}
  | {:user_prompt, String.t() | [content()]}
  | {:tool_return, tool_return()}

@type response_part ::
  {:text, String.t()}
  | {:tool_call, tool_call()}
  | {:thinking, String.t()}

@type content ::
  {:text, String.t()}
  | {:image_url, String.t()}
  | {:audio_url, String.t()}
```

### 3. Models (`Yggdrasil.Models`)

Model abstraction layer for different AI providers.

**Behaviour Definition:**
```elixir
defmodule Yggdrasil.Models.Behaviour do
  @callback model_name() :: String.t()
  @callback system() :: String.t()
  @callback request(messages, settings) :: {:ok, response} | {:error, term}
  @callback request_stream(messages, settings) :: {:ok, stream} | {:error, term}
  @callback count_tokens(messages) :: integer()
end
```

**Provider Implementations:**
- `Yggdrasil.Models.OpenAI`
- `Yggdrasil.Models.Anthropic`
- `Yggdrasil.Models.Google`
- `Yggdrasil.Models.Groq`
- `Yggdrasil.Models.Custom` (for custom providers)

### 4. Tools (`Yggdrasil.Tools`)

Functions that agents can call to retrieve data or perform actions.

**Tool Definition:**
```elixir
defmodule Yggdrasil.Tool do
  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    parameters: schema(),
    function: function(),
    retries: non_neg_integer(),
    requires_approval: boolean()
  }

  defstruct [
    :name,
    :description,
    :parameters,
    :function,
    retries: 1,
    requires_approval: false
  ]
end
```

### 5. Output Handling (`Yggdrasil.Output`)

Structured output validation and processing.

**Output Types:**
```elixir
# Using Ecto for validation
defmodule UserProfile do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string
    field :age, :integer
    field :email, :string
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:name, :age, :email])
    |> validate_required([:name, :email])
  end
end

# Use with agent
agent = Agent.new("openai:gpt-4", output_type: UserProfile)
{:ok, result} = Agent.run(agent, "Extract user info: John, 30, john@example.com")
result.output # %UserProfile{name: "John", age: 30, email: "john@example.com"}
```

### 6. Dependencies (`Yggdrasil.RunContext`)

Type-safe dependency injection for agents and tools.

```elixir
defmodule MyDeps do
  defstruct [:api_key, :http_client, :database]
end

# Access in tools
def search_database(ctx, query) do
  # ctx.deps.database
  # ctx.deps.http_client
end
```

### 7. Streaming (`Yggdrasil.Stream`)

Real-time streaming of agent responses.

```elixir
{:ok, stream} = Agent.run_stream(agent, "Tell me a story")

stream
|> Stream.each(fn event ->
  case event do
    {:text_delta, text} -> IO.write(text)
    {:tool_call, call} -> IO.inspect(call)
    {:complete, result} -> IO.puts("\nDone!")
  end
end)
|> Stream.run()
```

### 8. Usage Tracking (`Yggdrasil.Usage`)

Token and cost tracking across agent runs.

```elixir
defmodule Yggdrasil.Usage do
  defstruct [
    requests: 0,
    tool_calls: 0,
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0
  ]
end
```

---

## Implementation Details

### Module Structure

```
lib/
├── exadantic.ex                    # Main module, public API
├── exadantic/
│   ├── agent.ex                    # Agent definition and configuration
│   ├── agent_runner.ex             # GenServer for agent execution
│   ├── messages.ex                 # Message types and serialization
│   ├── output.ex                   # Output handling and validation
│   ├── run_context.ex              # Context for tool/prompt execution
│   ├── tool.ex                     # Tool definition
│   ├── tool_executor.ex            # Tool execution logic
│   ├── usage.ex                    # Usage tracking
│   ├── stream.ex                   # Streaming helpers
│   ├── models/
│   │   ├── behaviour.ex            # Model behaviour
│   │   ├── openai.ex               # OpenAI implementation
│   │   ├── anthropic.ex            # Anthropic implementation
│   │   ├── google.ex               # Google Gemini implementation
│   │   ├── groq.ex                 # Groq implementation
│   │   └── settings.ex             # Model settings
│   ├── exceptions.ex               # Custom exceptions
│   ├── telemetry.ex                # Telemetry events
│   └── utils/
│       ├── json_schema.ex          # JSON schema generation
│       ├── http_client.ex          # HTTP client wrapper
│       └── token_counter.ex        # Token counting utilities
test/
├── exadantic_test.exs
├── agent_test.exs
├── models/
│   ├── openai_test.exs
│   └── anthropic_test.exs
└── support/
    ├── test_model.ex               # Test model for unit tests
    └── fixtures.ex                 # Test fixtures
```

### Agent Implementation

```elixir
defmodule Yggdrasil.Agent do
  @moduledoc """
  Primary interface for AI agents.

  ## Example

      agent = Agent.new("openai:gpt-4",
        instructions: "Be concise and helpful",
        tools: [&search_database/2]
      )

      {:ok, result} = Agent.run(agent, "What is the capital of France?")
      IO.puts(result.output) # "Paris"
  """

  alias Yggdrasil.{AgentRunner, Tool, Messages, RunContext}

  @type t :: %__MODULE__{
    model: String.t() | module(),
    output_type: module() | :string,
    instructions: String.t() | function(),
    system_prompt: String.t() | function(),
    deps_type: module() | nil,
    name: String.t(),
    model_settings: map(),
    retries: non_neg_integer(),
    tools: [Tool.t()],
    end_strategy: :early | :exhaustive
  }

  defstruct [
    :model,
    :output_type,
    :instructions,
    :system_prompt,
    :deps_type,
    :name,
    :model_settings,
    :retries,
    :tools,
    :end_strategy
  ]

  @doc "Create a new agent"
  def new(model, opts \\ []) do
    %__MODULE__{
      model: parse_model(model),
      output_type: Keyword.get(opts, :output_type, :string),
      instructions: Keyword.get(opts, :instructions),
      system_prompt: Keyword.get(opts, :system_prompt),
      deps_type: Keyword.get(opts, :deps_type),
      name: Keyword.get(opts, :name, generate_name()),
      model_settings: Keyword.get(opts, :model_settings, %{}),
      retries: Keyword.get(opts, :retries, 1),
      tools: Keyword.get(opts, :tools, []),
      end_strategy: Keyword.get(opts, :end_strategy, :early)
    }
  end

  @doc "Run agent synchronously"
  def run(agent, prompt, opts \\ []) do
    deps = Keyword.get(opts, :deps)
    message_history = Keyword.get(opts, :message_history, [])
    usage_limits = Keyword.get(opts, :usage_limits)

    AgentRunner.run(agent, prompt,
      deps: deps,
      message_history: message_history,
      usage_limits: usage_limits
    )
  end

  @doc "Run agent with streaming"
  def run_stream(agent, prompt, opts \\ []) do
    AgentRunner.run_stream(agent, prompt, opts)
  end

  @doc "Register a tool with the agent"
  def tool(agent, tool_fun, opts \\ []) do
    tool = Tool.from_function(tool_fun, opts)
    %{agent | tools: [tool | agent.tools]}
  end

  # Private functions

  defp parse_model("openai:" <> model_name) do
    {Yggdrasil.Models.OpenAI, model_name}
  end

  defp parse_model("anthropic:" <> model_name) do
    {Yggdrasil.Models.Anthropic, model_name}
  end

  defp parse_model(model) when is_atom(model) do
    model
  end

  defp generate_name do
    "agent_#{:erlang.unique_integer([:positive])}"
  end
end
```

### AgentRunner (GenServer)

```elixir
defmodule Yggdrasil.AgentRunner do
  @moduledoc """
  GenServer that manages agent execution lifecycle.
  """

  use GenServer
  alias Yggdrasil.{Agent, Messages, Tool, ToolExecutor, Usage}

  defmodule State do
    defstruct [
      :agent,
      :message_history,
      :usage,
      :current_iteration,
      :max_iterations,
      :deps
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Run agent to completion"
  def run(agent, prompt, opts \\ []) do
    {:ok, pid} = start_link(agent: agent, opts: opts)
    GenServer.call(pid, {:run, prompt}, :infinity)
  end

  @doc "Run agent with streaming"
  def run_stream(agent, prompt, opts \\ []) do
    {:ok, pid} = start_link(agent: agent, opts: opts)

    stream = Stream.resource(
      fn -> {pid, prompt} end,
      fn {pid, prompt} = acc ->
        case GenServer.call(pid, {:next_event, prompt}, :infinity) do
          {:event, event} -> {[event], acc}
          :done -> {:halt, acc}
        end
      end,
      fn {pid, _} -> GenServer.stop(pid) end
    )

    {:ok, stream}
  end

  @impl true
  def init(opts) do
    agent = Keyword.fetch!(opts, :agent)
    run_opts = Keyword.get(opts, :opts, [])

    state = %State{
      agent: agent,
      message_history: Keyword.get(run_opts, :message_history, []),
      usage: Usage.new(),
      current_iteration: 0,
      max_iterations: 10,
      deps: Keyword.get(run_opts, :deps)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:run, prompt}, _from, state) do
    # Build initial messages
    messages = build_messages(state, prompt)

    # Execute agent loop
    result = execute_loop(state, messages)

    {:reply, result, state}
  end

  defp execute_loop(state, messages) do
    # Get model
    {model_module, model_name} = state.agent.model

    # Make request
    case model_module.request(messages, state.agent.model_settings) do
      {:ok, response} ->
        # Update usage
        new_usage = Usage.add(state.usage, response.usage)

        # Check for tool calls
        tool_calls = extract_tool_calls(response)

        if Enum.empty?(tool_calls) do
          # No tool calls, extract output
          output = extract_output(response, state.agent.output_type)
          {:ok, %{output: output, usage: new_usage, messages: messages}}
        else
          # Execute tools
          tool_results = execute_tools(tool_calls, state)

          # Add tool results to messages
          new_messages = messages ++ [response] ++ tool_results

          # Continue loop
          if state.current_iteration < state.max_iterations do
            execute_loop(%{state | current_iteration: state.current_iteration + 1}, new_messages)
          else
            {:error, :max_iterations_exceeded}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tools(tool_calls, state) do
    Enum.map(tool_calls, fn tool_call ->
      # Find tool
      tool = Enum.find(state.agent.tools, fn t -> t.name == tool_call.name end)

      if tool do
        # Create run context
        ctx = %RunContext{
          deps: state.deps,
          retry: 0,
          usage: state.usage
        }

        # Execute tool
        case ToolExecutor.execute(tool, tool_call.arguments, ctx) do
          {:ok, result} ->
            Messages.tool_return(tool_call.id, result)

          {:error, reason} ->
            Messages.tool_return(tool_call.id, "Error: #{inspect(reason)}")
        end
      else
        Messages.tool_return(tool_call.id, "Tool not found: #{tool_call.name}")
      end
    end)
  end

  defp build_messages(state, prompt) do
    # Build system prompt
    system_parts = build_system_prompt(state)

    # Add message history
    history = state.message_history

    # Add user prompt
    user_message = Messages.user_prompt(prompt)

    system_parts ++ history ++ [user_message]
  end

  defp build_system_prompt(state) do
    parts = []

    # Add instructions
    parts = if state.agent.instructions do
      [Messages.system_prompt(state.agent.instructions) | parts]
    else
      parts
    end

    # Add tool schemas
    parts = if not Enum.empty?(state.agent.tools) do
      tool_schemas = Enum.map(state.agent.tools, &Tool.to_schema/1)
      [Messages.system_prompt("Available tools: #{Jason.encode!(tool_schemas)}") | parts]
    else
      parts
    end

    Enum.reverse(parts)
  end

  defp extract_tool_calls(response) do
    response.parts
    |> Enum.filter(fn
      {:tool_call, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:tool_call, call} -> call end)
  end

  defp extract_output(response, :string) do
    response.parts
    |> Enum.filter(fn
      {:text, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:text, text} -> text end)
    |> Enum.join("")
  end

  defp extract_output(response, output_type) do
    # Find tool call that matches output schema
    tool_call = Enum.find(response.parts, fn
      {:tool_call, call} -> call.name == "return_output"
      _ -> false
    end)

    case tool_call do
      {:tool_call, call} ->
        # Validate with Ecto
        changeset = output_type.changeset(call.arguments)

        if changeset.valid? do
          Ecto.Changeset.apply_changes(changeset)
        else
          {:error, changeset}
        end

      nil ->
        {:error, :no_output_found}
    end
  end
end
```

### Tool Implementation

```elixir
defmodule Yggdrasil.Tool do
  @moduledoc """
  Tool definition and management.
  """

  defstruct [
    :name,
    :description,
    :parameters,
    :function,
    retries: 1,
    requires_approval: false
  ]

  @doc "Create tool from function"
  def from_function(fun, opts \\ []) do
    {module, function_name, _arity} = Function.info(fun, :name)

    # Extract function metadata
    {:docs_v1, _, _, _, module_doc, _, docs} = Code.fetch_docs(module)

    doc_entry = Enum.find(docs, fn
      {{:function, ^function_name, _}, _, _, doc, _} when doc != :none -> true
      _ -> false
    end)

    {description, param_docs} = extract_doc_info(doc_entry)

    # Generate parameter schema from function spec
    params = generate_parameter_schema(module, function_name)

    %__MODULE__{
      name: Keyword.get(opts, :name, to_string(function_name)),
      description: Keyword.get(opts, :description, description),
      parameters: params,
      function: fun,
      retries: Keyword.get(opts, :retries, 1),
      requires_approval: Keyword.get(opts, :requires_approval, false)
    }
  end

  @doc "Convert tool to JSON schema"
  def to_schema(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "parameters" => tool.parameters
    }
  end

  defp extract_doc_info(nil), do: {"", %{}}

  defp extract_doc_info({{:function, _, _}, _, _, doc, metadata}) do
    # Parse docstring to extract description and parameter docs
    # This is simplified - real implementation would parse markdown
    {doc, %{}}
  end

  defp generate_parameter_schema(module, function_name) do
    # Use Module.__info__(:specs) to get function specs
    # Convert to JSON schema
    # This is a simplified version
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end
end
```

### Model Behaviour

```elixir
defmodule Yggdrasil.Models.Behaviour do
  @moduledoc """
  Behaviour for AI model implementations.
  """

  @callback model_name() :: String.t()
  @callback system() :: String.t()
  @callback request(messages :: list(), settings :: map()) ::
    {:ok, response :: map()} | {:error, term()}
  @callback request_stream(messages :: list(), settings :: map()) ::
    {:ok, stream :: Enumerable.t()} | {:error, term()}
  @callback count_tokens(messages :: list()) :: integer()
end
```

### OpenAI Implementation

```elixir
defmodule Yggdrasil.Models.OpenAI do
  @moduledoc """
  OpenAI model implementation.
  """

  @behaviour Yggdrasil.Models.Behaviour

  alias Yggdrasil.{Messages, Usage}

  @impl true
  def model_name, do: "gpt-4"

  @impl true
  def system, do: "openai"

  @impl true
  def request(messages, settings) do
    # Convert messages to OpenAI format
    openai_messages = convert_messages(messages)

    # Build request body
    body = %{
      "model" => settings[:model] || "gpt-4",
      "messages" => openai_messages,
      "temperature" => settings[:temperature],
      "max_tokens" => settings[:max_tokens]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()

    # Add tools if present
    body = if settings[:tools] do
      Map.put(body, "tools", settings[:tools])
    else
      body
    end

    # Make HTTP request
    case http_post("/chat/completions", body) do
      {:ok, %{status: 200, body: response_body}} ->
        response = parse_response(response_body)
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def request_stream(messages, settings) do
    # Similar to request but with stream: true
    # Return a Stream that yields events
    {:ok, Stream.resource(
      fn -> start_stream(messages, settings) end,
      fn conn -> next_event(conn) end,
      fn conn -> close_stream(conn) end
    )}
  end

  @impl true
  def count_tokens(messages) do
    # Use tiktoken_elixir or similar
    # Simplified for now
    messages
    |> Enum.map(&estimate_tokens/1)
    |> Enum.sum()
  end

  # Private functions

  defp http_post(path, body) do
    url = "https://api.openai.com/v1" <> path
    api_key = Application.get_env(:yggdrasil, :openai_api_key)

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    Req.post(url, json: body, headers: headers)
  end

  defp convert_messages(messages) do
    Enum.map(messages, fn msg ->
      case msg do
        {:system_prompt, text} ->
          %{"role" => "system", "content" => text}

        {:user_prompt, text} when is_binary(text) ->
          %{"role" => "user", "content" => text}

        {:tool_return, return_data} ->
          %{
            "role" => "tool",
            "tool_call_id" => return_data.call_id,
            "content" => Jason.encode!(return_data.result)
          }

        %{parts: parts} ->
          # Model response with tool calls
          content = extract_text(parts)
          tool_calls = extract_tool_calls(parts)

          msg = %{"role" => "assistant", "content" => content}

          if not Enum.empty?(tool_calls) do
            Map.put(msg, "tool_calls", tool_calls)
          else
            msg
          end
      end
    end)
  end

  defp parse_response(body) do
    choice = List.first(body["choices"])
    message = choice["message"]

    parts = []

    # Add text if present
    parts = if message["content"] do
      [{:text, message["content"]} | parts]
    else
      parts
    end

    # Add tool calls if present
    parts = if message["tool_calls"] do
      tool_parts = Enum.map(message["tool_calls"], fn tc ->
        {:tool_call, %{
          id: tc["id"],
          name: tc["function"]["name"],
          arguments: Jason.decode!(tc["function"]["arguments"])
        }}
      end)
      tool_parts ++ parts
    else
      parts
    end

    usage = %Usage{
      requests: 1,
      input_tokens: body["usage"]["prompt_tokens"],
      output_tokens: body["usage"]["completion_tokens"],
      total_tokens: body["usage"]["total_tokens"]
    }

    %{
      parts: Enum.reverse(parts),
      usage: usage,
      model_name: body["model"],
      timestamp: DateTime.utc_now()
    }
  end

  defp extract_text(parts) do
    parts
    |> Enum.filter(fn {:text, _} -> true; _ -> false end)
    |> Enum.map(fn {:text, t} -> t end)
    |> Enum.join("")
  end

  defp extract_tool_calls(parts) do
    parts
    |> Enum.filter(fn {:tool_call, _} -> true; _ -> false end)
    |> Enum.map(fn {:tool_call, call} ->
      %{
        "id" => call.id,
        "type" => "function",
        "function" => %{
          "name" => call.name,
          "arguments" => Jason.encode!(call.arguments)
        }
      }
    end)
  end

  defp estimate_tokens(message) do
    # Rough estimation: ~4 characters per token
    String.length(inspect(message)) |> div(4)
  end
end
```

---

## Elixir-Specific Advantages

### 1. Concurrent Agent Execution

```elixir
# Execute multiple agents concurrently
tasks = [
  Task.async(fn -> Agent.run(agent1, "Question 1") end),
  Task.async(fn -> Agent.run(agent2, "Question 2") end),
  Task.async(fn -> Agent.run(agent3, "Question 3") end)
]

results = Task.await_many(tasks, 30_000)
```

### 2. Fault Tolerance with Supervisors

```elixir
defmodule MyApp.AgentSupervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Yggdrasil.ModelPool, []},
      {Task.Supervisor, name: Yggdrasil.ToolSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### 3. Pattern Matching for Message Routing

```elixir
def handle_response(response) do
  case response.parts do
    [{:text, text}] ->
      {:text_only, text}

    [{:tool_call, call} | _] ->
      {:needs_tool_execution, call}

    [{:text, _}, {:tool_call, _} | _] = parts ->
      {:mixed_response, parts}

    _ ->
      {:unknown, response}
  end
end
```

### 4. Built-in Telemetry

```elixir
defmodule Yggdrasil.Telemetry do
  def emit_request_start(agent_name, model) do
    :telemetry.execute(
      [:yggdrasil, :request, :start],
      %{system_time: System.system_time()},
      %{agent: agent_name, model: model}
    )
  end

  def emit_request_stop(agent_name, duration, usage) do
    :telemetry.execute(
      [:yggdrasil, :request, :stop],
      %{duration: duration, tokens: usage.total_tokens},
      %{agent: agent_name}
    )
  end
end
```

### 5. Streaming with Elixir Streams

```elixir
{:ok, stream} = Agent.run_stream(agent, "Tell me a story")

stream
|> Stream.map(&process_event/1)
|> Stream.filter(&relevant?/1)
|> Stream.take(100)
|> Enum.to_list()
```

### 6. Distributed Agents

```elixir
# Run agent on remote node
:rpc.call(:"agent@node2", Agent, :run, [agent, prompt])

# Or use distributed registry
{:via, Registry, {AgentRegistry, agent_name}}
```

---

## API Design

### Basic Usage

```elixir
# Simple text agent
agent = Yggdrasil.Agent.new("openai:gpt-4",
  instructions: "Be helpful and concise"
)

{:ok, result} = Yggdrasil.Agent.run(agent, "What is 2+2?")
IO.puts(result.output) # "4"
```

### With Tools

```elixir
defmodule MyTools do
  @doc """
  Search the database for users.

  ## Parameters
  - query: Search query string
  """
  def search_users(ctx, query) do
    # ctx.deps has access to dependencies
    ctx.deps.database
    |> Database.search(query)
    |> format_results()
  end

  @doc """
  Get current weather for a location.
  """
  def get_weather(ctx, location) do
    WeatherAPI.fetch(location, ctx.deps.api_key)
  end
end

agent = Agent.new("anthropic:claude-3-5-sonnet-20241022",
  instructions: "Help users with their queries",
  tools: [&MyTools.search_users/2, &MyTools.get_weather/2]
)

deps = %{database: MyApp.Database, api_key: "..."}
{:ok, result} = Agent.run(agent, "Find users named John", deps: deps)
```

### Structured Outputs

```elixir
defmodule UserInfo do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    field :age, :integer
    field :occupation, :string
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:name, :age, :occupation])
    |> validate_required([:name])
    |> validate_number(:age, greater_than: 0)
  end
end

agent = Agent.new("openai:gpt-4",
  output_type: UserInfo
)

{:ok, result} = Agent.run(agent,
  "Extract: John Smith, 35 years old, software engineer"
)

result.output
# %UserInfo{name: "John Smith", age: 35, occupation: "software engineer"}
```

### Streaming

```elixir
{:ok, stream} = Agent.run_stream(agent, "Write a short poem")

stream
|> Stream.each(fn
  {:text_delta, text} ->
    IO.write(text)
  {:complete, result} ->
    IO.puts("\n\nDone! Used #{result.usage.total_tokens} tokens")
end)
|> Stream.run()
```

### Conversation History

```elixir
# First message
{:ok, result1} = Agent.run(agent, "Tell me a joke")

# Continue conversation
{:ok, result2} = Agent.run(agent, "Explain it",
  message_history: result1.new_messages
)

# Full history
{:ok, result3} = Agent.run(agent, "Tell another one",
  message_history: result2.all_messages
)
```

### Multi-Agent Systems

```elixir
# Define specialized agents
researcher = Agent.new("openai:gpt-4",
  instructions: "Research topics thoroughly",
  tools: [&search_web/2]
)

writer = Agent.new("anthropic:claude-3-5-sonnet-20241022",
  instructions: "Write clear, engaging content"
)

editor = Agent.new("openai:gpt-4",
  instructions: "Edit and improve text"
)

# Coordinate agents
defmodule ContentPipeline do
  def create_article(topic) do
    # Research phase
    {:ok, research} = Agent.run(researcher,
      "Research: #{topic}"
    )

    # Writing phase
    {:ok, draft} = Agent.run(writer,
      "Write article based on: #{research.output}"
    )

    # Editing phase
    {:ok, final} = Agent.run(editor,
      "Edit and improve: #{draft.output}"
    )

    final.output
  end
end
```

### Usage Limits

```elixir
limits = %Yggdrasil.UsageLimits{
  request_limit: 5,
  total_token_limit: 1000,
  tool_call_limit: 10
}

case Agent.run(agent, prompt, usage_limits: limits) do
  {:ok, result} ->
    {:ok, result}

  {:error, {:usage_limit_exceeded, reason}} ->
    Logger.warn("Usage limit exceeded: #{reason}")
    {:error, :rate_limited}
end
```

---

## Implementation Roadmap

### Phase 1: Core Foundation (Weeks 1-2)

**Goals:**
- Basic project structure
- Core types and structs
- Message representation
- Agent definition

**Deliverables:**
- [ ] Project skeleton with mix.exs
- [ ] `Yggdrasil.Agent` module
- [ ] `Yggdrasil.Messages` module
- [ ] `Yggdrasil.Usage` module
- [ ] `Yggdrasil.RunContext` module
- [ ] Basic documentation

### Phase 2: Model Integration (Weeks 3-4)

**Goals:**
- Model behaviour definition
- OpenAI implementation
- HTTP client wrapper
- Basic request/response handling

**Deliverables:**
- [ ] `Yggdrasil.Models.Behaviour`
- [ ] `Yggdrasil.Models.OpenAI`
- [ ] HTTP client with retries
- [ ] Token counting utilities
- [ ] Unit tests for OpenAI integration

### Phase 3: Agent Execution (Weeks 5-6)

**Goals:**
- AgentRunner GenServer
- Tool execution
- Message loop
- Output extraction

**Deliverables:**
- [ ] `Yggdrasil.AgentRunner`
- [ ] `Yggdrasil.ToolExecutor`
- [ ] Tool execution with retries
- [ ] Output validation with Ecto
- [ ] Integration tests

### Phase 4: Tools & Dependencies (Weeks 7-8)

**Goals:**
- Tool definition
- Tool schema generation
- Dependency injection
- Tool registration

**Deliverables:**
- [ ] `Yggdrasil.Tool` module
- [ ] JSON schema generation
- [ ] Function introspection
- [ ] Dependency system
- [ ] Tool testing framework

### Phase 5: Streaming (Weeks 9-10)

**Goals:**
- Streaming support
- Event-based streaming
- Stream coordination

**Deliverables:**
- [ ] `Yggdrasil.Stream` module
- [ ] Streaming in OpenAI model
- [ ] Event types and handling
- [ ] Backpressure management
- [ ] Streaming examples

### Phase 6: Additional Models (Weeks 11-12)

**Goals:**
- Anthropic implementation
- Google Gemini implementation
- Model abstraction testing

**Deliverables:**
- [ ] `Yggdrasil.Models.Anthropic`
- [ ] `Yggdrasil.Models.Google`
- [ ] Multi-model tests
- [ ] Model comparison benchmarks

### Phase 7: Advanced Features (Weeks 13-14)

**Goals:**
- Telemetry integration
- Error handling & retries
- Usage limits
- Validation

**Deliverables:**
- [ ] Telemetry events
- [ ] Custom exceptions
- [ ] Retry strategies
- [ ] Usage limit enforcement
- [ ] Output validators

### Phase 8: Polish & Documentation (Weeks 15-16)

**Goals:**
- Complete documentation
- Example applications
- Performance optimization
- Public release

**Deliverables:**
- [ ] HexDocs documentation
- [ ] Example projects
- [ ] Getting started guide
- [ ] API reference
- [ ] Hex.pm package
- [ ] GitHub repository

---

## Testing Strategy

### Unit Tests

```elixir
defmodule Yggdrasil.AgentTest do
  use ExUnit.Case, async: true

  alias Yggdrasil.Agent

  describe "new/2" do
    test "creates agent with default options" do
      agent = Agent.new("openai:gpt-4")

      assert agent.model == {Yggdrasil.Models.OpenAI, "gpt-4"}
      assert agent.output_type == :string
      assert agent.retries == 1
    end

    test "creates agent with custom options" do
      agent = Agent.new("openai:gpt-4",
        instructions: "Be helpful",
        retries: 3
      )

      assert agent.instructions == "Be helpful"
      assert agent.retries == 3
    end
  end
end
```

### Integration Tests

```elixir
defmodule Yggdrasil.Integration.OpenAITest do
  use ExUnit.Case

  alias Yggdrasil.{Agent, Models.OpenAI}

  @moduletag :integration

  setup do
    # Setup test agent
    agent = Agent.new("openai:gpt-4",
      instructions: "Be concise"
    )

    {:ok, agent: agent}
  end

  test "runs simple query", %{agent: agent} do
    {:ok, result} = Agent.run(agent, "What is 2+2?")

    assert result.output =~ "4"
    assert result.usage.total_tokens > 0
  end

  test "handles tool calls", %{agent: agent} do
    tool = fn _ctx, x -> x * 2 end
    agent = Agent.tool(agent, tool, name: "double")

    {:ok, result} = Agent.run(agent, "Use the double tool on 5")

    assert result.output =~ "10"
  end
end
```

### Property-Based Tests

```elixir
defmodule Yggdrasil.PropertyTest do
  use ExUnit.Case
  use PropCheck

  property "message serialization roundtrip" do
    forall messages <- list(message()) do
      serialized = Messages.to_json(messages)
      deserialized = Messages.from_json(serialized)

      messages == deserialized
    end
  end

  def message do
    oneof([
      {:system_prompt, utf8()},
      {:user_prompt, utf8()},
      {:text, utf8()}
    ])
  end
end
```

### Mock Testing

```elixir
defmodule Yggdrasil.MockModel do
  @behaviour Yggdrasil.Models.Behaviour

  def model_name, do: "mock"
  def system, do: "test"

  def request(_messages, _settings) do
    {:ok, %{
      parts: [{:text, "Mock response"}],
      usage: %Yggdrasil.Usage{
        requests: 1,
        total_tokens: 10
      },
      model_name: "mock",
      timestamp: DateTime.utc_now()
    }}
  end

  def request_stream(_messages, _settings) do
    {:ok, Stream.repeatedly(fn -> {:text_delta, "word"} end)}
  end

  def count_tokens(_messages), do: 10
end
```

---

## Dependencies

### Required Dependencies

```elixir
# mix.exs
defp deps do
  [
    # HTTP client
    {:req, "~> 0.4.0"},

    # JSON parsing
    {:jason, "~> 1.4"},

    # Schema validation
    {:ecto, "~> 3.11"},

    # Telemetry
    {:telemetry, "~> 1.2"},

    # Testing
    {:ex_unit, "~> 1.15", only: :test},
    {:mox, "~> 1.1", only: :test},
    {:propcheck, "~> 1.4", only: :test},

    # Documentation
    {:ex_doc, "~> 0.31", only: :dev, runtime: false},

    # Development
    {:dialyxir, "~> 1.4", only: :dev, runtime: false},
    {:credo, "~> 1.7", only: :dev, runtime: false}
  ]
end
```

### Optional Dependencies

```elixir
# Token counting (OpenAI)
{:tiktoken, "~> 0.4", optional: true}

# Distributed tracing
{:opentelemetry, "~> 1.3", optional: true},
{:opentelemetry_exporter, "~> 1.6", optional: true}

# Rate limiting
{:ex_rated, "~> 2.1", optional: true}

# Caching
{:cachex, "~> 3.6", optional: true}
```

---

## Configuration

### Application Config

```elixir
# config/config.exs
import Config

config :yggdrasil,
  # Model API keys
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  google_api_key: System.get_env("GOOGLE_API_KEY"),

  # Default settings
  default_model: "openai:gpt-4",
  default_timeout: 30_000,
  max_retries: 3,

  # HTTP client
  http_pool_size: 10,
  http_timeout: 60_000,

  # Telemetry
  enable_telemetry: true,

  # Logging
  log_level: :info

# Environment-specific config
import_config "#{config_env()}.exs"
```

---

## Example Application

```elixir
defmodule MyApp.ChatBot do
  @moduledoc """
  Example chatbot using Yggdrasil AI.
  """

  alias Yggdrasil.Agent

  defmodule Deps do
    defstruct [:database, :weather_api_key]
  end

  def new do
    Agent.new("openai:gpt-4",
      instructions: """
      You are a helpful assistant. You can:
      - Search our user database
      - Get current weather information
      - Answer general questions
      """,
      tools: [
        &search_users/2,
        &get_weather/2
      ],
      deps_type: Deps
    )
  end

  @doc """
  Search for users in the database.

  ## Parameters
  - query: User search query
  """
  def search_users(ctx, query) do
    ctx.deps.database
    |> MyApp.Database.search_users(query)
    |> format_user_results()
  end

  @doc """
  Get current weather for a location.

  ## Parameters
  - location: City name or coordinates
  """
  def get_weather(ctx, location) do
    MyApp.WeatherAPI.fetch(location, ctx.deps.weather_api_key)
  end

  def chat(agent, message, conversation_history \\ []) do
    deps = %Deps{
      database: MyApp.Database,
      weather_api_key: Application.get_env(:my_app, :weather_api_key)
    }

    case Agent.run(agent, message,
      deps: deps,
      message_history: conversation_history
    ) do
      {:ok, result} ->
        IO.puts("Assistant: #{result.output}")
        {:ok, result}

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def interactive_loop do
    agent = new()
    loop(agent, [])
  end

  defp loop(agent, history) do
    message = IO.gets("You: ") |> String.trim()

    case message do
      "exit" ->
        IO.puts("Goodbye!")

      "" ->
        loop(agent, history)

      _ ->
        case chat(agent, message, history) do
          {:ok, result} ->
            new_history = history ++ result.all_messages()
            loop(agent, new_history)

          {:error, _} ->
            loop(agent, history)
        end
    end
  end

  defp format_user_results(users) do
    users
    |> Enum.map(fn user ->
      "#{user.name} (#{user.email})"
    end)
    |> Enum.join("\n")
  end
end
```

---

## Differences from Python Implementation

### 1. Type System

**Python (Runtime):**
```python
def tool(ctx: RunContext[MyDeps], query: str) -> list[dict]:
    return ctx.deps.search(query)
```

**Elixir (Compile-time specs):**
```elixir
@spec tool(RunContext.t(MyDeps.t()), String.t()) :: list(map())
def tool(ctx, query) do
  ctx.deps.search(query)
end
```

### 2. Concurrency Model

**Python (asyncio):**
```python
result = await agent.run("prompt")
```

**Elixir (Processes):**
```elixir
# Blocking
{:ok, result} = Agent.run(agent, "prompt")

# Or async with Task
task = Task.async(fn -> Agent.run(agent, "prompt") end)
result = Task.await(task)
```

### 3. Error Handling

**Python (Exceptions):**
```python
try:
    result = agent.run_sync("prompt")
except UsageLimitExceeded as e:
    handle_error(e)
```

**Elixir (Tagged tuples):**
```elixir
case Agent.run(agent, "prompt") do
  {:ok, result} -> handle_success(result)
  {:error, {:usage_limit_exceeded, reason}} -> handle_error(reason)
end
```

### 4. Dependency Injection

**Python (Dataclasses):**
```python
@dataclass
class MyDeps:
    api_key: str
    database: Database
```

**Elixir (Structs):**
```elixir
defmodule MyDeps do
  @type t :: %__MODULE__{
    api_key: String.t(),
    database: module()
  }

  defstruct [:api_key, :database]
end
```

### 5. Validation

**Python (Pydantic):**
```python
class UserProfile(BaseModel):
    name: str
    age: int

    @validator('age')
    def validate_age(cls, v):
        if v < 0:
            raise ValueError('Age must be positive')
        return v
```

**Elixir (Ecto):**
```elixir
defmodule UserProfile do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string
    field :age, :integer
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:name, :age])
    |> validate_number(:age, greater_than: 0)
  end
end
```

---

## Next Steps

1. **Create Initial Project Structure**
   ```bash
   mix new exadantic --sup
   cd exadantic
   ```

2. **Define Core Modules**
   - Start with `Yggdrasil.Agent`
   - Add `Yggdrasil.Messages`
   - Implement `Yggdrasil.Usage`

3. **Implement First Model Provider**
   - Focus on OpenAI as it's most popular
   - Create `Yggdrasil.Models.OpenAI`
   - Test with real API calls

4. **Build Agent Execution**
   - Implement `Yggdrasil.AgentRunner` GenServer
   - Add tool execution
   - Handle message loops

5. **Add Testing**
   - Unit tests for each module
   - Integration tests with real APIs
   - Mock model for fast testing

6. **Documentation**
   - ExDoc setup
   - Module documentation
   - Examples and guides

7. **Polish & Release**
   - Performance optimization
   - Error handling
   - Hex.pm package release

---

## Conclusion

**Yggdrasil AI** will bring the power of Pydantic AI's agent framework to the Elixir ecosystem, leveraging Elixir's strengths in concurrency, fault tolerance, and distributed systems. The library will provide:

- ✅ Type-safe AI agent development
- ✅ Model-agnostic abstraction
- ✅ Tool integration for function calling
- ✅ Structured output validation
- ✅ Streaming support
- ✅ Built-in observability
- ✅ Fault-tolerant execution
- ✅ Concurrent agent coordination

This port will enable Elixir developers to build production-grade AI applications with confidence, bringing modern LLM capabilities to the BEAM ecosystem.
