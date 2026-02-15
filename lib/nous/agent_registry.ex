defmodule Nous.AgentRegistry do
  @moduledoc "Registry for looking up agent processes by session ID."

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  def via_tuple(session_id) do
    {:via, Registry, {__MODULE__, session_id}}
  end

  def lookup(session_id) do
    case Registry.lookup(__MODULE__, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
