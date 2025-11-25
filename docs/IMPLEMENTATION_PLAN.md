# Yggdrasil AI - Detailed Implementation Plan

## Overview

This document provides a detailed, step-by-step implementation plan for building Yggdrasil AI, an Elixir port of Pydantic AI. Each phase includes specific tasks, code examples, and testing requirements.

---

## Phase 1: Project Setup & Core Types (Week 1)

### Tasks

#### 1.1 Initialize Mix Project

```bash
mix new exadantic --sup
cd exadantic
```

#### 1.2 Configure mix.exs

```elixir
defmodule Yggdrasil.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/yourusername/exadantic"

  def project do
    [
      app: :yggdrasil,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: "Type-safe AI agent framework for Elixir",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Yggdrasil.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP client
      {:req, "~> 0.5.0"},
      # JSON
      {:jason, "~> 1.4"},
      # Validation
      {:ecto, "~> 3.11"},
      # Telemetry
      {:telemetry, "~> 1.2"},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "DESIGN_DOCUMENT.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
```

#### 1.3 Create Application Supervisor

```elixir
# lib/exadantic/application.ex
defmodule Yggdrasil.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # HTTP connection pool
      {Finch, name: Yggdrasil.Finch},
      # Telemetry supervisor
      Yggdrasil.Telemetry
    ]

    opts = [strategy: :one_for_one, name: Yggdrasil.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

#### 1.4 Define Core Types

```elixir
# lib/exadantic/types.ex
defmodule Yggdrasil.Types do
  @moduledoc """
  Core type definitions for Yggdrasil AI.
  """

  @typedoc "Model identifier - either a string like 'openai:gpt-4' or a module"
  @type model :: String.t() | {module(), String.t()} | module()

  @typedoc "Output type specification"
  @type output_type :: :string | module()

  @typedoc "Message content - can be text or multi-modal"
  @type content ::
          String.t()
          | {:text, String.t()}
          | {:image_url, String.t()}
          | {:audio_url, String.t()}
          | {:document_url, String.t()}

  @typedoc "System prompt part"
  @type system_prompt_part :: {:system_prompt, String.t()}

  @typedoc "User prompt part"
  @type user_prompt_part :: {:user_prompt, String.t() | [content()]}

  @typedoc "Tool return part"
  @type tool_return_part :: {:tool_return, tool_return()}

  @typedoc "Text response part"
  @type text_part :: {:text, String.t()}

  @typedoc "Tool call part"
  @type tool_call_part :: {:tool_call, tool_call()}

  @typedoc "Thinking/reasoning part"
  @type thinking_part :: {:thinking, String.t()}

  @typedoc "Message parts that can appear in requests"
  @type request_part :: system_prompt_part() | user_prompt_part() | tool_return_part()

  @typedoc "Message parts that can appear in responses"
  @type response_part :: text_part() | tool_call_part() | thinking_part()

  @typedoc "Tool call information"
  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @typedoc "Tool return information"
  @type tool_return :: %{
          call_id: String.t(),
          result: any()
        }

  @typedoc "Model request message"
  @type model_request :: %{
          parts: [request_part()],
          timestamp: DateTime.t()
        }

  @typedoc "Model response message"
  @type model_response :: %{
          parts: [response_part()],
          usage: Yggdrasil.Usage.t(),
          model_name: String.t(),
          timestamp: DateTime.t()
        }

  @typedoc "Any message type"
  @type message :: model_request() | model_response()
