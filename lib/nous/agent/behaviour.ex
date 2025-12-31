defmodule Nous.Agent.Behaviour do
  @moduledoc """
  Behaviour for agent implementations.

  Defines the interface that different agent types must implement,
  allowing for customized execution logic while sharing common infrastructure.

  ## Implementing an Agent

  To create a custom agent type, implement this behaviour:

      defmodule MyApp.CustomAgent do
        @behaviour Nous.Agent.Behaviour

        @impl true
        def init_context(agent, ctx) do
          # Add custom initialization
          ctx
        end

        @impl true
        def build_messages(agent, ctx) do
          # Build messages for the LLM
          ctx.messages
        end

        @impl true
        def process_response(agent, message, ctx) do
          # Process LLM response, handle tool calls
          Context.add_message(ctx, message)
        end

        @impl true
        def extract_output(agent, ctx) do
          # Extract final output from context
          {:ok, Context.last_message(ctx).content}
        end

        @impl true
        def get_tools(agent) do
          agent.tools
        end
      end

  ## Built-in Implementations

  - `Nous.Agents.BasicAgent` - Standard tool-calling agent
  - `Nous.Agents.ReActAgent` - Structured reasoning with plan/note/final_answer

  ## Using with Agent.new

      agent = Agent.new("openai:gpt-4",
        behaviour_module: MyApp.CustomAgent,
        tools: [&search/2]
      )

  """

  alias Nous.Agent.Context

  @doc """
  Initialize context before execution begins.

  Called once at the start of `Agent.run/3`. Use this to:
  - Add agent-specific tools (e.g., ReAct tools)
  - Set up initial state in deps
  - Configure callbacks

  ## Parameters

    * `agent` - The agent configuration
    * `ctx` - Initial context from run options

  ## Returns

  Modified context for execution.

  ## Example

      @impl true
      def init_context(agent, ctx) do
        # Add ReAct-specific tools
        ctx
        |> Context.merge_deps(%{tool_history: []})
      end

  """
  @callback init_context(agent :: Nous.Agent.t(), ctx :: Context.t()) :: Context.t()

  @doc """
  Build messages to send to the LLM.

  Called at the start of each iteration. Use this to:
  - Add system prompts
  - Format messages for the provider
  - Include tool schemas

  ## Parameters

    * `agent` - The agent configuration
    * `ctx` - Current context with messages

  ## Returns

  List of messages to send to the model.

  ## Example

      @impl true
      def build_messages(agent, ctx) do
        system_msg = Message.system(agent.instructions)
        [system_msg | ctx.messages]
      end

  """
  @callback build_messages(agent :: Nous.Agent.t(), ctx :: Context.t()) :: [Nous.Message.t()]

  @doc """
  Process a response from the LLM.

  Called after each model response. Use this to:
  - Handle tool calls
  - Update context state
  - Set `needs_response` based on whether more work is needed

  ## Parameters

    * `agent` - The agent configuration
    * `message` - The LLM's response message
    * `ctx` - Current context

  ## Returns

  Updated context. The runner will check `ctx.needs_response` to decide
  whether to continue the loop.

  ## Example

      @impl true
      def process_response(agent, message, ctx) do
        ctx = Context.add_message(ctx, message)

        if Message.has_tool_calls?(message) do
          # Execute tools and add results
          execute_tools_and_continue(ctx, message.tool_calls)
        else
          # No tool calls - we're done
          Context.set_needs_response(ctx, false)
        end
      end

  """
  @callback process_response(
              agent :: Nous.Agent.t(),
              message :: Nous.Message.t(),
              ctx :: Context.t()
            ) :: Context.t()

  @doc """
  Extract the final output from the context.

  Called after the execution loop completes. Use this to:
  - Extract the final answer
  - Format structured output
  - Validate the result

  ## Parameters

    * `agent` - The agent configuration
    * `ctx` - Final context after execution

  ## Returns

    * `{:ok, output}` - Successfully extracted output
    * `{:error, reason}` - Failed to extract valid output

  ## Example

      @impl true
      def extract_output(_agent, ctx) do
        case Context.last_message(ctx) do
          %Message{role: :assistant, content: content} ->
            {:ok, content}
          _ ->
            {:error, :no_output}
        end
      end

  """
  @callback extract_output(agent :: Nous.Agent.t(), ctx :: Context.t()) ::
              {:ok, any()} | {:error, term()}

  @doc """
  Get tools available for this agent run.

  Called to determine which tools to advertise to the model.
  Implementations may add agent-specific tools (e.g., ReAct tools).

  ## Parameters

    * `agent` - The agent configuration

  ## Returns

  List of Tool structs.

  ## Example

      @impl true
      def get_tools(agent) do
        react_tools = [plan_tool(), note_tool(), final_answer_tool()]
        react_tools ++ agent.tools
      end

  """
  @callback get_tools(agent :: Nous.Agent.t()) :: [Nous.Tool.t()]

  @doc """
  Called when the agent encounters an error.

  Optional callback for custom error handling. Default behavior
  is to return the error.

  ## Parameters

    * `agent` - The agent configuration
    * `error` - The error that occurred
    * `ctx` - Current context when error occurred

  ## Returns

    * `{:retry, ctx}` - Retry the current iteration
    * `{:continue, ctx}` - Continue with modified context
    * `{:error, reason}` - Propagate error

  """
  @callback handle_error(
              agent :: Nous.Agent.t(),
              error :: term(),
              ctx :: Context.t()
            ) :: {:retry, Context.t()} | {:continue, Context.t()} | {:error, term()}

  @doc """
  Called before each LLM request.

  Optional callback for request-level customization.

  ## Parameters

    * `agent` - The agent configuration
    * `ctx` - Current context
    * `request_opts` - Options for the LLM request

  ## Returns

  Modified request options.

  """
  @callback before_request(
              agent :: Nous.Agent.t(),
              ctx :: Context.t(),
              request_opts :: keyword()
            ) :: keyword()

  @doc """
  Called after each tool execution.

  Optional callback for tool result processing.

  ## Parameters

    * `agent` - The agent configuration
    * `tool_call` - The tool call that was executed
    * `result` - The tool result
    * `ctx` - Current context

  ## Returns

  Modified context.

  """
  @callback after_tool(
              agent :: Nous.Agent.t(),
              tool_call :: map(),
              result :: any(),
              ctx :: Context.t()
            ) :: Context.t()

  @optional_callbacks [
    init_context: 2,
    handle_error: 3,
    before_request: 3,
    after_tool: 4
  ]

  @doc """
  Get the behaviour module for an agent.

  Returns the configured behaviour module, or the default BasicAgent.

  ## Examples

      iex> agent = Agent.new("openai:gpt-4")
      iex> Behaviour.get_module(agent)
      Nous.Agents.BasicAgent

      iex> agent = Agent.new("openai:gpt-4", behaviour_module: MyAgent)
      iex> Behaviour.get_module(agent)
      MyAgent

  """
  @spec get_module(Nous.Agent.t()) :: module()
  def get_module(%Nous.Agent{} = agent) do
    Map.get(agent, :behaviour_module) || default_module()
  end

  @doc """
  Get the default behaviour module.

  ## Examples

      iex> Behaviour.default_module()
      Nous.Agents.BasicAgent

  """
  @spec default_module() :: module()
  def default_module, do: Nous.Agents.BasicAgent

  @doc """
  Call a behaviour callback, using default if not implemented.

  ## Examples

      iex> Behaviour.call(MyAgent, :init_context, [agent, ctx], ctx)
      # Returns result of MyAgent.init_context(agent, ctx) or ctx if not implemented

  """
  @spec call(module(), atom(), list(), any()) :: any()
  def call(module, callback, args, default) do
    if function_exported?(module, callback, length(args)) do
      apply(module, callback, args)
    else
      default
    end
  end
end
