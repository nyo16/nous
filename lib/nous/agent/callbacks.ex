defmodule Nous.Agent.Callbacks do
  @moduledoc """
  Callback execution for agent events.

  Supports two notification mechanisms:
  1. **Map-based callbacks** - Functions in the context's callbacks map
  2. **Process messages** - Messages sent to the context's notify_pid

  ## Callback Events

  - `:on_agent_start` - Agent run begins
  - `:on_llm_new_delta` - Streaming text chunk received
  - `:on_llm_new_message` - Complete LLM response received
  - `:on_tool_call` - Tool invocation started
  - `:on_tool_response` - Tool execution completed
  - `:on_agent_complete` - Agent run finished successfully
  - `:on_error` - Error occurred during execution

  ## Map-Based Callbacks

  Configure callbacks as a map of event handlers:

      ctx = Context.new(callbacks: %{
        on_llm_new_delta: fn _event, delta -> IO.write(delta) end,
        on_tool_call: fn _event, call -> IO.inspect(call, label: "Tool") end
      })

  Callback functions receive `(event_name, payload)` and their return values
  are discarded (side-effects only).

  ## Process Messages

  For LiveView integration, set `notify_pid`:

      ctx = Context.new(notify_pid: self())
      # Will receive messages like:
      # {:agent_delta, text}
      # {:tool_call, %{id: ..., name: ..., arguments: ...}}
      # {:agent_complete, result}

  ## Example

      alias Nous.Agent.{Context, Callbacks}

      # Execute callback (safe - handles missing callbacks)
      Callbacks.execute(ctx, :on_llm_new_delta, "Hello")

      # Execute with metadata
      Callbacks.execute(ctx, :on_tool_call, %{
        id: "call_123",
        name: "search",
        arguments: %{"query" => "elixir"}
      })

  """

  alias Nous.Agent.Context

  @type event ::
          :on_agent_start
          | :on_llm_new_delta
          | :on_llm_new_message
          | :on_tool_call
          | :on_tool_response
          | :on_agent_complete
          | :on_error

  @type payload :: any()

  @events [
    :on_agent_start,
    :on_llm_new_delta,
    :on_llm_new_message,
    :on_tool_call,
    :on_tool_response,
    :on_agent_complete,
    :on_error
  ]

  @doc """
  List of all supported callback events.

  ## Events

  - `:on_agent_start` - Payload: `%{agent: agent}`
  - `:on_llm_new_delta` - Payload: `String.t()` (text chunk)
  - `:on_llm_new_message` - Payload: `Message.t()`
  - `:on_tool_call` - Payload: `%{id: String.t(), name: String.t(), arguments: map()}`
  - `:on_tool_response` - Payload: `%{id: String.t(), name: String.t(), result: any()}`
  - `:on_agent_complete` - Payload: result map
  - `:on_error` - Payload: error term

  ## Examples

      iex> Callbacks.events()
      [:on_agent_start, :on_llm_new_delta, :on_llm_new_message, ...]

  """
  @spec events() :: [event()]
  def events, do: @events

  @doc """
  Execute a callback for the given event.

  This function:
  1. Invokes the map-based callback if present in `ctx.callbacks`
  2. Sends a process message if `ctx.notify_pid` is set

  Safe to call even if no callbacks are configured.

  ## Parameters

    * `ctx` - The agent context
    * `event` - The event name (atom)
    * `payload` - Event-specific data

  ## Examples

      iex> ctx = Context.new(callbacks: %{on_llm_new_delta: fn _, d -> IO.write(d) end})
      iex> Callbacks.execute(ctx, :on_llm_new_delta, "Hello")
      :ok

      iex> ctx = Context.new(notify_pid: self())
      iex> Callbacks.execute(ctx, :on_llm_new_delta, "Hello")
      iex> receive do {:agent_delta, text} -> text end
      "Hello"

  """
  @spec execute(Context.t(), event(), payload()) :: :ok
  def execute(%Context{} = ctx, event, payload) when is_atom(event) do
    # 1. Execute map-based callback if present
    execute_callback(ctx.callbacks, event, payload)

    # 2. Send process message if pid configured
    send_notification(ctx.notify_pid, event, payload)

    # 3. Broadcast via PubSub if configured
    broadcast_event(ctx, event, payload)

    :ok
  end

  @doc """
  Execute multiple events in sequence.

  ## Examples

      iex> Callbacks.execute_many(ctx, [
      ...>   {:on_tool_call, %{id: "1", name: "search"}},
      ...>   {:on_tool_response, %{id: "1", result: "found"}}
      ...> ])
      :ok

  """
  @spec execute_many(Context.t(), [{event(), payload()}]) :: :ok
  def execute_many(%Context{} = ctx, events) when is_list(events) do
    Enum.each(events, fn {event, payload} ->
      execute(ctx, event, payload)
    end)
  end

  @doc """
  Check if a specific callback is configured.

  ## Examples

      iex> ctx = Context.new(callbacks: %{on_llm_new_delta: fn _, _ -> :ok end})
      iex> Callbacks.has_callback?(ctx, :on_llm_new_delta)
      true

      iex> ctx = Context.new()
      iex> Callbacks.has_callback?(ctx, :on_llm_new_delta)
      false

  """
  @spec has_callback?(Context.t(), event()) :: boolean()
  def has_callback?(%Context{callbacks: callbacks}, event) do
    is_function(Map.get(callbacks, event))
  end

  @doc """
  Check if process notification is enabled.

  ## Examples

      iex> ctx = Context.new(notify_pid: self())
      iex> Callbacks.has_notification?(ctx)
      true

      iex> ctx = Context.new()
      iex> Callbacks.has_notification?(ctx)
      false

  """
  @spec has_notification?(Context.t()) :: boolean()
  def has_notification?(%Context{notify_pid: pid}) do
    is_pid(pid)
  end

  @doc """
  Add a callback to the context.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Callbacks.put_callback(ctx, :on_llm_new_delta, fn _, d -> IO.write(d) end)
      iex> Callbacks.has_callback?(ctx, :on_llm_new_delta)
      true

  """
  @spec put_callback(Context.t(), event(), function()) :: Context.t()
  def put_callback(%Context{} = ctx, event, callback)
      when is_atom(event) and is_function(callback, 2) do
    %{ctx | callbacks: Map.put(ctx.callbacks, event, callback)}
  end

  @doc """
  Remove a callback from the context.

  ## Examples

      iex> ctx = Context.new(callbacks: %{on_llm_new_delta: fn _, _ -> :ok end})
      iex> ctx = Callbacks.remove_callback(ctx, :on_llm_new_delta)
      iex> Callbacks.has_callback?(ctx, :on_llm_new_delta)
      false

  """
  @spec remove_callback(Context.t(), event()) :: Context.t()
  def remove_callback(%Context{} = ctx, event) when is_atom(event) do
    %{ctx | callbacks: Map.delete(ctx.callbacks, event)}
  end

  @doc """
  Set the notification PID.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Callbacks.set_notify_pid(ctx, self())
      iex> Callbacks.has_notification?(ctx)
      true

  """
  @spec set_notify_pid(Context.t(), pid() | nil) :: Context.t()
  def set_notify_pid(%Context{} = ctx, pid) when is_pid(pid) or is_nil(pid) do
    %{ctx | notify_pid: pid}
  end

  # Private functions

  defp execute_callback(callbacks, event, payload) when is_map(callbacks) do
    case Map.get(callbacks, event) do
      callback when is_function(callback, 2) ->
        try do
          callback.(event, payload)
        rescue
          e ->
            # Log but don't fail on callback errors
            require Logger
            Logger.warning("Callback error for #{event}: #{inspect(e)}")
        end

      _ ->
        :ok
    end
  end

  defp execute_callback(_, _, _), do: :ok

  defp send_notification(nil, _event, _payload), do: :ok

  defp send_notification(pid, event, payload) when is_pid(pid) do
    message = to_message(event, payload)
    send(pid, message)
    :ok
  end

  @doc """
  Convert an event to a process message format.

  This is used internally but exposed for testing.

  ## Message Format

  | Event | Message |
  |-------|---------|
  | `:on_agent_start` | `{:agent_start, payload}` |
  | `:on_llm_new_delta` | `{:agent_delta, text}` |
  | `:on_llm_new_message` | `{:agent_message, message}` |
  | `:on_tool_call` | `{:tool_call, %{id, name, arguments}}` |
  | `:on_tool_response` | `{:tool_result, %{id, name, result}}` |
  | `:on_agent_complete` | `{:agent_complete, result}` |
  | `:on_error` | `{:agent_error, error}` |

  ## Examples

      iex> Callbacks.to_message(:on_llm_new_delta, "Hello")
      {:agent_delta, "Hello"}

      iex> Callbacks.to_message(:on_tool_call, %{id: "1", name: "search"})
      {:tool_call, %{id: "1", name: "search"}}

  """
  @spec to_message(event(), payload()) :: tuple()
  def to_message(:on_agent_start, payload), do: {:agent_start, payload}
  def to_message(:on_llm_new_delta, text), do: {:agent_delta, text}
  def to_message(:on_llm_new_message, message), do: {:agent_message, message}
  def to_message(:on_tool_call, call), do: {:tool_call, call}
  def to_message(:on_tool_response, result), do: {:tool_result, result}
  def to_message(:on_agent_complete, result), do: {:agent_complete, result}
  def to_message(:on_error, error), do: {:agent_error, error}
  def to_message(event, payload), do: {event, payload}

  defp broadcast_event(%Context{pubsub: nil}, _event, _payload), do: :ok
  defp broadcast_event(%Context{pubsub_topic: nil}, _event, _payload), do: :ok

  defp broadcast_event(%Context{pubsub: pubsub, pubsub_topic: topic}, event, payload) do
    message = to_message(event, payload)
    Nous.PubSub.broadcast(pubsub, topic, message)
  end
end
