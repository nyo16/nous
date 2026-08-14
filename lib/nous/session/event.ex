defmodule Nous.Session.Event do
  @moduledoc """
  One durable fact about a session.

  Events are append-only. Nothing is ever mutated or deleted: a compaction
  appends a *replace* that shadows a range, and the shadowed events stay in the
  log where fork, rewind and audit can still see them.

  ## Identity lives here, not on `Nous.Message`

  `%Nous.Message{}` declares `@primary_key false` — messages genuinely have no
  identity, and adding one would change a public struct that
  `Nous.run/3` hands back. The event carries `seq`; messages are projected fresh
  from the log every time. That is what lets the log be internal while
  `result.messages` stays byte-identical.

  ## Surface and non-surface types

  Only four types project into the model-visible surface, and only those may
  carry a `:surface_op`:

    * `:system_message`, `:user_message`, `:assistant_message`, `:tool_result`

  Everything else is bookkeeping the model never sees — `:tool_call`,
  `:turn_start`, `:turn_end`, `:step_start`, `:step_end`, `:request_header`. They
  are logged because they are what makes a run reconstructable, but
  `Nous.Session.Log.derive_messages/1` projects them to nothing.

  > #### Why four and not three {: .info}
  >
  > The plan specified exactly three surface types, on the assumption that system
  > content is assembly-time state rather than history. That assumption does not
  > survive contact with the code: `Nous.Plugins.Summarization` appends its
  > summary as a **system** message mid-conversation, and
  > `Nous.AgentRunner.build_initial_messages/3` puts one at the head. A system
  > message is therefore a real, ordered part of the transcript and needs a
  > surface type. The *rewrite* of the system prompt in
  > `Nous.AgentRunner.PromptAssembly` stays assembly-time and is deliberately not
  > an event — see that module.
  """

  alias __MODULE__

  @typedoc """
  How this event contributes to the model-visible surface.

  `:append` adds it at the end. `{:replace, start_seq, stop_seq}` additionally
  shadows every surface event in that inclusive `seq` range — the mechanism
  behind non-destructive compaction.
  """
  @type surface_op :: :append | {:replace, non_neg_integer(), non_neg_integer()}

  @type type ::
          :system_message
          | :user_message
          | :assistant_message
          | :tool_result
          | :tool_call
          | :turn_start
          | :turn_end
          | :step_start
          | :step_end
          | :request_header

  @type t :: %Event{
          seq: non_neg_integer(),
          type: type(),
          time: DateTime.t(),
          data: map()
        }

  @enforce_keys [:seq, :type, :time, :data]
  defstruct [:seq, :type, :time, :data]

  @surface_types [:system_message, :user_message, :assistant_message, :tool_result]

  @bookkeeping_types [
    :tool_call,
    :turn_start,
    :turn_end,
    :step_start,
    :step_end,
    :request_header
  ]

  @types @surface_types ++ @bookkeeping_types

  @doc """
  Every valid event type.
  """
  @spec types() :: [type()]
  def types, do: @types

  @doc """
  The types that project into the model-visible surface.

  ## Examples

      iex> Nous.Session.Event.surface_types()
      [:system_message, :user_message, :assistant_message, :tool_result]

  """
  @spec surface_types() :: [type()]
  def surface_types, do: @surface_types

  @doc """
  Whether this event contributes to the model-visible surface.

  ## Examples

      iex> Nous.Session.Event.surface?(:assistant_message)
      true

      iex> Nous.Session.Event.surface?(:step_start)
      false

  """
  @spec surface?(type() | t()) :: boolean()
  def surface?(%Event{type: type}), do: surface?(type)
  def surface?(type) when is_atom(type), do: type in @surface_types

  @doc """
  Build an event, validating type, data shape and `:surface_op`.

  Validation happens **here, at append time**, not at persist time. An event that
  cannot be serialized is a bug in the caller, and discovering it hours later
  when a session is saved makes it someone else's bug.

  Returns `{:error, reason}` rather than raising: an event that fails validation
  must not take down a live agent run.
  """
  @spec new(non_neg_integer(), type(), map(), DateTime.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def new(seq, type, data, time \\ nil)

  def new(seq, type, data, time) when is_integer(seq) and seq >= 0 and is_map(data) do
    with :ok <- validate_type(type),
         :ok <- validate_surface_op(type, data),
         :ok <- validate_serializable(data) do
      {:ok, %Event{seq: seq, type: type, time: time || DateTime.utc_now(), data: data}}
    end
  end

  def new(seq, type, data, _time) do
    {:error, {:invalid_event, seq: seq, type: type, data_is_map: is_map(data)}}
  end

  @doc """
  The `:surface_op` this event carries. `:append` unless it says otherwise.
  """
  @spec surface_op(t()) :: surface_op()
  def surface_op(%Event{data: data}), do: Map.get(data, :surface_op, :append)

  # ---------------------------------------------------------------------------

  defp validate_type(type) when type in @types, do: :ok
  defp validate_type(other), do: {:error, {:unknown_event_type, other}}

  defp validate_surface_op(type, data) do
    case Map.get(data, :surface_op) do
      nil ->
        :ok

      _op when type not in @surface_types ->
        # A replace on a bookkeeping event would shadow surface events from
        # something the surface cannot see, which no fold could explain.
        {:error, {:surface_op_on_non_surface_event, type}}

      :append ->
        :ok

      {:replace, start, stop}
      when is_integer(start) and is_integer(stop) and start >= 0 and stop >= start ->
        :ok

      other ->
        {:error, {:invalid_surface_op, other}}
    end
  end

  # Cheap structural check for the things that actually break persistence: pids,
  # references, ports and functions are alive-process handles that cannot survive
  # a restart, and a log holding one is a log that cannot be reloaded.
  defp validate_serializable(data) do
    case find_unserializable(data) do
      nil -> :ok
      term -> {:error, {:unserializable_event_data, term}}
    end
  end

  defp find_unserializable(term)
       when is_pid(term) or is_reference(term) or is_port(term) or is_function(term),
       do: term

  defp find_unserializable(%_struct{} = struct) do
    struct |> Map.from_struct() |> find_unserializable()
  end

  defp find_unserializable(map) when is_map(map) do
    Enum.find_value(map, fn {key, value} ->
      find_unserializable(key) || find_unserializable(value)
    end)
  end

  defp find_unserializable(list) when is_list(list) do
    Enum.find_value(list, &find_unserializable/1)
  end

  defp find_unserializable(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> find_unserializable()
  end

  defp find_unserializable(_ok), do: nil
end