end
```

#### 1.5 Implement Usage Tracking

```elixir
# lib/exadantic/usage.ex
defmodule Yggdrasil.Usage do
  @moduledoc """
  Tracks resource usage for agent runs.
  """

  @type t :: %__MODULE__{
          requests: non_neg_integer(),
          tool_calls: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer()
        }

  defstruct requests: 0,
            tool_calls: 0,
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0

  @doc "Create a new empty usage tracker"
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Add two usage trackers together"
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = u1, %__MODULE__{} = u2) do
    %__MODULE__{
      requests: u1.requests + u2.requests,
      tool_calls: u1.tool_calls + u2.tool_calls,
      input_tokens: u1.input_tokens + u2.input_tokens,
      output_tokens: u1.output_tokens + u2.output_tokens,
      total_tokens: u1.total_tokens + u2.total_tokens,
      cache_read_tokens: u1.cache_read_tokens + u2.cache_read_tokens,
      cache_write_tokens: u1.cache_write_tokens + u2.cache_write_tokens
    }
  end

  @doc "Increment request count"
  @spec inc_requests(t()) :: t()
  def inc_requests(%__MODULE__{} = usage) do
    %{usage | requests: usage.requests + 1}
  end

  @doc "Increment tool call count"
  @spec inc_tool_calls(t(), non_neg_integer()) :: t()
  def inc_tool_calls(%__MODULE__{} = usage, count \\ 1) do
    %{usage | tool_calls: usage.tool_calls + count}
  end

  @doc "Add token counts"
  @spec add_tokens(t(), keyword()) :: t()
  def add_tokens(%__MODULE__{} = usage, opts) do
    input = Keyword.get(opts, :input, 0)
    output = Keyword.get(opts, :output, 0)
    cache_read = Keyword.get(opts, :cache_read, 0)
    cache_write = Keyword.get(opts, :cache_write, 0)

    %{
      usage
      | input_tokens: usage.input_tokens + input,
        output_tokens: usage.output_tokens + output,
        total_tokens: usage.total_tokens + input + output,
        cache_read_tokens: usage.cache_read_tokens + cache_read,
        cache_write_tokens: usage.cache_write_tokens + cache_write
    }
  end
end
```

#### 1.6 Implement Usage Limits

```elixir
# lib/exadantic/usage_limits.ex
defmodule Yggdrasil.UsageLimits do
  @moduledoc """
  Defines usage limits for agent runs.
  """

  alias Yggdrasil.Usage

  @type t :: %__MODULE__{
          request_limit: pos_integer() | nil,
          tool_call_limit: pos_integer() | nil,
          input_token_limit: pos_integer() | nil,
          output_token_limit: pos_integer() | nil,
          total_token_limit: pos_integer() | nil
        }

  defstruct [
    :request_limit,
    :tool_call_limit,
    :input_token_limit,
    :output_token_limit,
    :total_token_limit
  ]

  @doc "Check if usage exceeds limits"
  @spec check(Usage.t(), t()) :: :ok | {:error, atom()}
  def check(%Usage{} = usage, %__MODULE__{} = limits) do
    cond do
      !is_nil(limits.request_limit) and usage.requests >= limits.request_limit ->
        {:error, :request_limit_exceeded}

      !is_nil(limits.tool_call_limit) and usage.tool_calls >= limits.tool_call_limit ->
        {:error, :tool_call_limit_exceeded}

      !is_nil(limits.input_token_limit) and usage.input_tokens >= limits.input_token_limit ->
        {:error, :input_token_limit_exceeded}

      !is_nil(limits.output_token_limit) and usage.output_tokens >= limits.output_token_limit ->
        {:error, :output_token_limit_exceeded}

      !is_nil(limits.total_token_limit) and usage.total_tokens >= limits.total_token_limit ->
        {:error, :total_token_limit_exceeded}

      true ->
        :ok
    end
  end
end
```

#### 1.7 Implement RunContext

```elixir
# lib/exadantic/run_context.ex
defmodule Yggdrasil.RunContext do
  @moduledoc """
  Context passed to tools and dynamic prompts.
  Provides access to dependencies, retry information, and usage data.
  """

  alias Yggdrasil.Usage

  @type t(deps) :: %__MODULE__{
          deps: deps,
          retry: non_neg_integer(),
          usage: Usage.t()
        }

  @type t :: t(any())

  defstruct [:deps, retry: 0, usage: %Usage{}]

  @doc "Create a new run context"
  @spec new(deps :: any(), opts :: keyword()) :: t(any())
  def new(deps, opts \\ []) do
    %__MODULE__{
      deps: deps,
      retry: Keyword.get(opts, :retry, 0),
      usage: Keyword.get(opts, :usage, Usage.new())
    }
  end
end
```

### Testing (Week 1)

```elixir
# test/exadantic/usage_test.exs
defmodule Yggdrasil.UsageTest do
  use ExUnit.Case, async: true

  alias Yggdrasil.Usage

  describe "new/0" do
    test "creates empty usage tracker" do
      usage = Usage.new()

      assert usage.requests == 0
      assert usage.total_tokens == 0
    end
  end

  describe "add/2" do
    test "adds two usage trackers" do
      u1 = %Usage{requests: 1, total_tokens: 100}
      u2 = %Usage{requests: 2, total_tokens: 200}

      result = Usage.add(u1, u2)

      assert result.requests == 3
      assert result.total_tokens == 300
    end
  end

  describe "add_tokens/2" do
    test "adds token counts" do
      usage = Usage.new()

      result = Usage.add_tokens(usage, input: 50, output: 30)

      assert result.input_tokens == 50
      assert result.output_tokens == 30
      assert result.total_tokens == 80
    end
  end
