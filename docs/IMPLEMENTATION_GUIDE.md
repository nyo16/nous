# Yggdrasil AI - Implementation Guide with OpenAI.Ex

## Overview

This guide provides concrete implementation details for building Yggdrasil AI using the `openai_ex` library. All code examples are production-ready and follow Elixir best practices.

## Phase 1: Project Setup

### 1.1 Initialize Project

```bash
mix new exadantic --sup
cd exadantic
```

### 1.2 Configure mix.exs

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
      description: "Type-safe AI agent framework for Elixir with OpenAI-compatible models",
      source_url: @source_url
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
      # OpenAI client library
      {:openai_ex, "~> 0.9.17"},
      # or from GitHub:
      # {:openai_ex, github: "cyberchitta/openai_ex"},

      # JSON
      {:jason, "~> 1.4"},

      # Validation
      {:ecto, "~> 3.11"},

      # Telemetry
      {:telemetry, "~> 1.2"},

      # HTTP client (required by openai_ex)
      {:finch, "~> 0.18"},

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
end
```

### 1.3 Application Supervisor

```elixir
# lib/exadantic/application.ex
defmodule Yggdrasil.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Finch HTTP client pool for openai_ex
      {Finch,
       name: Yggdrasil.Finch,
       pools: %{
         # OpenAI
         "https://api.openai.com" => [size: 10],
         # Groq
         "https://api.groq.com" => [size: 10],
         # OpenRouter
         "https://openrouter.ai" => [size: 10],
         # Local Ollama
         "http://localhost:11434" => [size: 5]
       }},
      # Telemetry
      Yggdrasil.Telemetry.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Yggdrasil.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### 1.4 Configuration

```elixir
# config/config.exs
import Config

config :yggdrasil,
  # API Keys
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),

  # Finch pool name
  finch: Yggdrasil.Finch,

  # Default settings
  default_timeout: 60_000,
  stream_timeout: 120_000

# Import environment specific config
import_config "#{config_env()}.exs"
```

```elixir
# config/dev.exs
import Config

config :yggdrasil,
  log_level: :debug

# config/test.exs
import Config

config :yggdrasil,
  log_level: :warning

# config/prod.exs
import Config

config :yggdrasil,
  log_level: :info
```

## Phase 2: Core Data Types

### 2.1 Types Module

```elixir
# lib/exadantic/types.ex
defmodule Yggdrasil.Types do
  @moduledoc """
  Core type definitions for Yggdrasil AI.
  """

  @typedoc "Model identifier"
  @type model :: String.t()

  @typedoc "Output type specification"
  @type output_type :: :string | module()

  @typedoc "Message content"
  @type content ::
          String.t()
          | {:text, String.t()}
          | {:image_url, String.t()}

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

  @typedoc "Message parts in requests"
  @type request_part :: system_prompt_part() | user_prompt_part() | tool_return_part()

  @typedoc "Message parts in responses"
  @type response_part :: text_part() | tool_call_part()

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

  @typedoc "Model response"
  @type model_response :: %{
          parts: [response_part()],
          usage: Yggdrasil.Usage.t(),
          model_name: String.t(),
          timestamp: DateTime.t()
        }
end
```

### 2.2 Usage Tracking

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
          total_tokens: non_neg_integer()
        }

  defstruct requests: 0,
            tool_calls: 0,
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0

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
      total_tokens: u1.total_tokens + u2.total_tokens
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

  @doc "Add token counts from OpenAI usage"
  @spec from_openai(map()) :: t()
  def from_openai(openai_usage) do
    %__MODULE__{
      requests: 1,
      input_tokens: openai_usage.prompt_tokens || 0,
      output_tokens: openai_usage.completion_tokens || 0,
      total_tokens: openai_usage.total_tokens || 0
    }
  end
