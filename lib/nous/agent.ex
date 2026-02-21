defmodule Nous.Agent do
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

  alias Nous.{Model, Tool, Types}

  @type t :: %__MODULE__{
          model: Model.t(),
          output_type: Types.output_type(),
          structured_output: keyword(),
          instructions: String.t() | function() | nil,
          system_prompt: String.t() | function() | nil,
          deps_type: module() | nil,
          name: String.t(),
          model_settings: map(),
          retries: non_neg_integer(),
          tools: [Tool.t()],
          plugins: [module()],
          end_strategy: :early | :exhaustive,
          enable_todos: boolean(),
          behaviour_module: module() | nil
        }

  @enforce_keys [:model]
  defstruct [
    :model,
    :deps_type,
    :behaviour_module,
    output_type: :string,
    structured_output: [],
    instructions: nil,
    system_prompt: nil,
    name: nil,
    model_settings: %{},
    retries: 1,
    tools: [],
    plugins: [],
    end_strategy: :early,
    enable_todos: false
  ]

  @doc """
  Create a new agent.

  ## Parameters
    * `model_string` - Model in format "provider:model-name"
    * `opts` - Configuration options

  ## Options
    * `:output_type` - Expected output type (`:string`, Ecto schema, schemaless map, JSON schema, or guided mode tuple)
    * `:structured_output` - Structured output options (`mode:`, `max_retries:`)
    * `:instructions` - Static instructions or function returning instructions
    * `:system_prompt` - Static system prompt or function
    * `:deps_type` - Module defining dependency structure
    * `:name` - Agent name for logging
    * `:model_settings` - Model settings (temperature, max_tokens, etc.)
    * `:retries` - Default retry count for tools
    * `:enable_todos` - Enable automatic todo tracking (default: false)
    * `:tools` - List of tool functions or Tool structs
    * `:plugins` - List of plugin modules implementing `Nous.Plugin` behaviour
    * `:end_strategy` - How to handle tool calls (`:early` or `:exhaustive`)
    * `:behaviour_module` - Custom agent behaviour module (default: BasicAgent)

  ## Examples

      # OpenAI GPT-4
      agent = Agent.new("openai:gpt-4")

      # Groq Llama with settings
      agent = Agent.new("groq:llama-3.1-70b-versatile",
        instructions: "Be concise",
        model_settings: %{temperature: 0.7, max_tokens: 1000}
      )

      # Local LM Studio
      agent = Agent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        instructions: "Always answer in rhymes"
      )

      # With tools
      agent = Agent.new("openai:gpt-4",
        tools: [&MyTools.search/2, &MyTools.calculate/2]
      )

  """
  @spec new(String.t(), keyword()) :: t()
  def new(model_string, opts \\ []) do
    model = Model.parse(model_string, opts)

    %__MODULE__{
      model: model,
      output_type: Keyword.get(opts, :output_type, :string),
      structured_output: Keyword.get(opts, :structured_output, []),
      instructions: Keyword.get(opts, :instructions),
      system_prompt: Keyword.get(opts, :system_prompt),
      deps_type: Keyword.get(opts, :deps_type),
      name: Keyword.get(opts, :name, generate_name()),
      model_settings: Keyword.get(opts, :model_settings, %{}),
      retries: Keyword.get(opts, :retries, 1),
      tools: parse_tools(Keyword.get(opts, :tools, [])),
      plugins: Keyword.get(opts, :plugins, []),
      end_strategy: Keyword.get(opts, :end_strategy, :early),
      behaviour_module: Keyword.get(opts, :behaviour_module)
    }
  end

  @doc """
  Run agent synchronously.

  ## Input Formats

  The second argument accepts multiple formats:

  - **String prompt**: Simple string message from user
  - **Keyword list**: Use `:messages` for custom message list, `:context` to continue from previous run

  ## Options
    * `:deps` - Dependencies to pass to tools and prompts
    * `:message_history` - Previous messages to continue conversation
    * `:usage_limits` - Usage limits for this run
    * `:model_settings` - Override model settings for this run
    * `:callbacks` - Map of callback functions for events
    * `:notify_pid` - PID to receive event messages
    * `:context` - Existing context to continue from

  ## Examples

      # String prompt
      {:ok, result} = Agent.run(agent, "What is the capital of France?")
      IO.puts(result.output) # "Paris"

      # With dependencies
      {:ok, result} = Agent.run(agent, "Search for users",
        deps: %{database: MyApp.DB}
      )

      # Message list directly
      {:ok, result} = Agent.run(agent,
        messages: [
          Message.system("Be concise"),
          Message.user("What is 2+2?")
        ]
      )

      # Continue from previous context
      {:ok, result1} = Agent.run(agent, "First question")
      {:ok, result2} = Agent.run(agent, "Follow up",
        context: result1.context
      )

      # Continue conversation with message history
      {:ok, result2} = Agent.run(agent, "Tell me more",
        message_history: result1.new_messages
      )

      # With callbacks
      {:ok, result} = Agent.run(agent, "Hello",
        callbacks: %{
          on_llm_new_delta: fn _, text -> IO.write(text) end
        }
      )

  ## Returns

      {:ok, %{
        output: "Result text or structured output",
        usage: %Usage{...},
        all_messages: [...],
        new_messages: [...],
        context: %Context{...}  # Can be used for continuation
      }}

      {:error, reason}

  """
  @spec run(t(), String.t() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(agent, input, opts \\ [])

  # String prompt
  def run(%__MODULE__{} = agent, prompt, opts) when is_binary(prompt) do
    Nous.AgentRunner.run(agent, prompt, opts)
  end

  # Keyword input with messages or context
  def run(%__MODULE__{} = agent, input, opts) when is_list(input) do
    merged_opts = Keyword.merge(input, opts)

    cond do
      Keyword.has_key?(merged_opts, :messages) ->
        # Build context from messages
        messages = Keyword.fetch!(merged_opts, :messages)
        run_with_messages(agent, messages, Keyword.delete(merged_opts, :messages))

      Keyword.has_key?(merged_opts, :context) ->
        # Continue from existing context - need a prompt
        {:error, :prompt_required_with_context}

      true ->
        {:error, :invalid_input}
    end
  end

  defp run_with_messages(agent, messages, opts) do
    alias Nous.Agent.Context

    # Build initial context from messages
    ctx =
      Context.new(
        messages: messages,
        deps: Keyword.get(opts, :deps, %{}),
        max_iterations: Keyword.get(opts, :max_iterations, 10),
        callbacks: Keyword.get(opts, :callbacks, %{}),
        notify_pid: Keyword.get(opts, :notify_pid),
        agent_name: agent.name,
        cancellation_check: Keyword.get(opts, :cancellation_check),
        needs_response: true
      )

    # Run with pre-built context
    Nous.AgentRunner.run_with_context(agent, ctx, opts)
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
    Nous.AgentRunner.run_stream(agent, prompt, opts)
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
