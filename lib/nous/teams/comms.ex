defmodule Nous.Teams.Comms do
  @moduledoc """
  PubSub topic helpers and communication utilities for multi-agent teams.

  Provides consistent topic naming conventions and convenience wrappers
  around `Nous.PubSub` for team-scoped messaging.

  ## Topic Structure

      nous:team:<team_id>              — team-wide broadcasts
      nous:team:<team_id>:context      — shared context updates
      nous:team:<team_id>:agent:<name> — direct agent messages

  ## Quick Start

      # Subscribe an agent to team + direct topics
      Comms.subscribe_team(pubsub, "team_1")
      Comms.subscribe_agent(pubsub, "team_1", "alice")

      # Broadcast to all agents on a team
      Comms.broadcast_team(pubsub, "team_1", {:discovery, %{topic: "bug found"}})

      # Send a direct message to one agent
      Comms.send_to_agent(pubsub, "team_1", "bob", {:peer_message, "alice", "check this"})
  """

  alias Nous.PubSub

  @doc """
  Build the team-wide broadcast topic.

  ## Examples

      iex> Nous.Teams.Comms.team_topic("team_1")
      "nous:team:team_1"
  """
  @spec team_topic(String.t()) :: String.t()
  def team_topic(team_id), do: "nous:team:#{team_id}"

  @doc """
  Build the shared context update topic for a team.

  ## Examples

      iex> Nous.Teams.Comms.context_topic("team_1")
      "nous:team:team_1:context"
  """
  @spec context_topic(String.t()) :: String.t()
  def context_topic(team_id), do: "nous:team:#{team_id}:context"

  @doc """
  Build the direct message topic for a specific agent in a team.

  ## Examples

      iex> Nous.Teams.Comms.agent_topic("team_1", "alice")
      "nous:team:team_1:agent:alice"
  """
  @spec agent_topic(String.t(), String.t()) :: String.t()
  def agent_topic(team_id, agent_name), do: "nous:team:#{team_id}:agent:#{agent_name}"

  @doc """
  Subscribe the calling process to the team-wide broadcast topic.

  ## Options

  Uses `Nous.PubSub.subscribe/2` — no-op if PubSub is nil or unavailable.
  """
  @spec subscribe_team(module() | nil, String.t()) :: :ok | {:error, term()}
  def subscribe_team(pubsub, team_id) do
    PubSub.subscribe(pubsub, team_topic(team_id))
  end

  @doc """
  Subscribe the calling process to a specific agent's direct message topic.

  ## Options

  Uses `Nous.PubSub.subscribe/2` — no-op if PubSub is nil or unavailable.
  """
  @spec subscribe_agent(module() | nil, String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe_agent(pubsub, team_id, agent_name) do
    PubSub.subscribe(pubsub, agent_topic(team_id, agent_name))
  end

  @doc """
  Broadcast a message to all agents on the team.

  ## Options

  Uses `Nous.PubSub.broadcast/3` — no-op if PubSub is nil or unavailable.
  """
  @spec broadcast_team(module() | nil, String.t(), term()) :: :ok | {:error, term()}
  def broadcast_team(pubsub, team_id, message) do
    PubSub.broadcast(pubsub, team_topic(team_id), message)
  end

  @doc """
  Send a direct message to a specific agent on the team.

  ## Options

  Uses `Nous.PubSub.broadcast/3` on the agent's direct topic — no-op if PubSub
  is nil or unavailable.
  """
  @spec send_to_agent(module() | nil, String.t(), String.t(), term()) :: :ok | {:error, term()}
  def send_to_agent(pubsub, team_id, agent_name, message) do
    PubSub.broadcast(pubsub, agent_topic(team_id, agent_name), message)
  end
end
