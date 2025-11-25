defmodule Yggdrasil.Agent do
  @moduledoc """
  Primary interface for AI agents.

  An Agent is a stateless configuration object that defines how to interact
  with an AI model. It specifies the model, instructions, tools, and output format.

  ## Example

      # Simple agent
      agent = Agent.new("openai:gpt-4",
        instructions: "Be helpful and concise"
      )

      {:ok, result} = Agent.run(agent, "What is 2+2?")
      IO.puts(result.output) # "4"

      # Agent with tools
      agent = Agent.new("groq:llama-3.1-70b-versatile",
        instructions: "Help users find information",
        tools: [&MyTools.search/2]
      )

      {:ok, result} = Agent.run(agent, "Search for Elixir tutorials",
        deps: %{database: MyApp.DB}
      )

  """

  alias Yggdrasil.{Model, ModelParser, Tool, Types}

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
          end_strategy: :early | :exhaustive,
          enable_todos: boolean()
        }

  @enforce_keys [:model]
  defstruct [
    :model,
    :deps_type,
    output_type: :string,
    instructions: nil,
    system_prompt: nil,
    name: nil,
    model_settings: %{},
    retries: 1,
    tools: [],
    end_strategy: :early,
    enable_todos: false
  ]

  @doc """
  Create a new agent.

  ## Parameters
    * `model_string` - Model in format "provider:model-name"
    * `opts` - Configuration options

  ## Options
    * `:output_type` - Expected output type (`:string` or Ecto schema module)
    * `:instructions` - Static instructions or function returning instructions
    * `:system_prompt` - Static system prompt or function
    * `:deps_type` - Module defining dependency structure
    * `:name` - Agent name for logging
    * `:model_settings` - Model settings (temperature, max_tokens, etc.)
    * `:retries` - Default retry count for tools
    * `:enable_todos` - Enable automatic todo tracking (default: false)
    * `:tools` - List of tool functions or Tool structs
    * `:end_strategy` - How to handle tool calls (`:early` or `:exhaustive`)

  ## Examples

      # OpenAI GPT-4
      agent = Agent.new("openai:gpt-4")

      # Groq Llama with settings
      agent = Agent.new("groq:llama-3.1-70b-versatile",
        instructions: "Be concise",
        model_settings: %{temperature: 0.7, max_tokens: 1000}
      )

      # Local LM Studio
      agent = Agent.new("lmstudio:qwen/qwen3-30b",
        instructions: "Always answer in rhymes"
      )

      # With tools
      agent = Agent.new("openai:gpt-4",
        tools: [&MyTools.search/2, &MyTools.calculate/2]
      )

  """
  @spec new(String.t(), keyword()) :: t()
  def new(model_string, opts \\ []) do
    model = ModelParser.parse(model_string, opts)

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

  ## Options
    * `:deps` - Dependencies to pass to tools and prompts
    * `:message_history` - Previous messages to continue conversation
    * `:usage_limits` - Usage limits for this run
    * `:model_settings` - Override model settings for this run

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

  ## Returns

      {:ok, %{
        output: "Result text or structured output",
        usage: %Usage{...},
        all_messages: [...],
        new_messages: [...]
      }}

      {:error, reason}

  """
  @spec run(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = agent, prompt, opts \\ []) do
    Yggdrasil.AgentRunner.run(agent, prompt, opts)
  end

  @doc """
  Run agent with streaming.

  Returns a stream that yields events as they occur.

  ## Events
    * `{:text_delta, text}` - Incremental text update
    * `{:tool_call, call}` - Tool is being called
    * `{:tool_result, result}` - Tool execution completed
    * `{:complete, result}` - Final result

  ## Example

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

  @doc """
  Register a tool with the agent.

  Returns a new agent with the tool added.

  ## Options
    * `:name` - Custom tool name (default: function name)
    * `:description` - Custom description
    * `:retries` - Retry count for this tool
    * `:requires_approval` - Whether tool needs human approval

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
