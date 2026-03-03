defmodule Nous.Plugins.TeamToolsTest do
  use ExUnit.Case, async: true

  alias Nous.Agent
  alias Nous.Agent.Context
  alias Nous.Plugins.TeamTools
  alias Nous.Teams.SharedState

  setup do
    agent = Agent.new("openai:test-model", instructions: "Team agent")

    team_id = "tt_test_#{System.unique_integer([:positive])}"

    {:ok, shared_state} =
      start_supervised(
        {SharedState, team_id: team_id},
        id: :"shared_state_#{team_id}"
      )

    ctx =
      Context.new(
        deps: %{
          team_id: team_id,
          agent_name: "alice",
          shared_state_pid: shared_state,
          team_coordinator_pid: nil
        }
      )

    %{agent: agent, ctx: ctx, team_id: team_id, shared_state: shared_state}
  end

  describe "Plugin behaviour" do
    test "provides tools", %{agent: agent, ctx: ctx} do
      tools = TeamTools.tools(agent, ctx)

      assert length(tools) == 5
      names = Enum.map(tools, & &1.name) |> Enum.sort()

      assert names == [
               "broadcast_message",
               "claim_region",
               "list_team",
               "peer_message",
               "share_discovery"
             ]
    end

    test "all tools take context", %{agent: agent, ctx: ctx} do
      tools = TeamTools.tools(agent, ctx)

      for tool <- tools do
        assert tool.takes_ctx == true
      end
    end

    test "system_prompt returns team context", %{agent: agent, ctx: ctx} do
      prompt = TeamTools.system_prompt(agent, ctx)

      assert is_binary(prompt)
      assert prompt =~ "alice"
      assert prompt =~ ctx.deps[:team_id]
      assert prompt =~ "peer_message"
      assert prompt =~ "claim_region"
    end

    test "system_prompt includes role info when present", %{agent: agent, ctx: ctx} do
      role = Nous.Teams.Role.researcher()
      ctx = %{ctx | deps: Map.put(ctx.deps, :team_role, role)}

      prompt = TeamTools.system_prompt(agent, ctx)

      assert prompt =~ "researcher"
    end

    test "init subscribes to PubSub topics (no-op with nil pubsub)", %{agent: agent, ctx: ctx} do
      # Should not crash even with nil pubsub
      result = TeamTools.init(agent, ctx)
      assert %Context{} = result
    end

    test "before_request returns context and tools unchanged", %{agent: agent, ctx: ctx} do
      {result_ctx, result_tools} = TeamTools.before_request(agent, ctx, [])
      assert result_ctx == ctx
      assert result_tools == []
    end
  end

  describe "tool schemas" do
    test "peer_message has required to and content params", %{agent: agent, ctx: ctx} do
      tools = TeamTools.tools(agent, ctx)
      tool = Enum.find(tools, &(&1.name == "peer_message"))

      assert tool.parameters["required"] == ["to", "content"]
      assert Map.has_key?(tool.parameters["properties"], "to")
      assert Map.has_key?(tool.parameters["properties"], "content")
    end

    test "broadcast_message has required content param", %{agent: agent, ctx: ctx} do
      tools = TeamTools.tools(agent, ctx)
      tool = Enum.find(tools, &(&1.name == "broadcast_message"))

      assert tool.parameters["required"] == ["content"]
    end

    test "share_discovery has required topic and content params", %{agent: agent, ctx: ctx} do
      tools = TeamTools.tools(agent, ctx)
      tool = Enum.find(tools, &(&1.name == "share_discovery"))

      assert tool.parameters["required"] == ["topic", "content"]
    end

    test "claim_region has required file, start_line, end_line params", %{agent: agent, ctx: ctx} do
      tools = TeamTools.tools(agent, ctx)
      tool = Enum.find(tools, &(&1.name == "claim_region"))

      assert Enum.sort(tool.parameters["required"]) == ["end_line", "file", "start_line"]
    end
  end

  describe "share_discovery tool" do
    test "stores discovery in shared state", %{ctx: ctx, shared_state: shared_state} do
      result =
        TeamTools.share_discovery(ctx, %{"topic" => "Bug Found", "content" => "Null check issue"})

      assert result.status == "shared"
      assert result.topic == "Bug Found"
      assert result.from == "alice"

      discoveries = SharedState.get_discoveries(shared_state)
      assert length(discoveries) == 1
      assert hd(discoveries).topic == "Bug Found"
    end
  end

  describe "claim_region tool" do
    test "claims a region successfully", %{ctx: ctx} do
      result =
        TeamTools.claim_region(ctx, %{
          "file" => "lib/parser.ex",
          "start_line" => 10,
          "end_line" => 20
        })

      assert result.status == "claimed"
      assert result.file == "lib/parser.ex"
    end

    test "reports conflict on overlapping claim", %{ctx: ctx, shared_state: shared_state} do
      # First claim by another agent
      SharedState.claim_region(shared_state, "bob", "lib/parser.ex", 10, 20)

      result =
        TeamTools.claim_region(ctx, %{
          "file" => "lib/parser.ex",
          "start_line" => 15,
          "end_line" => 25
        })

      assert result.status == "conflict"
    end
  end

  describe "list_team tool" do
    test "returns note when coordinator unavailable", %{ctx: ctx} do
      result = TeamTools.list_team(ctx, %{})

      assert result.team_id == ctx.deps[:team_id]
      assert result.note == "coordinator unavailable"
    end
  end

  describe "peer_message tool" do
    test "returns sent status", %{ctx: ctx} do
      result = TeamTools.peer_message(ctx, %{"to" => "bob", "content" => "hello"})

      assert result.status == "sent"
      assert result.from == "alice"
      assert result.to == "bob"
    end
  end

  describe "broadcast_message tool" do
    test "returns broadcast status", %{ctx: ctx} do
      result = TeamTools.broadcast_message(ctx, %{"content" => "team announcement"})

      assert result.status == "broadcast"
      assert result.from == "alice"
    end
  end

  describe "Plugin integration" do
    test "works with Plugin.collect_tools/3", %{agent: agent, ctx: ctx} do
      tools = Nous.Plugin.collect_tools([TeamTools], agent, ctx)

      assert length(tools) == 5
    end

    test "works with Plugin.collect_system_prompts/3", %{agent: agent, ctx: ctx} do
      prompt = Nous.Plugin.collect_system_prompts([TeamTools], agent, ctx)

      assert is_binary(prompt)
      assert prompt =~ "Team Context"
    end

    test "works with Plugin.run_init/3", %{agent: agent, ctx: ctx} do
      result = Nous.Plugin.run_init([TeamTools], agent, ctx)
      assert %Context{} = result
    end
  end
end
