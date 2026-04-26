defmodule Nous.Persistence.ETS do
  @moduledoc """
  ETS-based persistence backend.

  Stores serialized context data in a named ETS table. The table is owned
  by a dedicated GenServer (`Nous.Persistence.ETS.TableOwner`) started
  under the Nous application supervisor, so the table outlives transient
  callers - previously the table died with whichever process happened to
  call save/load first.

  Data does not survive node restarts. Useful for development, testing,
  and short-lived sessions.

  ## Usage

      # In AgentServer config
      AgentServer.start_link(
        session_id: "session_123",
        agent_config: %{model: "openai:gpt-4", instructions: "Be helpful"},
        persistence: Nous.Persistence.ETS
      )

  """

  @behaviour Nous.Persistence

  @table :nous_persistence

  defmodule TableOwner do
    @moduledoc false
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    @impl true
    def init(:ok) do
      table_name = :nous_persistence

      table =
        case :ets.whereis(table_name) do
          :undefined ->
            :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])

          _ref ->
            table_name
        end

      {:ok, %{table: table}}
    end
  end

  @doc false
  def child_spec(_opts) do
    %{id: __MODULE__, start: {TableOwner, :start_link, [[]]}, type: :worker}
  end

  @impl true
  def save(session_id, data) when is_binary(session_id) and is_map(data) do
    ensure_table()

    try do
      true = :ets.insert(@table, {session_id, data})
      :ok
    rescue
      e -> {:error, {:ets_insert_failed, Exception.message(e)}}
    end
  end

  @impl true
  def load(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  @impl true
  def list do
    ensure_table()
    keys = :ets.foldl(fn {key, _val}, acc -> [key | acc] end, [], @table)
    {:ok, keys}
  end

  # Fallback for callers used before the supervisor started the owner
  # (mainly ad-hoc tests). Production code goes through TableOwner.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError ->
            # Another process created the table between whereis and new
            :ok
        end

      _ref ->
        :ok
    end
  end
end