end
```

---

## Phase 2: Messages & Agent Definition (Week 2)

### Tasks

#### 2.1 Implement Messages Module

```elixir
# lib/exadantic/messages.ex
defmodule Yggdrasil.Messages do
  @moduledoc """
  Message construction and manipulation.
  """

  alias Yggdrasil.Types

  @doc "Create a system prompt message part"
  @spec system_prompt(String.t()) :: Types.system_prompt_part()
  def system_prompt(text) when is_binary(text) do
    {:system_prompt, text}
  end

  @doc "Create a user prompt message part"
  @spec user_prompt(String.t() | [Types.content()]) :: Types.user_prompt_part()
  def user_prompt(content) do
    {:user_prompt, content}
  end

  @doc "Create a tool return message part"
  @spec tool_return(String.t(), any()) :: Types.tool_return_part()
  def tool_return(call_id, result) do
    {:tool_return, %{call_id: call_id, result: result}}
  end

  @doc "Create a model request"
  @spec model_request([Types.request_part()]) :: Types.model_request()
  def model_request(parts) do
    %{
      parts: parts,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Create a model response"
  @spec model_response([Types.response_part()], keyword()) :: Types.model_response()
  def model_response(parts, opts \\ []) do
    %{
      parts: parts,
      usage: Keyword.get(opts, :usage, Yggdrasil.Usage.new()),
      model_name: Keyword.fetch!(opts, :model_name),
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Extract text from response parts"
  @spec extract_text([Types.response_part()]) :: String.t()
  def extract_text(parts) do
    parts
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map(fn {:text, text} -> text end)
    |> Enum.join("")
  end

  @doc "Extract tool calls from response parts"
  @spec extract_tool_calls([Types.response_part()]) :: [Types.tool_call()]
  def extract_tool_calls(parts) do
    parts
    |> Enum.filter(&match?({:tool_call, _}, &1))
    |> Enum.map(fn {:tool_call, call} -> call end)
  end

  @doc "Serialize messages to JSON"
  @spec to_json([Types.message()]) :: {:ok, String.t()} | {:error, term()}
  def to_json(messages) do
    Jason.encode(messages)
  end

  @doc "Deserialize messages from JSON"
  @spec from_json(String.t()) :: {:ok, [Types.message()]} | {:error, term()}
  def from_json(json) do
    with {:ok, data} <- Jason.decode(json) do
      # Convert string keys back to atoms and reconstruct tuples
      messages = Enum.map(data, &reconstruct_message/1)
      {:ok, messages}
    end
  end

  defp reconstruct_message(%{"parts" => parts, "timestamp" => ts} = msg) do
    reconstructed_parts = Enum.map(parts, &reconstruct_part/1)

    base = %{
      parts: reconstructed_parts,
      timestamp: DateTime.from_iso8601(ts) |> elem(1)
    }

    # Check if this is a response (has usage)
    if Map.has_key?(msg, "usage") do
      Map.merge(base, %{
        usage: struct(Yggdrasil.Usage, string_keys_to_atoms(msg["usage"])),
        model_name: msg["model_name"]
      })
    else
      base
    end
  end

  defp reconstruct_part([type, data]) when is_binary(type) do
    {String.to_existing_atom(type), data}
  end

  defp reconstruct_part([type, data]) when is_map(data) do
    {String.to_existing_atom(type), string_keys_to_atoms(data)}
  end

  defp string_keys_to_atoms(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end
end
```

#### 2.2 Implement Agent Module

```elixir
# lib/exadantic/agent.ex
defmodule Yggdrasil.Agent do
  @moduledoc """
  Primary interface for AI agents.

  An Agent is a stateless configuration object that defines:
  - Which model to use
  - Instructions for the model
  - Available tools
  - Output validation schema
  - Dependency types

  ## Example

      agent = Agent.new("openai:gpt-4",
        instructions: "Be helpful and concise",
        tools: [&MyTools.search/2]
      )

      {:ok, result} = Agent.run(agent, "What is 2+2?")
      IO.puts(result.output) # "4"
  """

  alias Yggdrasil.{AgentRunner, Tool, Types}

  @type t :: %__MODULE__{
          model: Types.model(),
          output_type: Types.output_type(),
          instructions: String.t() | function() | nil,
          system_prompt: String.t() | function() | nil,
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
    model_settings: %{},
    retries: 1,
    tools: [],
    end_strategy: :early
  ]

  @doc """
  Create a new agent.

  ## Options

  - `:output_type` - Expected output type (default: `:string`)
  - `:instructions` - Static instructions or function returning instructions
  - `:system_prompt` - Static system prompt or function
  - `:deps_type` - Module defining dependency structure
  - `:name` - Agent name for logging
  - `:model_settings` - Model-specific settings (temperature, max_tokens, etc.)
  - `:retries` - Default retry count for tools and validation
  - `:tools` - List of tool functions or Tool structs
  - `:end_strategy` - How to handle tool calls (`:early` or `:exhaustive`)

  ## Examples

      # Simple text agent
      agent = Agent.new("openai:gpt-4")

      # Agent with custom settings
      agent = Agent.new("anthropic:claude-3-5-sonnet-20241022",
        instructions: "Be concise",
        model_settings: %{temperature: 0.7, max_tokens: 1000}
      )

      # Agent with tools
      agent = Agent.new("openai:gpt-4",
        tools: [&MyTools.search/2, &MyTools.calculate/2]
      )
  """
  @spec new(Types.model(), keyword()) :: t()
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
      tools: parse_tools(Keyword.get(opts, :tools, [])),
      end_strategy: Keyword.get(opts, :end_strategy, :early)
    }
  end

  @doc """
  Run agent synchronously.

  ## Options

  - `:deps` - Dependencies to pass to tools and prompts
  - `:message_history` - Previous messages to continue conversation
  - `:usage_limits` - Usage limits for this run
  - `:model_settings` - Override model settings for this run

  ## Examples

      {:ok, result} = Agent.run(agent, "What is the capital of France?")
      IO.puts(result.output) # "Paris"

      # With dependencies
      {:ok, result} = Agent.run(agent, "Search for users",
        deps: %{database: MyApp.DB}
      )

      # Continue conversation
      {:ok, result2} = Agent.run(agent, "Tell me more",
        message_history: result1.new_messages
      )
  """
  @spec run(t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = agent, prompt, opts \\ []) do
    AgentRunner.run(agent, prompt, opts)
  end

  @doc """
  Run agent with streaming.

  Returns a stream that yields events as they occur.

  ## Events

  - `{:text_delta, text}` - Incremental text update
  - `{:tool_call, call}` - Tool is being called
  - `{:tool_result, result}` - Tool execution completed
  - `{:complete, result}` - Final result

  ## Example

      {:ok, stream} = Agent.run_stream(agent, "Tell me a story")

      stream
      |> Stream.each(fn
        {:text_delta, text} -> IO.write(text)
        {:complete, result} -> IO.puts("\\nDone!")
      end)
      |> Stream.run()
  """
  @spec run_stream(t(), String.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def run_stream(%__MODULE__{} = agent, prompt, opts \\ []) do
    AgentRunner.run_stream(agent, prompt, opts)
  end

  @doc """
  Register a tool with the agent.

  Returns a new agent with the tool added.

  ## Options

  - `:name` - Custom tool name (default: function name)
  - `:description` - Custom description
  - `:retries` - Retry count for this tool
  - `:requires_approval` - Whether tool needs human approval

  ## Example

      agent = Agent.new("openai:gpt-4")
      agent = Agent.tool(agent, &MyTools.search/2,
        description: "Search the database"
      )
  """
  @spec tool(t(), function(), keyword()) :: t()
  def tool(%__MODULE__{} = agent, tool_fun, opts \\ []) do
    tool = Tool.from_function(tool_fun, opts)
    %{agent | tools: [tool | agent.tools]}
  end

  # Private functions

  @spec parse_model(Types.model()) :: Types.model()
  defp parse_model("openai:" <> model_name) do
    {Yggdrasil.Models.OpenAI, model_name}
  end

  defp parse_model("anthropic:" <> model_name) do
    {Yggdrasil.Models.Anthropic, model_name}
  end

  defp parse_model("google:" <> model_name) do
    {Yggdrasil.Models.Google, model_name}
  end

  defp parse_model("groq:" <> model_name) do
    {Yggdrasil.Models.Groq, model_name}
  end

  defp parse_model(model) when is_atom(model) or is_tuple(model) do
    model
  end

  @spec parse_tools([function() | Tool.t()]) :: [Tool.t()]
  defp parse_tools(tools) do
    Enum.map(tools, fn
      %Tool{} = tool -> tool
      fun when is_function(fun) -> Tool.from_function(fun)
    end)
  end

  @spec generate_name() :: String.t()
  defp generate_name do
    "agent_#{:erlang.unique_integer([:positive])}"
  end
end
```

### Testing (Week 2)

```elixir
# test/exadantic/agent_test.exs
defmodule Yggdrasil.AgentTest do
  use ExUnit.Case, async: true

  alias Yggdrasil.Agent

  describe "new/2" do
    test "creates agent with default options" do
      agent = Agent.new("openai:gpt-4")

      assert {Yggdrasil.Models.OpenAI, "gpt-4"} = agent.model
      assert agent.output_type == :string
      assert agent.retries == 1
      assert agent.tools == []
    end

    test "creates agent with custom options" do
      agent =
        Agent.new("anthropic:claude-3-5-sonnet-20241022",
          instructions: "Be helpful",
          retries: 3,
          model_settings: %{temperature: 0.5}
        )

      assert agent.instructions == "Be helpful"
      assert agent.retries == 3
      assert agent.model_settings == %{temperature: 0.5}
    end

    test "parses different model formats" do
      agent1 = Agent.new("openai:gpt-4")
      assert {Yggdrasil.Models.OpenAI, "gpt-4"} = agent1.model

      agent2 = Agent.new("anthropic:claude-3-5-sonnet-20241022")
      assert {Yggdrasil.Models.Anthropic, _} = agent2.model

      agent3 = Agent.new("google:gemini-pro")
      assert {Yggdrasil.Models.Google, "gemini-pro"} = agent3.model
    end
  end

  describe "tool/3" do
    test "adds tool to agent" do
      agent = Agent.new("openai:gpt-4")

      tool_fun = fn _ctx, x -> x * 2 end
      agent = Agent.tool(agent, tool_fun, name: "double")

      assert length(agent.tools) == 1
      assert hd(agent.tools).name == "double"
    end

    test "can add multiple tools" do
      agent = Agent.new("openai:gpt-4")

      agent =
        agent
        |> Agent.tool(fn _ctx, x -> x * 2 end, name: "double")
        |> Agent.tool(fn _ctx, x -> x + 10 end, name: "add_ten")

      assert length(agent.tools) == 2
    end
  end
end
```

---

## Phase 3: Model Behaviour & OpenAI Implementation (Weeks 3-4)

### Tasks

#### 3.1 Define Model Behaviour

```elixir
# lib/exadantic/models/behaviour.ex
defmodule Yggdrasil.Models.Behaviour do
  @moduledoc """
  Behaviour for AI model implementations.

  All model providers must implement this behaviour to be compatible
  with Yggdrasil agents.
  """

  alias Yggdrasil.Types

  @doc "Get the model name"
  @callback model_name() :: String.t()

  @doc "Get the provider/system name"
  @callback system() :: String.t()

  @doc "Make a request to the model"
  @callback request([Types.message()], map()) ::
              {:ok, Types.model_response()} | {:error, term()}

  @doc "Make a streaming request to the model"
  @callback request_stream([Types.message()], map()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc "Count tokens in messages (optional, can return estimate)"
  @callback count_tokens([Types.message()]) :: integer()

  @optional_callbacks count_tokens: 1
end
```

#### 3.2 Implement Model Settings

```elixir
# lib/exadantic/models/settings.ex
defmodule Yggdrasil.Models.Settings do
  @moduledoc """
  Model configuration settings.
  """

  @type t :: %{
          optional(:temperature) => float(),
          optional(:max_tokens) => pos_integer(),
          optional(:top_p) => float(),
          optional(:frequency_penalty) => float(),
          optional(:presence_penalty) => float(),
          optional(:stop_sequences) => [String.t()],
          optional(:seed) => integer(),
          optional(atom()) => any()
        }

  @doc "Merge settings with defaults"
  @spec merge(t(), t()) :: t()
  def merge(settings, defaults) do
    Map.merge(defaults, settings)
  end

  @doc "Validate settings"
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(settings) do
    cond do
      Map.has_key?(settings, :temperature) and
          (settings.temperature < 0 or settings.temperature > 2) ->
        {:error, "temperature must be between 0 and 2"}

      Map.has_key?(settings, :top_p) and
          (settings.top_p < 0 or settings.top_p > 1) ->
        {:error, "top_p must be between 0 and 1"}

      Map.has_key?(settings, :max_tokens) and settings.max_tokens < 1 ->
        {:error, "max_tokens must be positive"}

      true ->
        :ok
    end
  end
end
```

#### 3.3 Implement OpenAI Model

This is a large file - see the main DESIGN_DOCUMENT.md for the full implementation. Key points:

- HTTP client using `Req`
- Message format conversion
- Tool call handling
- Streaming support
- Error handling

```elixir
# lib/exadantic/models/openai.ex
defmodule Yggdrasil.Models.OpenAI do
  @moduledoc """
  OpenAI model implementation.

  Supports:
  - GPT-4, GPT-4 Turbo, GPT-3.5 Turbo
  - Function/tool calling
  - Streaming
  - Vision (multimodal inputs)
  """

  @behaviour Yggdrasil.Models.Behaviour

  alias Yggdrasil.{Messages, Usage, Types}

  @base_url "https://api.openai.com/v1"

  @impl true
  def model_name, do: "gpt-4"

  @impl true
  def system, do: "openai"

  @impl true
  def request(messages, settings) do
    # Implementation details in DESIGN_DOCUMENT.md
    # Key steps:
    # 1. Convert messages to OpenAI format
    # 2. Build request body with settings
    # 3. Make HTTP request
    # 4. Parse response
    # 5. Return structured response
  end

  @impl true
  def request_stream(messages, settings) do
    # Similar to request but with stream: true
    # Return Stream that yields events
  end

  @impl true
  def count_tokens(messages) do
    # Use tiktoken_elixir if available
    # Otherwise provide estimate
    estimate_tokens(messages)
  end

  # Private helper functions...
end
```

### Testing (Weeks 3-4)

```elixir
# test/exadantic/models/openai_test.exs
defmodule Yggdrasil.Models.OpenAITest do
  use ExUnit.Case

  alias Yggdrasil.{Messages, Models.OpenAI}

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    # Skip if no API key
    api_key = System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) do
      {:ok, skip: true}
    else
      {:ok, api_key: api_key}
    end
  end

  describe "request/2" do
    @tag :skip
    test "makes simple request", %{skip: skip} do
      unless skip do
        messages = [
          Messages.user_prompt("What is 2+2? Answer with just the number.")
        ]

        {:ok, response} = OpenAI.request(messages, %{model: "gpt-4"})

        assert is_map(response)
        assert response.model_name =~ "gpt"
        assert Messages.extract_text(response.parts) =~ "4"
      end
    end
  end
end
```

---

## Phase 4: Agent Execution Engine (Weeks 5-6)

### Tasks

#### 4.1 Implement ToolExecutor

```elixir
# lib/exadantic/tool_executor.ex
defmodule Yggdrasil.ToolExecutor do
  @moduledoc """
  Executes tool functions with retry logic and error handling.
  """

  alias Yggdrasil.{Tool, RunContext}

  require Logger

  @doc "Execute a tool with the given arguments"
  @spec execute(Tool.t(), map(), RunContext.t()) :: {:ok, any()} | {:error, term()}
  def execute(%Tool{} = tool, arguments, %RunContext{} = ctx) do
    do_execute(tool, arguments, ctx, 0)
  end

  defp do_execute(tool, arguments, ctx, attempt) do
    try do
      # Call the tool function
      result =
        if tool.takes_ctx do
          tool.function.(ctx, arguments)
        else
          tool.function.(arguments)
        end

      {:ok, result}
    rescue
      error ->
        if attempt < tool.retries do
          Logger.warning("Tool #{tool.name} failed (attempt #{attempt + 1}), retrying...")
          do_execute(tool, arguments, %{ctx | retry: attempt + 1}, attempt + 1)
        else
          Logger.error("Tool #{tool.name} failed after #{attempt + 1} attempts")
          {:error, error}
        end
    end
  end
end
```

#### 4.2 Implement Tool Module

Implementation in DESIGN_DOCUMENT.md includes:
- Tool struct definition
- `from_function/2` to create tools from functions
- `to_schema/1` for JSON schema generation
- Parameter extraction from function specs
- Docstring parsing

#### 4.3 Implement AgentRunner

This is the core execution engine. See DESIGN_DOCUMENT.md for full implementation.

Key responsibilities:
- Manage agent execution loop
- Call model with messages
- Execute tools when requested
- Handle retries and errors
- Track usage
- Support streaming

---

## Phase 5: Structured Outputs & Validation (Week 7)

### Tasks

#### 5.1 Implement Output Module

```elixir
# lib/exadantic/output.ex
defmodule Yggdrasil.Output do
  @moduledoc """
  Output extraction and validation.
  """

  alias Yggdrasil.{Types, Messages}

  @doc "Extract output from response based on output type"
  @spec extract(Types.model_response(), Types.output_type()) ::
          {:ok, any()} | {:error, term()}
  def extract(response, :string) do
    text = Messages.extract_text(response.parts)
    {:ok, text}
  end

  def extract(response, output_module) when is_atom(output_module) do
    # Look for tool call with output schema
    tool_calls = Messages.extract_tool_calls(response.parts)

    output_call =
      Enum.find(tool_calls, fn call ->
        call.name == "return_output" or call.name == output_module_name(output_module)
      end)

    case output_call do
      nil ->
        {:error, :no_structured_output_found}

      call ->
        validate_with_ecto(call.arguments, output_module)
    end
  end

  @doc "Validate data with Ecto schema"
  @spec validate_with_ecto(map(), module()) :: {:ok, struct()} | {:error, term()}
  def validate_with_ecto(data, module) do
    changeset = module.changeset(data)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, {:validation_failed, changeset.errors}}
    end
  end

  @doc "Generate JSON schema for output type"
  @spec generate_schema(module()) :: map()
  def generate_schema(module) do
    # Use module.__schema__/1 from Ecto to generate JSON schema
    # This is simplified - full implementation would handle all Ecto types
    fields = module.__schema__(:fields)

    properties =
      Map.new(fields, fn field ->
        type = module.__schema__(:type, field)
        {field, ecto_type_to_json_schema(type)}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => []
    }
  end

  defp ecto_type_to_json_schema(:string), do: %{"type" => "string"}
  defp ecto_type_to_json_schema(:integer), do: %{"type" => "integer"}
  defp ecto_type_to_json_schema(:float), do: %{"type" => "number"}
  defp ecto_type_to_json_schema(:boolean), do: %{"type" => "boolean"}
  defp ecto_type_to_json_schema(_), do: %{"type" => "string"}

  defp output_module_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end
```

---

## Phase 6: Streaming (Week 8)

### Tasks

#### 6.1 Implement Stream Module

```elixir
# lib/exadantic/stream.ex
defmodule Yggdrasil.Stream do
  @moduledoc """
  Streaming utilities and event types.
  """

  @type event ::
          {:text_delta, String.t()}
          | {:tool_call, map()}
          | {:tool_result, any()}
          | {:thinking, String.t()}
          | {:complete, map()}
          | {:error, term()}

  @doc "Create a stream from model response stream"
  @spec from_model_stream(Enumerable.t(), map()) :: Enumerable.t()
  def from_model_stream(model_stream, state) do
    Stream.transform(model_stream, state, &process_model_event/2)
  end

  defp process_model_event(event, state) do
    case event do
      {:text_delta, text} ->
        {[{:text_delta, text}], state}

      {:tool_call_start, call} ->
        new_state = Map.update(state, :pending_calls, [call], &[call | &1])
        {[{:tool_call, call}], new_state}

      {:tool_call_complete, call} ->
        # Execute tool
        # Return result event
        {[{:tool_result, "result"}], state}

      {:complete, response} ->
        {[{:complete, response}], state}

      _ ->
        {[], state}
    end
  end
end
```

---

## Phase 7: Testing Infrastructure (Week 9)

### Tasks

#### 7.1 Create TestModel

```elixir
# lib/exadantic/testing/test_model.ex
defmodule Yggdrasil.Testing.TestModel do
  @moduledoc """
  Test model that returns predefined responses without calling real APIs.
  """

  @behaviour Yggdrasil.Models.Behaviour

  @impl true
  def model_name, do: "test-model"

  @impl true
  def system, do: "test"

  @impl true
  def request(messages, settings) do
    # Generate fake response based on settings
    response_text = Map.get(settings, :response, "Test response")

    response = %{
      parts: [{:text, response_text}],
      usage: %Yggdrasil.Usage{
        requests: 1,
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15
      },
      model_name: "test-model",
      timestamp: DateTime.utc_now()
    }

    {:ok, response}
  end

  @impl true
  def request_stream(_messages, settings) do
    response_text = Map.get(settings, :response, "Test response")
    chunks = String.split(response_text, " ")

    stream =
      Stream.concat(
        Stream.map(chunks, fn chunk -> {:text_delta, chunk <> " "} end),
        [{:complete, %{output: response_text}}]
      )

    {:ok, stream}
  end

  @impl true
  def count_tokens(_messages), do: 10
end
```

---

## Phase 8: Additional Model Providers (Weeks 10-11)

Implement:
- `Yggdrasil.Models.Anthropic` (Claude)
- `Yggdrasil.Models.Google` (Gemini)
- `Yggdrasil.Models.Groq`

Each follows the same pattern as OpenAI but with provider-specific:
- API endpoints
- Message formats
- Tool calling conventions
- Streaming formats

---

## Phase 9: Telemetry & Observability (Week 12)

### Tasks

#### 9.1 Implement Telemetry

```elixir
# lib/exadantic/telemetry.ex
defmodule Yggdrasil.Telemetry do
  @moduledoc """
  Telemetry events for observability.
  """

  @doc "Emit agent run start event"
  def agent_run_start(agent_name, model) do
    :telemetry.execute(
      [:yggdrasil, :agent, :run, :start],
      %{system_time: System.system_time()},
      %{agent: agent_name, model: inspect(model)}
    )
  end

  @doc "Emit agent run stop event"
  def agent_run_stop(agent_name, duration, usage) do
    :telemetry.execute(
      [:yggdrasil, :agent, :run, :stop],
      %{
        duration: duration,
        requests: usage.requests,
        total_tokens: usage.total_tokens
      },
      %{agent: agent_name}
    )
  end

  @doc "Emit tool execution event"
  def tool_execute(tool_name, duration, success) do
    :telemetry.execute(
      [:yggdrasil, :tool, :execute],
      %{duration: duration},
      %{tool: tool_name, success: success}
    )
  end

  @doc "Emit model request event"
  def model_request(model, tokens) do
    :telemetry.execute(
      [:yggdrasil, :model, :request],
      %{tokens: tokens},
      %{model: model}
    )
  end
end
```

---

## Phase 10: Documentation & Examples (Weeks 13-14)

### Tasks

#### 10.1 Complete Module Documentation

- Add @moduledoc to all modules
- Add @doc to all public functions
- Include examples in docs
- Add typespecs to all functions

#### 10.2 Create Examples

```elixir
# examples/simple_chat.exs
Mix.install([{:yggdrasil, path: ".."}])

alias Yggdrasil.Agent

# Create agent
agent = Agent.new("openai:gpt-4",
  instructions: "Be helpful and concise"
)

# Run agent
{:ok, result} = Agent.run(agent, "What is the capital of France?")
IO.puts("Response: #{result.output}")
IO.puts("Tokens used: #{result.usage.total_tokens}")
```

#### 10.3 Write Guides

- Getting Started
- Tool Development
- Multi-Agent Systems
- Production Deployment
- Testing Guide

---

## Phase 11: Polish & Release (Weeks 15-16)

### Tasks

#### 11.1 Performance Optimization

- Profile hot paths
- Optimize message serialization
- Connection pooling
- Caching strategies

#### 11.2 Release Preparation

- [ ] Complete test coverage
- [ ] Run Dialyzer with no errors
- [ ] Run Credo with no issues
- [ ] Format all code
- [ ] Update CHANGELOG.md
- [ ] Write migration guide from Python

#### 11.3 Publish

- [ ] Publish to Hex.pm
- [ ] Create GitHub repository
- [ ] Set up CI/CD
- [ ] Create documentation site

---

## Testing Strategy Summary

### Unit Tests
- Test each module in isolation
- Use mocks for external dependencies
- Aim for >90% coverage

### Integration Tests
- Test with real API calls (tagged :integration)
- Test multi-agent scenarios
- Test streaming

### Property Tests
- Message serialization roundtrips
- Usage tracking invariants
- Tool execution properties

### Performance Tests
- Benchmark hot paths
- Memory profiling
- Concurrent load testing

---

## Development Commands

```bash
# Run tests
mix test

# Run only unit tests (fast)
mix test --exclude integration

# Run integration tests
mix test --only integration

# Type checking
mix dialyzer

# Linting
mix credo --strict

# Format code
mix format

# Generate docs
mix docs

# Run examples
mix run examples/simple_chat.exs
```

---

## Success Criteria

### Phase Completion

Each phase is complete when:
- [ ] All code is implemented
- [ ] Tests are passing
- [ ] Documentation is written
- [ ] No Dialyzer warnings
- [ ] Credo passes

### Project Completion

Project is ready for v0.1.0 release when:
- [ ] All phases complete
- [ ] Example applications work
- [ ] Documentation site live
- [ ] Hex.pm package published
- [ ] GitHub repository public
- [ ] CI/CD pipeline working

---

## Next Steps

1. Start with Phase 1: Project Setup
2. Work through phases sequentially
3. Test thoroughly at each phase
4. Document as you go
5. Gather feedback early and often

This implementation plan provides a clear path from zero to a working, tested, documented Elixir port of Pydantic AI.
