defmodule TradingDesk.Supervisor do
  @moduledoc """
  Supervisor for the trading desk multi-agent system.

  Supervises:
  - Registry for agent names
  - Coordinator agent
  - All specialist agents (Market, Risk, Trading, Research)
  """

  use Supervisor
  require Logger

  alias TradingDesk.{AgentSpecs, AgentServer, Coordinator}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[TradingDesk] Starting trading desk supervisor...")

    children = [
      # Registry for agent process names
      {Registry, keys: :unique, name: TradingDesk.Registry},

      # Coordinator agent (orchestrates specialists)
      {Coordinator, []},

      # Specialist agents - each needs unique ID
      Supervisor.child_spec({AgentServer, AgentSpecs.market_analyst()}, id: :market_analyst_server),
      Supervisor.child_spec({AgentServer, AgentSpecs.risk_manager()}, id: :risk_manager_server),
      Supervisor.child_spec({AgentServer, AgentSpecs.trading_executor()}, id: :trading_executor_server),
      Supervisor.child_spec({AgentServer, AgentSpecs.research_analyst()}, id: :research_analyst_server)
    ]

    Logger.info("[TradingDesk] Starting 4 specialist agents + coordinator")

    Supervisor.init(children, strategy: :one_for_one)
  end
end