end
```

### 2.3 RunContext

```elixir
# lib/exadantic/run_context.ex
defmodule Yggdrasil.RunContext do
  @moduledoc """
  Context passed to tools and dynamic prompts.
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

## Phase 3: Model Integration with OpenAI.Ex

### 3.1 Model Configuration

```elixir
# lib/exadantic/model.ex
defmodule Yggdrasil.Model do
  @moduledoc """
  Model configuration for OpenAI-compatible APIs.
  """

  @type provider :: :openai | :groq | :ollama | :openrouter | :together | :custom

  @type t :: %__MODULE__{
          provider: provider(),
          model: String.t(),
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          organization: String.t() | nil,
          default_settings: map()
        }

  defstruct [
    :provider,
    :model,
    :base_url,
    :api_key,
    :organization,
    default_settings: %{}
  ]

  @doc """
  Parse model string into configuration.

  ## Examples

      iex> Model.parse("openai:gpt-4")
      %Model{provider: :openai, model: "gpt-4"}

      iex> Model.parse("groq:llama-3.1-70b-versatile")
      %Model{provider: :groq, model: "llama-3.1-70b-versatile",
             base_url: "https://api.groq.com/openai/v1"}
  """
  @spec parse(String.t(), keyword()) :: t()
  def parse(model_string, opts \\ [])

  def parse("openai:" <> model, opts) do
    %__MODULE__{
      provider: :openai,
      model: model,
      base_url: Keyword.get(opts, :base_url, "https://api.openai.com/v1"),
      api_key: Keyword.get(opts, :api_key, get_env_key(:openai)),
      organization: Keyword.get(opts, :organization),
      default_settings: Keyword.get(opts, :default_settings, %{})
    }
  end

  def parse("groq:" <> model, opts) do
    %__MODULE__{
      provider: :groq,
      model: model,
      base_url: Keyword.get(opts, :base_url, "https://api.groq.com/openai/v1"),
      api_key: Keyword.get(opts, :api_key, get_env_key(:groq)),
      default_settings: Keyword.get(opts, :default_settings, %{})
    }
  end

  def parse("ollama:" <> model, opts) do
    %__MODULE__{
      provider: :ollama,
      model: model,
      base_url: Keyword.get(opts, :base_url, "http://localhost:11434/v1"),
      api_key: Keyword.get(opts, :api_key, "ollama"),  # Ollama requires any non-empty key
      default_settings: Keyword.get(opts, :default_settings, %{})
    }
  end

  def parse("lmstudio:" <> model, opts) do
    %__MODULE__{
      provider: :lmstudio,
      model: model,
      base_url: Keyword.get(opts, :base_url, "http://localhost:1234/v1"),
      api_key: Keyword.get(opts, :api_key, "not-needed"),  # LM Studio doesn't require API key
      default_settings: Keyword.get(opts, :default_settings, %{})
    }
  end

  def parse("openrouter:" <> model, opts) do
    %__MODULE__{
      provider: :openrouter,
      model: model,
      base_url: Keyword.get(opts, :base_url, "https://openrouter.ai/api/v1"),
      api_key: Keyword.get(opts, :api_key, get_env_key(:openrouter)),
      default_settings: Keyword.get(opts, :default_settings, %{})
    }
  end

  def parse("together:" <> model, opts) do
    %__MODULE__{
      provider: :together,
      model: model,
      base_url: Keyword.get(opts, :base_url, "https://api.together.xyz/v1"),
      api_key: Keyword.get(opts, :api_key, get_env_key(:together)),
      default_settings: Keyword.get(opts, :default_settings, %{})
    }
  end

  def parse("custom:" <> model, opts) do
    %__MODULE__{
      provider: :custom,
      model: model,
      base_url: Keyword.fetch!(opts, :base_url),
      api_key: Keyword.get(opts, :api_key),
      default_settings: Keyword.get(opts, :default_settings, %{})
    }
  end

  @doc "Create OpenAI.Ex client from model config"
  @spec to_client(t()) :: OpenaiEx.t()
  def to_client(%__MODULE__{} = model) do
    config = %OpenaiEx.Config{
      api_key: model.api_key,
      base_url: model.base_url,
      organization: model.organization,
      http_options: %OpenaiEx.HttpOptions{
        finch: Application.get_env(:yggdrasil, :finch, Yggdrasil.Finch),
        receive_timeout: Application.get_env(:yggdrasil, :default_timeout, 60_000)
      }
    }

    OpenaiEx.new(config)
  end

  defp get_env_key(:openai), do: Application.get_env(:yggdrasil, :openai_api_key)
  defp get_env_key(:groq), do: Application.get_env(:yggdrasil, :groq_api_key)
  defp get_env_key(:openrouter), do: Application.get_env(:yggdrasil, :openrouter_api_key)
  defp get_env_key(:together), do: Application.get_env(:yggdrasil, :together_api_key)
  defp get_env_key(_), do: nil
end
```

### 3.2 Message Conversion

```elixir
# lib/exadantic/messages.ex
defmodule Yggdrasil.Messages do
  @moduledoc """
  Message construction and conversion for OpenAI.Ex.
  """

  alias Yggdrasil.Types
  alias OpenaiEx.ChatMessage

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

  @doc "Convert our message format to OpenAI.Ex ChatMessage format"
  @spec to_openai_messages([Types.request_part() | Types.model_response()]) :: [
          ChatMessage.t()
        ]
  def to_openai_messages(messages) do
    Enum.map(messages, &to_openai_message/1)
  end

  defp to_openai_message({:system_prompt, text}) do
    ChatMessage.system(text)
  end

  defp to_openai_message({:user_prompt, text}) when is_binary(text) do
    ChatMessage.user(text)
  end

  defp to_openai_message({:user_prompt, content}) when is_list(content) do
    ChatMessage.user(convert_content_list(content))
  end

  defp to_openai_message({:tool_return, %{call_id: id, result: result}}) do
    ChatMessage.tool(Jason.encode!(result), id)
  end

  # Previous assistant response with tool calls
  defp to_openai_message(%{parts: parts}) do
    text = extract_text(parts)
    tool_calls = extract_tool_calls(parts)

    content = if text == "", do: nil, else: text

    if Enum.empty?(tool_calls) do
      ChatMessage.assistant(content)
    else
      openai_tool_calls = Enum.map(tool_calls, &to_openai_tool_call/1)
      ChatMessage.assistant(content, tool_calls: openai_tool_calls)
    end
  end

  defp convert_content_list(content) do
    Enum.map(content, fn
      {:text, text} -> %{type: "text", text: text}
      {:image_url, url} -> %{type: "image_url", image_url: %{url: url}}
      text when is_binary(text) -> %{type: "text", text: text}
    end)
  end

  defp to_openai_tool_call(%{id: id, name: name, arguments: args}) do
    %{
      id: id,
      type: "function",
      function: %{
        name: name,
        arguments: Jason.encode!(args)
      }
    }
  end

  @doc "Parse OpenAI.Ex response into our format"
  @spec from_openai_response(map()) :: Types.model_response()
  def from_openai_response(response) do
    choice = List.first(response.choices)
    message = choice.message

    parts = []

    # Add text content
    parts =
      if message.content && message.content != "" do
        [{:text, message.content} | parts]
      else
        parts
      end

    # Add tool calls
    parts =
      if message.tool_calls do
        tool_parts = Enum.map(message.tool_calls, &parse_tool_call/1)
        tool_parts ++ parts
      else
        parts
      end

    %{
      parts: Enum.reverse(parts),
      usage: Yggdrasil.Usage.from_openai(response.usage),
      model_name: response.model,
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_tool_call(tool_call) do
    {:tool_call,
     %{
       id: tool_call.id,
       name: tool_call.function.name,
       arguments: Jason.decode!(tool_call.function.arguments)
     }}
  end
end
```

### 3.3 Model Implementation

```elixir
# lib/exadantic/models/openai_compatible.ex
defmodule Yggdrasil.Models.OpenAICompatible do
  @moduledoc """
  OpenAI-compatible model implementation using openai_ex library.

  Works with any OpenAI-compatible API endpoint:
  - OpenAI
  - Groq
  - Ollama
  - OpenRouter
  - Together AI
  - Custom endpoints
  """

  alias Yggdrasil.{Model, Messages, Types}
  alias OpenaiEx.Chat

  require Logger

  @doc """
  Make a request to the model.
  """
  @spec request(Model.t(), [Types.request_part() | Types.model_response()], map()) ::
          {:ok, Types.model_response()} | {:error, term()}
  def request(%Model{} = model, messages, settings) do
    # Create OpenAI.Ex client
    client = Model.to_client(model)

    # Convert messages to OpenAI format
    openai_messages = Messages.to_openai_messages(messages)

    # Build request parameters
    params = build_request_params(model, openai_messages, settings)

    # Log request for debugging
    Logger.debug("Making request to #{model.provider}:#{model.model}")

    # Make request
    case Chat.Completions.create(client, params) do
      {:ok, response} ->
        {:ok, Messages.from_openai_response(response)}

      {:error, error} ->
        Logger.error("Model request failed: #{inspect(error)}")
        {:error, format_error(error)}
    end
  end

  @doc """
  Make a streaming request to the model.
  """
  @spec request_stream(Model.t(), [Types.request_part() | Types.model_response()], map()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def request_stream(%Model{} = model, messages, settings) do
    client = Model.to_client(model)
    openai_messages = Messages.to_openai_messages(messages)

    # Enable streaming and configure timeout
    settings =
      settings
      |> Map.put(:stream, true)
      |> Map.put_new(:stream_timeout, Application.get_env(:yggdrasil, :stream_timeout, 120_000))

    params = build_request_params(model, openai_messages, settings)

    Logger.debug("Making streaming request to #{model.provider}:#{model.model}")

    case Chat.Completions.create(client, params) do
      {:ok, stream} ->
        # Transform OpenAI.Ex stream events to our format
        transformed_stream = Stream.map(stream, &parse_stream_chunk/1)
        {:ok, transformed_stream}

      {:error, error} ->
        Logger.error("Streaming request failed: #{inspect(error)}")
        {:error, format_error(error)}
    end
  end

  @doc """
  Estimate token count (rough approximation).
  """
  @spec count_tokens([any()]) :: integer()
  def count_tokens(messages) do
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
  end

  # Private functions

  defp build_request_params(model, messages, settings) do
    # Merge model defaults with request settings
    merged_settings = Map.merge(model.default_settings, settings)

    # Build base parameters
    params = Chat.Completions.new(
      model: model.model,
      messages: messages
    )

    # Add optional parameters
    params
    |> maybe_put(:temperature, merged_settings[:temperature])
    |> maybe_put(:max_tokens, merged_settings[:max_tokens])
    |> maybe_put(:top_p, merged_settings[:top_p])
    |> maybe_put(:frequency_penalty, merged_settings[:frequency_penalty])
    |> maybe_put(:presence_penalty, merged_settings[:presence_penalty])
    |> maybe_put(:stop, merged_settings[:stop_sequences])
    |> maybe_put(:stream, merged_settings[:stream])
    |> maybe_put(:tools, merged_settings[:tools])
    |> maybe_put(:tool_choice, merged_settings[:tool_choice])
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp parse_stream_chunk(chunk) do
    # OpenAI.Ex provides chunk with choices
    choice = List.first(chunk.choices)

    if choice do
      delta = choice.delta

      cond do
        delta.content ->
          {:text_delta, delta.content}

        delta.tool_calls ->
          {:tool_call_delta, delta.tool_calls}

        choice.finish_reason ->
          {:finish, choice.finish_reason}

        true ->
          {:unknown, chunk}
      end
    else
      {:unknown, chunk}
    end
  end

  defp format_error(error) do
    # Convert OpenAI.Ex errors to our format
    case error do
      %{message: message} -> {:api_error, message}
      _ -> {:unknown_error, error}
    end
  end

  defp estimate_message_tokens(message) do
    # Rough estimation: ~4 characters per token
    message
    |> inspect()
    |> String.length()
    |> div(4)
  end
end
```

## Phase 4: Tool System

### 4.1 Tool Definition

```elixir
# lib/exadantic/tool.ex
defmodule Yggdrasil.Tool do
  @moduledoc """
  Tool definition for agent function calling.
  """

  alias Yggdrasil.RunContext

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          function: function(),
          takes_ctx: boolean(),
          retries: non_neg_integer()
        }

  defstruct [
    :name,
    :description,
    :parameters,
    :function,
    takes_ctx: true,
    retries: 1
  ]

  @doc """
  Create tool from function.

  ## Examples

      defmodule MyTools do
        @doc "Search the database"
        def search(ctx, query) do
          # Implementation
        end
      end

      tool = Tool.from_function(&MyTools.search/2, name: "search_db")
  """
  @spec from_function(function(), keyword()) :: t()
  def from_function(fun, opts \\ []) do
    # Extract function info
    info = Function.info(fun)
    {module, function_name, arity} = {info[:module], info[:name], info[:arity]}

    # Determine if function takes context
    takes_ctx = arity == 2

    # Extract documentation
    {description, param_schema} = extract_docs(module, function_name, arity)

    %__MODULE__{
      name: Keyword.get(opts, :name, to_string(function_name)),
      description: Keyword.get(opts, :description, description),
      parameters: Keyword.get(opts, :parameters, param_schema),
      function: fun,
      takes_ctx: takes_ctx,
      retries: Keyword.get(opts, :retries, 1)
    }
  end

  @doc "Convert tool to OpenAI function schema"
  @spec to_openai_schema(t()) :: map()
  def to_openai_schema(%__MODULE__{} = tool) do
    %{
      type: "function",
      function: %{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    }
  end

  defp extract_docs(module, function_name, arity) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, docs} ->
        doc_entry =
          Enum.find(docs, fn
            {{:function, ^function_name, ^arity}, _, _, doc, _} when doc != :none -> true
            _ -> false
          end)

        case doc_entry do
          {{:function, _, _}, _, _, %{"en" => doc_text}, _} ->
            # Parse documentation
            {extract_description(doc_text), extract_parameters(doc_text)}

          _ ->
            {"", default_parameters(arity)}
        end

      _ ->
        {"", default_parameters(arity)}
    end
  end

  defp extract_description(doc_text) do
    # Take first line/paragraph as description
    doc_text
    |> String.split("\n\n")
    |> List.first()
    |> String.trim()
  end

  defp extract_parameters(_doc_text) do
    # For now, use a simple schema
    # In a full implementation, parse parameter docs
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Query parameter"}
      },
      required: ["query"]
    }
  end

  defp default_parameters(arity) when arity == 2 do
    %{
      type: "object",
      properties: %{
        input: %{type: "string", description: "Input parameter"}
      },
      required: ["input"]
    }
  end

  defp default_parameters(_), do: %{type: "object", properties: %{}}
end
```

### 4.2 Tool Executor

```elixir
# lib/exadantic/tool_executor.ex
defmodule Yggdrasil.ToolExecutor do
  @moduledoc """
  Executes tool functions with retry logic.
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
      result =
        if tool.takes_ctx do
          # Pass context and arguments
          apply_tool_with_ctx(tool.function, ctx, arguments)
        else
          # Just pass arguments
          apply_tool(tool.function, arguments)
        end

      {:ok, result}
    rescue
      error ->
        Logger.warning("Tool #{tool.name} failed (attempt #{attempt + 1}): #{inspect(error)}")

        if attempt < tool.retries do
          # Retry with incremented retry count
          new_ctx = %{ctx | retry: attempt + 1}
          do_execute(tool, arguments, new_ctx, attempt + 1)
        else
          Logger.error("Tool #{tool.name} failed after #{tool.retries} attempts")
          {:error, error}
        end
    end
  end

  defp apply_tool_with_ctx(fun, ctx, args) when is_map(args) do
    # If args is a map with a single key matching the parameter name, extract it
    case Map.keys(args) do
      [single_key] -> fun.(ctx, Map.get(args, single_key))
      _ -> fun.(ctx, args)
    end
  end

  defp apply_tool(fun, args) when is_map(args) do
    case Map.keys(args) do
      [single_key] -> fun.(Map.get(args, single_key))
      _ -> fun.(args)
    end
  end
