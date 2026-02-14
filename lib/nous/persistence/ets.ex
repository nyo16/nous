defmodule Nous.Persistence.ETS do
  @moduledoc """
  ETS-based persistence backend.

  Stores serialized context data in a named ETS table. The table is created
  lazily on first use. Data does not survive process restarts.

  This is useful for development, testing, and short-lived sessions.

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

  @impl true
  def save(session_id, data) when is_binary(session_id) and is_map(data) do
    ensure_table()
    :ets.insert(@table, {session_id, data})
    :ok
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

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      _ref ->
        :ok
    end
  end
end
