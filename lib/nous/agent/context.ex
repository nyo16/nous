defmodule Nous.Agent.Context do
  @moduledoc """
  Unified context for agent execution.

  Accumulates state across the agent loop:
  - Conversation messages
  - Tool call history
  - Usage tracking
  - User dependencies
  - Callbacks configuration

  ## Example

      # Create new context
      ctx = Context.new(
        system_prompt: "You are helpful",
        deps: %{database: MyDB},
        max_iterations: 15
      )

      # Add messages
      ctx = ctx
      |> Context.add_message(Message.user("Hello"))
      |> Context.add_message(Message.assistant("Hi there!"))

      # Check loop control
      if ctx.needs_response do
        # Continue execution
      end

  ## Callbacks

  Callbacks can be configured as a map of event handlers:

      ctx = Context.new(callbacks: %{
        on_llm_new_delta: fn _event, delta -> IO.write(delta) end,
        on_tool_call: fn _event, call -> IO.inspect(call) end
      })

  ## Process Notification

  For LiveView integration, set `notify_pid`:

      ctx = Context.new(notify_pid: self())
      # Will receive: {:agent_delta, text}, {:tool_call, call}, etc.

  """

  alias Nous.{Message, Usage}

  @type callback_fn :: (atom(), any() -> any())

  @type t :: %__MODULE__{
          # Conversation
          messages: [Message.t()],
          tool_calls: [map()],
          system_prompt: String.t() | nil,

          # State
          deps: map(),
          usage: Usage.t(),

          # Loop control
          needs_response: boolean(),
          iteration: non_neg_integer(),
          max_iterations: non_neg_integer(),

          # Events
          callbacks: %{optional(atom()) => callback_fn()},
          notify_pid: pid() | nil,

          # Metadata
          started_at: DateTime.t() | nil,
          agent_name: String.t() | nil,

          # Cancellation
          cancellation_check: (-> :ok | {:error, term()}) | nil,

          # Human-in-the-loop
          approval_handler: (map() -> :approve | {:edit, map()} | :reject) | nil
        }

  defstruct messages: [],
            tool_calls: [],
            system_prompt: nil,
            deps: %{},
            usage: %Usage{},
            needs_response: true,
            iteration: 0,
            max_iterations: 10,
            callbacks: %{},
            notify_pid: nil,
            started_at: nil,
            agent_name: nil,
            cancellation_check: nil,
            approval_handler: nil

  @doc """
  Create a new context with options.

  ## Options

    * `:messages` - Initial message list (default: [])
    * `:system_prompt` - System prompt string
    * `:deps` - User dependencies map (default: %{})
    * `:max_iterations` - Maximum loop iterations (default: 10)
    * `:callbacks` - Map of callback functions
    * `:notify_pid` - PID to receive event messages
    * `:agent_name` - Name for telemetry/logging
    * `:cancellation_check` - Function to check for cancellation
    * `:approval_handler` - Function called for tools with `requires_approval: true`

  ## Examples

      iex> ctx = Context.new(system_prompt: "Be helpful", max_iterations: 5)
      iex> ctx.max_iterations
      5

      iex> ctx = Context.new(deps: %{user_id: 123})
      iex> ctx.deps.user_id
      123

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      messages: Keyword.get(opts, :messages, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      deps: Keyword.get(opts, :deps, %{}),
      usage: Keyword.get(opts, :usage, Usage.new()),
      needs_response: Keyword.get(opts, :needs_response, true),
      iteration: Keyword.get(opts, :iteration, 0),
      max_iterations: Keyword.get(opts, :max_iterations, 10),
      callbacks: Keyword.get(opts, :callbacks, %{}),
      notify_pid: Keyword.get(opts, :notify_pid),
      started_at: DateTime.utc_now(),
      agent_name: Keyword.get(opts, :agent_name),
      cancellation_check: Keyword.get(opts, :cancellation_check),
      approval_handler: Keyword.get(opts, :approval_handler)
    }
  end

  @doc """
  Add a message to the context.

  Automatically updates `needs_response` based on message role and content.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Context.add_message(ctx, Message.user("Hello"))
      iex> length(ctx.messages)
      1

  """
  @spec add_message(t(), Message.t()) :: t()
  def add_message(%__MODULE__{} = ctx, %Message{} = message) do
    updated_messages = ctx.messages ++ [message]

    %{ctx | messages: updated_messages}
    |> update_needs_response(message)
  end

  @doc """
  Add multiple messages to the context.

  ## Examples

      iex> ctx = Context.new()
      iex> messages = [Message.user("Hi"), Message.assistant("Hello")]
      iex> ctx = Context.add_messages(ctx, messages)
      iex> length(ctx.messages)
      2

  """
  @spec add_messages(t(), [Message.t()]) :: t()
  def add_messages(%__MODULE__{} = ctx, messages) when is_list(messages) do
    Enum.reduce(messages, ctx, &add_message(&2, &1))
  end

  @doc """
  Record a tool call in the context.

  ## Examples

      iex> ctx = Context.new()
      iex> call = %{id: "call_123", name: "search", arguments: %{"q" => "test"}}
      iex> ctx = Context.add_tool_call(ctx, call)
      iex> length(ctx.tool_calls)
      1

  """
  @spec add_tool_call(t(), map()) :: t()
  def add_tool_call(%__MODULE__{} = ctx, call) when is_map(call) do
    %{ctx | tool_calls: ctx.tool_calls ++ [call]}
  end

  @doc """
  Merge usage statistics into the context.

  ## Examples

      iex> ctx = Context.new()
      iex> usage = %Usage{input_tokens: 100, output_tokens: 50}
      iex> ctx = Context.add_usage(ctx, usage)
      iex> ctx.usage.input_tokens
      100

  """
  @spec add_usage(t(), Usage.t() | map()) :: t()
  def add_usage(%__MODULE__{} = ctx, %Usage{} = usage) do
    new_usage = Usage.add(ctx.usage, usage)
    %{ctx | usage: new_usage}
  end

  def add_usage(%__MODULE__{} = ctx, usage) when is_map(usage) do
    # Convert map to Usage struct, handling partial updates
    usage_struct = %Usage{
      requests: Map.get(usage, :requests, 0),
      tool_calls: Map.get(usage, :tool_calls, 0),
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      total_tokens: Map.get(usage, :total_tokens, 0)
    }

    new_usage = Usage.add(ctx.usage, usage_struct)
    %{ctx | usage: new_usage}
  end

  @doc """
  Merge new dependencies into the context.

  Used by tools to update context state via `__update_context__` or `ContextUpdate`.

  ## Examples

      iex> ctx = Context.new(deps: %{count: 0})
      iex> ctx = Context.merge_deps(ctx, %{count: 1, new_key: "value"})
      iex> ctx.deps.count
      1
      iex> ctx.deps.new_key
      "value"

  """
  @spec merge_deps(t(), map()) :: t()
  def merge_deps(%__MODULE__{} = ctx, new_deps) when is_map(new_deps) do
    merged = Map.merge(ctx.deps || %{}, new_deps)
    %{ctx | deps: merged}
  end

  @doc """
  Increment the iteration counter.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Context.increment_iteration(ctx)
      iex> ctx.iteration
      1

  """
  @spec increment_iteration(t()) :: t()
  def increment_iteration(%__MODULE__{} = ctx) do
    %{ctx | iteration: ctx.iteration + 1}
  end

  @doc """
  Set needs_response flag explicitly.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Context.set_needs_response(ctx, false)
      iex> ctx.needs_response
      false

  """
  @spec set_needs_response(t(), boolean()) :: t()
  def set_needs_response(%__MODULE__{} = ctx, value) when is_boolean(value) do
    %{ctx | needs_response: value}
  end

  @doc """
  Check if maximum iterations has been reached.

  ## Examples

      iex> ctx = Context.new(max_iterations: 5, iteration: 5)
      iex> Context.max_iterations_reached?(ctx)
      true

      iex> ctx = Context.new(max_iterations: 5, iteration: 3)
      iex> Context.max_iterations_reached?(ctx)
      false

  """
  @spec max_iterations_reached?(t()) :: boolean()
  def max_iterations_reached?(%__MODULE__{iteration: i, max_iterations: max}) do
    i >= max
  end

  @doc """
  Get the last message from the context.

  ## Examples

      iex> ctx = Context.new() |> Context.add_message(Message.user("Hello"))
      iex> Context.last_message(ctx).content
      "Hello"

      iex> ctx = Context.new()
      iex> Context.last_message(ctx)
      nil

  """
  @spec last_message(t()) :: Message.t() | nil
  def last_message(%__MODULE__{messages: []}), do: nil
  def last_message(%__MODULE__{messages: messages}), do: List.last(messages)

  @doc """
  Get all assistant messages from the context.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = ctx |> Context.add_message(Message.user("Hi"))
      iex> ctx = ctx |> Context.add_message(Message.assistant("Hello"))
      iex> length(Context.assistant_messages(ctx))
      1

  """
  @spec assistant_messages(t()) :: [Message.t()]
  def assistant_messages(%__MODULE__{messages: messages}) do
    Enum.filter(messages, &(&1.role == :assistant))
  end

  @doc """
  Convert to RunContext for tool execution (backwards compatibility).

  This allows tools to continue using the existing RunContext interface.

  ## Examples

      iex> ctx = Context.new(deps: %{db: :postgres})
      iex> run_ctx = Context.to_run_context(ctx)
      iex> run_ctx.deps.db
      :postgres

  """
  @spec to_run_context(t()) :: Nous.RunContext.t()
  def to_run_context(%__MODULE__{} = ctx) do
    Nous.RunContext.new(ctx.deps, usage: ctx.usage)
  end

  @doc """
  Create context from an existing RunContext (migration helper).

  ## Examples

      iex> run_ctx = Nous.RunContext.new(%{key: "value"})
      iex> ctx = Context.from_run_context(run_ctx)
      iex> ctx.deps.key
      "value"

  """
  @spec from_run_context(Nous.RunContext.t(), keyword()) :: t()
  def from_run_context(%Nous.RunContext{} = run_ctx, opts \\ []) do
    new(
      Keyword.merge(opts,
        deps: run_ctx.deps,
        usage: run_ctx.usage
      )
    )
  end

  @doc """
  Patch dangling tool calls in the conversation.

  Scans messages for assistant messages with tool_calls that have no
  corresponding tool result message. Injects synthetic tool results
  for unmatched calls with a message indicating the call was interrupted.

  This is critical when resuming from a persisted context where the
  session was interrupted mid-tool-execution.

  ## Examples

      iex> ctx = Context.new(messages: [
      ...>   Message.assistant("Let me search", tool_calls: [%{id: "call_1", name: "search"}])
      ...> ])
      iex> ctx = Context.patch_dangling_tool_calls(ctx)
      iex> length(ctx.messages)
      2

  """
  @spec patch_dangling_tool_calls(t()) :: t()
  def patch_dangling_tool_calls(%__MODULE__{messages: messages} = ctx) do
    # Collect all tool_call IDs from assistant messages
    tool_call_ids =
      messages
      |> Enum.filter(&(&1.role == :assistant))
      |> Enum.flat_map(fn msg ->
        (msg.tool_calls || [])
        |> Enum.map(fn call ->
          Map.get(call, :id) || Map.get(call, "id")
        end)
        |> Enum.reject(&is_nil/1)
      end)
      |> MapSet.new()

    # Collect all tool result IDs
    tool_result_ids =
      messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(& &1.tool_call_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    # Find unmatched tool calls
    dangling_ids = MapSet.difference(tool_call_ids, tool_result_ids)

    if MapSet.size(dangling_ids) == 0 do
      ctx
    else
      # Inject synthetic tool results for dangling calls
      synthetic_results =
        Enum.map(dangling_ids, fn id ->
          Message.tool(id, "Tool call was interrupted and not executed. Please retry if needed.")
        end)

      %{ctx | messages: messages ++ synthetic_results}
    end
  end

  # Serialization

  @doc """
  Serialize context to a JSON-encodable map.

  Persists messages, usage, metadata. Never persists functions, PIDs, or modules.
  Includes a `version` field for future migrations.

  ## Examples

      iex> ctx = Context.new(system_prompt: "Be helpful", max_iterations: 5)
      iex> data = Context.serialize(ctx)
      iex> data.version
      1
      iex> data.system_prompt
      "Be helpful"

  """
  @spec serialize(t()) :: map()
  def serialize(%__MODULE__{} = ctx) do
    %{
      version: 1,
      messages: Enum.map(ctx.messages, &serialize_message/1),
      tool_calls: ctx.tool_calls,
      system_prompt: ctx.system_prompt,
      deps: serialize_deps(ctx.deps),
      usage: serialize_usage(ctx.usage),
      needs_response: ctx.needs_response,
      iteration: ctx.iteration,
      max_iterations: ctx.max_iterations,
      started_at: ctx.started_at && DateTime.to_iso8601(ctx.started_at),
      agent_name: ctx.agent_name
    }
  end

  @doc """
  Deserialize a map back into a Context struct.

  Handles version migrations and restores messages, usage, and metadata.
  Functions, PIDs, and callbacks are not restored and will use defaults.

  Returns `{:ok, context}` or `{:error, reason}`.

  ## Examples

      iex> ctx = Context.new(system_prompt: "Be helpful")
      iex> data = Context.serialize(ctx)
      iex> {:ok, restored} = Context.deserialize(data)
      iex> restored.system_prompt
      "Be helpful"

  """
  @spec deserialize(map()) :: {:ok, t()} | {:error, term()}
  def deserialize(%{version: 1} = data) do
    do_deserialize(data)
  end

  def deserialize(%{"version" => 1} = data) do
    data
    |> atomize_keys()
    |> do_deserialize()
  end

  def deserialize(%{version: v}) when is_integer(v) do
    {:error, "unsupported version: #{v}"}
  end

  def deserialize(%{"version" => v}) when is_integer(v) do
    {:error, "unsupported version: #{v}"}
  end

  def deserialize(_data) do
    {:error, "missing or invalid version field"}
  end

  # Private functions

  defp do_deserialize(data) do
    messages =
      (data[:messages] || [])
      |> Enum.map(&deserialize_message/1)

    usage = deserialize_usage(data[:usage] || %{})

    started_at =
      case data[:started_at] do
        nil ->
          nil

        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _offset} -> dt
            _ -> nil
          end
      end

    ctx = %__MODULE__{
      messages: messages,
      tool_calls: data[:tool_calls] || [],
      system_prompt: data[:system_prompt],
      deps: data[:deps] || %{},
      usage: usage,
      needs_response: data[:needs_response] || false,
      iteration: data[:iteration] || 0,
      max_iterations: data[:max_iterations] || 10,
      started_at: started_at,
      agent_name: data[:agent_name],
      callbacks: %{},
      notify_pid: nil,
      cancellation_check: nil,
      approval_handler: nil
    }

    {:ok, ctx}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp serialize_message(%Message{} = msg) do
    %{
      role: msg.role,
      content: msg.content,
      tool_calls: msg.tool_calls,
      tool_call_id: msg.tool_call_id,
      name: msg.name,
      metadata: msg.metadata
    }
  end

  defp deserialize_message(data) when is_map(data) do
    data = atomize_keys(data)

    role =
      case data[:role] do
        r when is_atom(r) -> r
        r when is_binary(r) -> String.to_existing_atom(r)
      end

    attrs = %{
      role: role,
      content: data[:content],
      tool_calls: data[:tool_calls] || [],
      tool_call_id: data[:tool_call_id],
      name: data[:name],
      metadata: data[:metadata] || %{}
    }

    Message.new!(attrs)
  end

  defp serialize_usage(%Usage{} = usage) do
    %{
      requests: usage.requests,
      tool_calls: usage.tool_calls,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens
    }
  end

  defp serialize_deps(deps) when is_map(deps) do
    deps
    |> Enum.reject(fn {_k, v} -> is_function(v) or is_pid(v) or is_port(v) end)
    |> Map.new()
  end

  defp serialize_deps(_), do: %{}

  defp deserialize_usage(data) when is_map(data) do
    data = atomize_keys(data)

    %Usage{
      requests: data[:requests] || 0,
      tool_calls: data[:tool_calls] || 0,
      input_tokens: data[:input_tokens] || 0,
      output_tokens: data[:output_tokens] || 0,
      total_tokens: data[:total_tokens] || 0
    }
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  defp update_needs_response(ctx, %Message{role: :assistant} = message) do
    # Assistant messages with tool calls need a response (tool results)
    # Assistant messages without tool calls don't need a response (final answer)
    has_tool_calls = Message.has_tool_calls?(message)
    %{ctx | needs_response: has_tool_calls}
  end

  defp update_needs_response(ctx, %Message{role: :tool}) do
    # Tool result messages always need a response from the model
    %{ctx | needs_response: true}
  end

  defp update_needs_response(ctx, %Message{role: :user}) do
    # User messages always need a response
    %{ctx | needs_response: true}
  end

  defp update_needs_response(ctx, _message) do
    # System messages don't change needs_response
    ctx
  end
end