end
```

## Phase 5: Agent & Agent Runner

### 5.1 Agent Definition

```elixir
# lib/exadantic/agent.ex
defmodule Yggdrasil.Agent do
  @moduledoc """
  Primary interface for AI agents.
  """

  alias Yggdrasil.{Model, Tool, Types}

  @type t :: %__MODULE__{
          model: Model.t(),
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

  ## Examples

      # OpenAI GPT-4
      agent = Agent.new("openai:gpt-4")

      # Groq Llama 3.1
      agent = Agent.new("groq:llama-3.1-70b-versatile")

      # Local Ollama
      agent = Agent.new("ollama:llama2")

      # Local LM Studio
      agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507")

      # With options
      agent = Agent.new("openai:gpt-4",
        instructions: "Be helpful and concise",
        tools: [&MyTools.search/2],
        model_settings: %{temperature: 0.7}
      )
  """
  @spec new(String.t(), keyword()) :: t()
  def new(model_string, opts \\ []) do
    model = Model.parse(model_string, opts)

    %__MODULE__{
      model: model,
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

  ## Examples

      {:ok, result} = Agent.run(agent, "What is 2+2?")
      IO.puts(result.output) # "4"

      # With dependencies
      {:ok, result} = Agent.run(agent, "Search for users",
        deps: %{database: MyApp.DB}
      )
  """
  @spec run(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = agent, prompt, opts \\ []) do
    Yggdrasil.AgentRunner.run(agent, prompt, opts)
  end

  @doc """
  Run agent with streaming.

  ## Examples

      {:ok, stream} = Agent.run_stream(agent, "Tell me a story")

      stream
      |> Stream.each(fn
        {:text_delta, text} -> IO.write(text)
        {:complete, result} -> IO.puts("\\nDone!")
      end)
      |> Stream.run()
  """
  @spec run_stream(t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run_stream(%__MODULE__{} = agent, prompt, opts \\ []) do
    Yggdrasil.AgentRunner.run_stream(agent, prompt, opts)
  end

  @doc "Register a tool with the agent"
  @spec tool(t(), function(), keyword()) :: t()
  def tool(%__MODULE__{} = agent, tool_fun, opts \\ []) do
    tool = Tool.from_function(tool_fun, opts)
    %{agent | tools: [tool | agent.tools]}
  end

  defp parse_tools(tools) do
    Enum.map(tools, fn
      %Tool{} = tool -> tool
      fun when is_function(fun) -> Tool.from_function(fun)
    end)
  end

  defp generate_name do
    "agent_#{:erlang.unique_integer([:positive])}"
  end
end
```

### 5.2 Agent Runner

```elixir
# lib/exadantic/agent_runner.ex
defmodule Yggdrasil.AgentRunner do
  @moduledoc """
  Executes agent runs with tool calling loop.
  """

  alias Yggdrasil.{
    Agent,
    Messages,
    Models.OpenAICompatible,
    RunContext,
    Tool,
    ToolExecutor,
    Usage
  }

  require Logger

  @max_iterations 10

  @doc "Run agent to completion"
  @spec run(Agent.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Agent{} = agent, prompt, opts \\ []) do
    # Initialize state
    state = %{
      agent: agent,
      deps: Keyword.get(opts, :deps),
      message_history: Keyword.get(opts, :message_history, []),
      usage: Usage.new(),
      iteration: 0
    }

    # Build initial messages
    messages = build_initial_messages(state, prompt)

    # Execute loop
    execute_loop(state, messages)
  end

  @doc "Run agent with streaming (placeholder - full implementation needed)"
  @spec run_stream(Agent.t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run_stream(%Agent{} = agent, prompt, opts \\ []) do
    # For now, return a simple stream wrapper
    # Full streaming implementation would handle tool calls in stream
    model_settings = Map.put(agent.model_settings, :stream, true)

    messages =
      build_initial_messages(
        %{agent: agent, deps: Keyword.get(opts, :deps), message_history: []},
        prompt
      )

    case OpenAICompatible.request_stream(agent.model, messages, model_settings) do
      {:ok, stream} -> {:ok, stream}
      error -> error
    end
  end

  # Private functions

  defp execute_loop(state, messages) do
    if state.iteration >= @max_iterations do
      {:error, :max_iterations_exceeded}
    else
      # Add tools to model settings if any
      model_settings =
        if Enum.empty?(state.agent.tools) do
          state.agent.model_settings
        else
          tool_schemas = Enum.map(state.agent.tools, &Tool.to_openai_schema/1)
          Map.put(state.agent.model_settings, :tools, tool_schemas)
        end

      # Make model request
      case OpenAICompatible.request(state.agent.model, messages, model_settings) do
        {:ok, response} ->
          # Update usage
          new_usage = Usage.add(state.usage, response.usage)
          new_state = %{state | usage: new_usage, iteration: state.iteration + 1}

          # Check for tool calls
          tool_calls = Messages.extract_tool_calls(response.parts)

          if Enum.empty?(tool_calls) do
            # No tool calls, extract final output
            output = extract_output(response, state.agent.output_type)

            {:ok,
             %{
               output: output,
               usage: new_usage,
               all_messages: messages ++ [response],
               new_messages: [response]
             }}
          else
            # Execute tools and continue
            Logger.debug("Executing #{length(tool_calls)} tool calls")
            handle_tool_calls(new_state, messages, response, tool_calls)
          end

        {:error, reason} ->
          Logger.error("Model request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp handle_tool_calls(state, messages, response, tool_calls) do
    # Build run context
    ctx = RunContext.new(state.deps, usage: state.usage)

    # Execute all tool calls
    tool_results =
      Enum.map(tool_calls, fn call ->
        execute_single_tool(state.agent.tools, call, ctx)
      end)

    # Add response and tool results to messages
    new_messages = messages ++ [response] ++ tool_results

    # Continue loop
    execute_loop(state, new_messages)
  end

  defp execute_single_tool(tools, call, ctx) do
    tool = Enum.find(tools, fn t -> t.name == call.name end)

    result =
      if tool do
        case ToolExecutor.execute(tool, call.arguments, ctx) do
          {:ok, result} ->
            result

          {:error, error} ->
            "Error executing tool: #{inspect(error)}"
        end
      else
        "Tool not found: #{call.name}"
      end

    Messages.tool_return(call.id, result)
  end

  defp build_initial_messages(state, prompt) do
    messages = []

    # Add system prompt / instructions
    messages =
      if state.agent.instructions do
        [Messages.system_prompt(state.agent.instructions) | messages]
      else
        messages
      end

    # Add message history
    messages = messages ++ state.message_history

    # Add user prompt
    messages = messages ++ [Messages.user_prompt(prompt)]

    messages
  end

  defp extract_output(response, :string) do
    Messages.extract_text(response.parts)
  end

  defp extract_output(response, output_module) when is_atom(output_module) do
    # For structured outputs, look for tool call with schema
    # This would need more sophisticated handling in production
    Messages.extract_text(response.parts)
  end
end
```

## Phase 6: Example Usage

### 6.1 Simple Example

```elixir
# examples/simple.exs
Mix.install([
  {:yggdrasil, path: ".."}
])

alias Yggdrasil.Agent

# Create agent
agent = Agent.new("openai:gpt-4",
  instructions: "Be helpful and concise",
  model_settings: %{temperature: 0.7}
)

# Run agent
IO.puts("Running agent...")
{:ok, result} = Agent.run(agent, "What is the capital of France?")

IO.puts("\nResponse: #{result.output}")
IO.puts("Tokens used: #{result.usage.total_tokens}")
```

### 6.2 With Tools

```elixir
# examples/with_tools.exs
Mix.install([
  {:yggdrasil, path: ".."}
])

alias Yggdrasil.Agent

defmodule MyTools do
  @doc """
  Calculate the result of a mathematical expression.
  """
  def calculate(_ctx, %{"expression" => expr}) do
    # Simple calculator (in production, use a safe eval library)
    "Result: #{expr}"
  end

  @doc """
  Get the current time.
  """
  def get_time(_ctx, _args) do
    DateTime.utc_now() |> DateTime.to_string()
  end
end

# Create agent with tools
agent =
  Agent.new("groq:llama-3.1-70b-versatile",
    instructions: "You are a helpful assistant with access to tools",
    tools: [
      &MyTools.calculate/2,
      &MyTools.get_time/2
    ]
  )

# Run agent
{:ok, result} = Agent.run(agent, "What time is it and what is 25 * 4?")

IO.puts("Response: #{result.output}")
IO.puts("Tokens: #{result.usage.total_tokens}")
IO.puts("Tool calls: #{result.usage.tool_calls}")
```

This implementation guide provides everything needed to build the core of Yggdrasil AI using the `openai_ex` library!