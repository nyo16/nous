defmodule Nous.Plugins.TeamTools do
  @moduledoc """
  Plugin that provides team communication and coordination tools for agents.

  When an agent is part of a team, this plugin adds tools for peer messaging,
  broadcasting, sharing discoveries, listing team members, and claiming file
  regions for editing.

  ## Capabilities

  - Direct messaging between team agents
  - Team-wide broadcasts
  - Shared discovery board
  - File region claiming to prevent edit conflicts
  - Team member listing

  ## Usage

      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.TeamTools],
        deps: %{
          team_id: "team_1",
          agent_name: "alice",
          shared_state_pid: shared_state_pid
        }
      )

  ## Configuration

  The plugin reads the following keys from `ctx.deps`:

  - `:team_id` — the team identifier (required)
  - `:agent_name` — this agent's name in the team (required)
  - `:shared_state_pid` — pid of the team's SharedState process
  - `:team_coordinator_pid` — pid of the team's Coordinator process

  ## Tools Provided

  | Tool | Description |
  |------|-------------|
  | `peer_message` | Send a direct message to a named agent |
  | `broadcast_message` | Broadcast a message to all team agents |
  | `share_discovery` | Store a finding in SharedState and broadcast |
  | `list_team` | List team members and their status |
  | `claim_region` | Claim file lines before editing |

  ## PubSub Events

  - `{:peer_message, from, to, content}` — sent on agent's direct topic
  - `{:team_broadcast, from, content}` — sent on team-wide topic
  - `{:discovery, from, discovery}` — sent on team-wide topic
  """

  @behaviour Nous.Plugin

  alias Nous.Tool
  alias Nous.Teams.{Comms, SharedState, Coordinator}

  # ===========================================================================
  # Plugin callbacks
  # ===========================================================================

  @impl true
  def init(_agent, ctx) do
    team_id = ctx.deps[:team_id]
    agent_name = ctx.deps[:agent_name]
    pubsub = ctx.pubsub

    if team_id && agent_name do
      Comms.subscribe_team(pubsub, team_id)
      Comms.subscribe_agent(pubsub, team_id, agent_name)
    end

    ctx
  end

  @impl true
  def tools(_agent, _ctx) do
    [
      peer_message_tool(),
      broadcast_message_tool(),
      share_discovery_tool(),
      list_team_tool(),
      claim_region_tool()
    ]
  end

  @impl true
  def system_prompt(_agent, ctx) do
    team_id = ctx.deps[:team_id]
    agent_name = ctx.deps[:agent_name]
    role = ctx.deps[:team_role]

    role_info =
      if role do
        "Your role: #{role.name}. #{role.system_prompt || ""}"
      else
        ""
      end

    """
    ## Team Context

    You are agent "#{agent_name || "unknown"}" on team "#{team_id || "unknown"}".
    #{role_info}

    ### Team Communication Tools
    - `peer_message` — send a direct message to another agent by name
    - `broadcast_message` — send a message to all agents on the team
    - `share_discovery` — store an important finding for the team
    - `list_team` — see who is on the team and their status
    - `claim_region` — claim a file region before editing to prevent conflicts

    ### Guidelines
    - Share important findings with the team via `share_discovery`
    - Claim file regions before editing with `claim_region`
    - Use `peer_message` for targeted communication
    - Use `broadcast_message` sparingly, only for team-wide announcements
    """
  end

  @impl true
  def before_request(_agent, ctx, tools) do
    # Inject recent team messages into context if available
    {ctx, tools}
  end

  # ===========================================================================
  # Tool definitions
  # ===========================================================================

  defp peer_message_tool do
    %Tool{
      name: "peer_message",
      description: "Send a direct message to a named agent on your team.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "to" => %{
            "type" => "string",
            "description" => "Name of the agent to send the message to"
          },
          "content" => %{
            "type" => "string",
            "description" => "The message content"
          }
        },
        "required" => ["to", "content"]
      },
      function: &__MODULE__.peer_message/2,
      takes_ctx: true
    }
  end

  defp broadcast_message_tool do
    %Tool{
      name: "broadcast_message",
      description:
        "Broadcast a message to all agents on the team. Use sparingly for important announcements.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "The message to broadcast"
          }
        },
        "required" => ["content"]
      },
      function: &__MODULE__.broadcast_message/2,
      takes_ctx: true
    }
  end

  defp share_discovery_tool do
    %Tool{
      name: "share_discovery",
      description:
        "Share an important finding with the team. Stores it in shared state and broadcasts to all agents.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "topic" => %{
            "type" => "string",
            "description" => "Short topic/title for the discovery"
          },
          "content" => %{
            "type" => "string",
            "description" => "Detailed content of the discovery"
          }
        },
        "required" => ["topic", "content"]
      },
      function: &__MODULE__.share_discovery/2,
      takes_ctx: true
    }
  end

  defp list_team_tool do
    %Tool{
      name: "list_team",
      description: "List all agents on the team and their current status.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      function: &__MODULE__.list_team/2,
      takes_ctx: true
    }
  end

  defp claim_region_tool do
    %Tool{
      name: "claim_region",
      description:
        "Claim a file region (line range) before editing to prevent conflicts with other agents.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file" => %{
            "type" => "string",
            "description" => "File path to claim"
          },
          "start_line" => %{
            "type" => "integer",
            "description" => "Start line number"
          },
          "end_line" => %{
            "type" => "integer",
            "description" => "End line number"
          }
        },
        "required" => ["file", "start_line", "end_line"]
      },
      function: &__MODULE__.claim_region/2,
      takes_ctx: true
    }
  end

  # ===========================================================================
  # Tool implementations
  # ===========================================================================

  @doc false
  def peer_message(ctx, %{"to" => to, "content" => content}) do
    team_id = ctx.deps[:team_id]
    from = ctx.deps[:agent_name]
    pubsub = ctx.pubsub

    Comms.send_to_agent(pubsub, team_id, to, {:peer_message, from, to, content})

    %{status: "sent", from: from, to: to}
  end

  @doc false
  def broadcast_message(ctx, %{"content" => content}) do
    team_id = ctx.deps[:team_id]
    from = ctx.deps[:agent_name]
    pubsub = ctx.pubsub

    Comms.broadcast_team(pubsub, team_id, {:team_broadcast, from, content})

    %{status: "broadcast", from: from}
  end

  @doc false
  def share_discovery(ctx, %{"topic" => topic, "content" => content}) do
    team_id = ctx.deps[:team_id]
    from = ctx.deps[:agent_name]
    pubsub = ctx.pubsub
    shared_state = ctx.deps[:shared_state_pid]

    discovery = %{topic: topic, content: content}

    if is_pid(shared_state) and Process.alive?(shared_state) do
      SharedState.share_discovery(shared_state, from, discovery)
    end

    Comms.broadcast_team(pubsub, team_id, {:discovery, from, discovery})

    %{status: "shared", topic: topic, from: from}
  end

  @doc false
  def list_team(ctx, _args) do
    coordinator = ctx.deps[:team_coordinator_pid]

    if is_pid(coordinator) and Process.alive?(coordinator) do
      agents = Coordinator.list_agents(coordinator)

      %{
        team_id: ctx.deps[:team_id],
        agents:
          Enum.map(agents, fn a ->
            %{name: a.name, status: a.status}
          end)
      }
    else
      %{team_id: ctx.deps[:team_id], agents: [], note: "coordinator unavailable"}
    end
  end

  @doc false
  def claim_region(ctx, %{"file" => file, "start_line" => start_line, "end_line" => end_line}) do
    agent_name = ctx.deps[:agent_name]
    shared_state = ctx.deps[:shared_state_pid]

    if is_pid(shared_state) and Process.alive?(shared_state) do
      case SharedState.claim_region(shared_state, agent_name, file, start_line, end_line) do
        :ok ->
          %{status: "claimed", file: file, start_line: start_line, end_line: end_line}

        {:error, :conflict} ->
          %{status: "conflict", file: file, message: "Region overlaps with another agent's claim"}
      end
    else
      %{status: "error", message: "shared state unavailable"}
    end
  end
end
