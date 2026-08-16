defmodule Nous.Tool.ContextUpdate do
  @moduledoc """
  Structured context updates from tools.

  When tools need to update the agent's context (e.g., storing data for later use),
  they can return a ContextUpdate along with their result. This provides a clear,
  explicit way to modify context state without magic keys.

  ## Example

      defmodule MyTools do
        alias Nous.Tool.ContextUpdate

        def add_todo(ctx, %{"text" => text}) do
          todo = %{id: generate_id(), text: text, done: false}
          todos = [todo | ctx.deps[:todos] || []]

          {:ok, %{success: true, todo: todo},
           ContextUpdate.new() |> ContextUpdate.set(:todos, todos)}
        end

        def increment_counter(ctx, _args) do
          count = (ctx.deps[:counter] || 0) + 1

          {:ok, %{count: count},
           ContextUpdate.new() |> ContextUpdate.set(:counter, count)}
        end

        def add_note(ctx, %{"note" => note}) do
          {:ok, %{added: note},
           ContextUpdate.new() |> ContextUpdate.append(:notes, note)}
        end
      end

  ## Operations

  - `set/3` - Replace a key's value
  - `merge/3` - Deep merge a map into an existing map key
  - `append/3` - Append an item to a list key
  - `delete/2` - Remove a key
  - `log_event/3` - Record a bookkeeping session event (touches no deps)

  ## Integration

  The AgentRunner applies these updates to the context deps after tool execution:

      case execute_tool(tool, args, ctx) do
        {:ok, result, %ContextUpdate{} = update} ->
          new_ctx = ContextUpdate.apply(update, ctx)
          {:ok, result, new_ctx}

        {:ok, result} ->
          {:ok, result, ctx}
      end

  """

  alias __MODULE__

  require Logger

  @type operation ::
          {:set, atom(), any()}
          | {:merge, atom(), map()}
          | {:append, atom(), any()}
          | {:delete, atom()}
          | {:log_event, atom(), map()}

  @type t :: %ContextUpdate{
          operations: [operation()]
        }

  defstruct operations: []

  @doc """
  Create a new empty ContextUpdate.

  ## Example

      update = ContextUpdate.new()
      |> ContextUpdate.set(:key, "value")

  """
  @spec new() :: t()
  def new, do: %ContextUpdate{}

  @doc """
  Set a key to a value in the context deps.

  Replaces any existing value for the key.

  ## Example

      ContextUpdate.new()
      |> ContextUpdate.set(:user_id, 123)

  """
  @spec set(t(), atom(), any()) :: t()
  def set(%ContextUpdate{} = update, key, value) when is_atom(key) do
    %{update | operations: update.operations ++ [{:set, key, value}]}
  end

  @doc """
  Deep merge a map into an existing map key in context deps.

  If the key doesn't exist, it will be created with the map value.

  ## Example

      ContextUpdate.new()
      |> ContextUpdate.merge(:settings, %{theme: "dark"})

  """
  @spec merge(t(), atom(), map()) :: t()
  def merge(%ContextUpdate{} = update, key, map) when is_atom(key) and is_map(map) do
    %{update | operations: update.operations ++ [{:merge, key, map}]}
  end

  @doc """
  Append an item to a list key in context deps.

  If the key doesn't exist or is nil, creates a new list with the item.

  ## Example

      ContextUpdate.new()
      |> ContextUpdate.append(:history, %{action: "search", query: "elixir"})

  """
  @spec append(t(), atom(), any()) :: t()
  def append(%ContextUpdate{} = update, key, item) when is_atom(key) do
    %{update | operations: update.operations ++ [{:append, key, item}]}
  end

  @doc """
  Delete a key from context deps.

  ## Example

      ContextUpdate.new()
      |> ContextUpdate.delete(:temp_data)

  """
  @spec delete(t(), atom()) :: t()
  def delete(%ContextUpdate{} = update, key) when is_atom(key) do
    %{update | operations: update.operations ++ [{:delete, key}]}
  end

  @doc """
  Record a bookkeeping session event alongside this update.

  For a tool that did something auditable which must NOT enter the model's
  history — a sub-dispatch made from inside a code run, say. The event is
  appended to the session log through `Nous.Agent.Context.log_event/3`, which
  projects to no message, so `ctx.messages` is unchanged.

  `type` and `data` are the same pair `Nous.Agent.Context.log_event/3` takes: a
  bookkeeping `Nous.Session.Event` type and its payload. A surface type
  (`:user_message` and friends) is refused there, with a warning, so this
  cannot be used to smuggle content into the transcript.

  Only a `Nous.Agent.Context` has a log. Applied to a `Nous.RunContext` these
  operations are dropped — loudly; see `apply_to_run_context/2`.

  ## Example

      ContextUpdate.new()
      |> ContextUpdate.log_event(:tool_call, %{id: "sub_1", name: "file_read"})

  """
  @spec log_event(t(), atom(), map()) :: t()
  def log_event(%ContextUpdate{} = update, type, data) when is_atom(type) and is_map(data) do
    %{update | operations: update.operations ++ [{:log_event, type, data}]}
  end

  @doc """
  Apply all operations to a context, returning the updated context.

  Deps operations are applied first, in the order they were added, then
  `log_event/3` events are appended to the session log, also in order.
  `ctx.messages` is untouched: a bookkeeping event projects to no message,
  which is the whole point of recording a tool's side effect this way.

  ## Example

      update = ContextUpdate.new()
      |> ContextUpdate.set(:key, "value")
      |> ContextUpdate.append(:list, "item")
      |> ContextUpdate.log_event(:tool_call, %{name: "search"})

      new_ctx = ContextUpdate.apply(update, ctx)

  """
  @spec apply(t(), Nous.Agent.Context.t()) :: Nous.Agent.Context.t()
  def apply(%ContextUpdate{operations: ops} = update, %Nous.Agent.Context{} = ctx) do
    ctx = %{ctx | deps: to_deps(update, ctx.deps || %{})}

    keys =
      ops
      |> Enum.map(&op_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    :telemetry.execute(
      [:nous, :context, :update],
      %{keys_updated: length(keys)},
      %{agent_name: ctx.agent_name, keys: keys}
    )

    Enum.reduce(log_events(update), ctx, fn {type, data}, ctx ->
      Nous.Agent.Context.log_event(ctx, type, data)
    end)
  end

  # `:log_event` carries an event type, not a deps key. Reporting it as a key
  # would tell every telemetry handler that an update which touched no deps
  # updated one.
  defp op_key({:log_event, _type, _data}), do: nil
  defp op_key({_op, key, _value}), do: key
  defp op_key({_op, key}), do: key
  defp op_key(_), do: nil

  @doc """
  Apply all operations to a RunContext, returning the updated context.

  For backwards compatibility with tools using RunContext.

  **`log_event/3` operations are dropped here.** A `Nous.RunContext` carries
  deps and the run seam, not a session log, so there is nowhere for an event to
  go. The drop is logged at warning level naming the types lost, because a
  silently discarded audit record is worse than none: it looks like it worked.
  A tool whose events must survive has to run through `Nous.AgentRunner`, which
  applies the same update to a `Nous.Agent.Context`.
  """
  @spec apply_to_run_context(t(), Nous.RunContext.t()) :: Nous.RunContext.t()
  def apply_to_run_context(%ContextUpdate{} = update, %Nous.RunContext{} = ctx) do
    case log_events(update) do
      [] ->
        :ok

      events ->
        Logger.warning(
          "Nous.Tool.ContextUpdate: dropping #{length(events)} log event(s) " <>
            "#{inspect(Enum.map(events, &elem(&1, 0)))} — a Nous.RunContext has no session " <>
            "log. Deps operations were still applied."
        )
    end

    %{ctx | deps: to_deps(update, ctx.deps || %{})}
  end

  @doc """
  Check if this ContextUpdate has any operations.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%ContextUpdate{operations: []}), do: true
  def empty?(%ContextUpdate{}), do: false

  @doc """
  Get the list of operations in this update.
  """
  @spec operations(t()) :: [operation()]
  def operations(%ContextUpdate{operations: ops}), do: ops

  @doc """
  The `{type, data}` pairs added by `log_event/3`, in the order they were added.

  Deps operations are skipped. A caller that owns a session log uses this to
  append them; a caller that does not uses it to say exactly what it dropped.
  """
  @spec log_events(t()) :: [{atom(), map()}]
  def log_events(%ContextUpdate{operations: ops}) do
    for {:log_event, type, data} <- ops, do: {type, data}
  end

  @doc """
  Fold this update's deps operations into a map, starting from `initial`.

  This is the **single** reducer for `ContextUpdate` operations: `apply/2`,
  `apply_to_run_context/2` and `Nous.AgentRunner.ToolExecution` all fold
  through here, so an operation's meaning is defined in exactly one place.
  There used to be three hand-synchronised copies, and they had already drifted
  — the runner's did a shallow merge and could not see a new operation type at
  all.

  `:log_event` operations touch no deps and are skipped: only the caller knows
  whether it holds something with a log to put them in.

  ## Example

      update = ContextUpdate.new() |> ContextUpdate.append(:log, :b)
      ContextUpdate.to_deps(update, %{log: [:a]})
      #=> %{log: [:a, :b]}

  """
  # `:append` once did `existing ++ [item]`, which is O(n^2) over many appends
  # to the same key in one update. We prepend instead and reverse each
  # append-built key once at the end. `reversed` tracks the keys whose stored
  # list is currently reversed — :set/:merge/:delete store forward-order values
  # and clear the flag, so a `:set [list]` then `:append` (the only mixed case
  # that could get this wrong) still yields exact insertion order. The result is
  # byte-identical to the old `++` reduce; `context_update_test.exs` pins that
  # against a reference implementation of the old semantics.
  @spec to_deps(t(), map()) :: map()
  def to_deps(%ContextUpdate{operations: ops}, initial \\ %{}) do
    {deps, reversed} = Enum.reduce(ops, {initial, MapSet.new()}, &apply_operation/2)

    Enum.reduce(reversed, deps, fn key, deps -> Map.update!(deps, key, &Enum.reverse/1) end)
  end

  # Private

  defp apply_operation({:set, key, value}, {deps, reversed}) do
    {Map.put(deps, key, value), MapSet.delete(reversed, key)}
  end

  defp apply_operation({:merge, key, map}, {deps, reversed}) do
    existing = Map.get(deps, key, %{})
    {Map.put(deps, key, deep_merge(existing, map)), MapSet.delete(reversed, key)}
  end

  defp apply_operation({:append, key, item}, {deps, reversed}) do
    if MapSet.member?(reversed, key) do
      {Map.update!(deps, key, &[item | &1]), reversed}
    else
      existing = Map.get(deps, key) || []
      {Map.put(deps, key, [item | Enum.reverse(existing)]), MapSet.put(reversed, key)}
    end
  end

  defp apply_operation({:delete, key}, {deps, reversed}) do
    {Map.delete(deps, key), MapSet.delete(reversed, key)}
  end

  # `:log_event` records a session event, not a deps key, so the fold ignores
  # it. Deliberately an explicit clause and not a catch-all: the next operation
  # type added must fail loudly here rather than vanish, which is exactly the
  # defect that used to swallow events on the tool path.
  defp apply_operation({:log_event, _type, _data}, acc), do: acc

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp deep_merge(_left, right), do: right
end
