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

  @type operation ::
          {:set, atom(), any()}
          | {:merge, atom(), map()}
          | {:append, atom(), any()}
          | {:delete, atom()}

  @type t :: %__MODULE__{
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
  def new, do: %__MODULE__{}

  @doc """
  Set a key to a value in the context deps.

  Replaces any existing value for the key.

  ## Example

      ContextUpdate.new()
      |> ContextUpdate.set(:user_id, 123)

  """
  @spec set(t(), atom(), any()) :: t()
  def set(%__MODULE__{} = update, key, value) when is_atom(key) do
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
  def merge(%__MODULE__{} = update, key, map) when is_atom(key) and is_map(map) do
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
  def append(%__MODULE__{} = update, key, item) when is_atom(key) do
    %{update | operations: update.operations ++ [{:append, key, item}]}
  end

  @doc """
  Delete a key from context deps.

  ## Example

      ContextUpdate.new()
      |> ContextUpdate.delete(:temp_data)

  """
  @spec delete(t(), atom()) :: t()
  def delete(%__MODULE__{} = update, key) when is_atom(key) do
    %{update | operations: update.operations ++ [{:delete, key}]}
  end

  @doc """
  Apply all operations to a context, returning the updated context.

  Operations are applied in order.

  ## Example

      update = ContextUpdate.new()
      |> ContextUpdate.set(:key, "value")
      |> ContextUpdate.append(:list, "item")

      new_ctx = ContextUpdate.apply(update, ctx)

  """
  @spec apply(t(), Nous.Agent.Context.t()) :: Nous.Agent.Context.t()
  def apply(%__MODULE__{operations: ops}, %Nous.Agent.Context{} = ctx) do
    new_deps = reduce_operations(ops, ctx.deps || %{})

    keys =
      ops
      |> Enum.map(&op_key/1)
      |> Enum.uniq()

    :telemetry.execute(
      [:nous, :context, :update],
      %{keys_updated: length(keys)},
      %{agent_name: ctx.agent_name, keys: keys}
    )

    %{ctx | deps: new_deps}
  end

  defp op_key({_op, key, _value}), do: key
  defp op_key({_op, key}), do: key
  defp op_key(_), do: nil

  @doc """
  Apply all operations to a RunContext, returning the updated context.

  For backwards compatibility with tools using RunContext.
  """
  @spec apply_to_run_context(t(), Nous.RunContext.t()) :: Nous.RunContext.t()
  def apply_to_run_context(%__MODULE__{operations: ops}, %Nous.RunContext{} = ctx) do
    new_deps = reduce_operations(ops, ctx.deps || %{})
    %{ctx | deps: new_deps}
  end

  @doc """
  Check if this ContextUpdate has any operations.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{operations: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Get the list of operations in this update.
  """
  @spec operations(t()) :: [operation()]
  def operations(%__MODULE__{operations: ops}), do: ops

  # Private

  # Reduce operations into a deps map in a single pass. `:append` previously did
  # `existing ++ [item]` (O(n^2) over many appends to the same key); we prepend
  # and reverse each append-built key once at the end. `reversed` tracks keys
  # whose stored list is currently reversed — :set/:merge/:delete store
  # forward-order values and reset the flag, so a `:set [list]` then `:append`
  # still yields exact insertion order. Result is identical to the old reduce.
  defp reduce_operations(ops, initial) do
    {deps, reversed} =
      Enum.reduce(ops, {initial, MapSet.new()}, &apply_operation/2)

    Enum.reduce(reversed, deps, fn key, deps -> Map.update!(deps, key, &Enum.reverse/1) end)
  end

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
