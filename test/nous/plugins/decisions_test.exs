defmodule Nous.Plugins.DecisionsTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Decisions.{Node, Tools}
  alias Nous.Decisions.Store.ETS
  alias Nous.Plugins.Decisions, as: DecisionsPlugin
  alias Nous.Tool.ContextUpdate

  defp make_agent do
    # Minimal agent struct for plugin callbacks
    %Nous.Agent{model: "test:model", system_prompt: "test"}
  end

  describe "init/2" do
    test "initializes store and sets config" do
      agent = make_agent()
      ctx = Context.new(deps: %{decisions_config: %{store: ETS}})

      ctx = DecisionsPlugin.init(agent, ctx)

      config = ctx.deps[:decisions_config]
      assert config[:store_state] != nil
      assert config[:auto_inject] == true
      assert config[:inject_strategy] == :first_only
      assert config[:decision_limit] == 5
    end

    test "warns and returns ctx when no store configured" do
      agent = make_agent()
      ctx = Context.new(deps: %{decisions_config: %{}})

      result = DecisionsPlugin.init(agent, ctx)
      # Should return ctx unchanged (no store_state)
      assert result.deps[:decisions_config][:store_state] == nil
    end

    test "returns ctx when no config at all" do
      agent = make_agent()
      ctx = Context.new(deps: %{})

      result = DecisionsPlugin.init(agent, ctx)
      assert result.deps[:decisions_config] == nil
    end
  end

  describe "tools/2" do
    test "returns decision tools" do
      agent = make_agent()
      ctx = Context.new(deps: %{})

      tools = DecisionsPlugin.tools(agent, ctx)

      assert length(tools) == 4
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["add_goal", "query_decisions", "record_decision", "record_outcome"]

      Enum.each(tools, fn tool ->
        assert %Nous.Tool{} = tool
        assert tool.takes_ctx == true
        assert is_function(tool.function)
      end)
    end
  end

  describe "system_prompt/2" do
    test "returns context text when store is initialized" do
      agent = make_agent()
      {:ok, state} = ETS.init([])

      # Add a goal to make the context non-empty
      goal = Node.new(%{type: :goal, label: "Test goal", confidence: 0.9})
      {:ok, state} = ETS.add_node(state, goal)

      config = %{store: ETS, store_state: state, decision_limit: 5}
      ctx = Context.new(deps: %{decisions_config: config})

      prompt = DecisionsPlugin.system_prompt(agent, ctx)

      assert is_binary(prompt)
      assert prompt =~ "Decisions"
      assert prompt =~ "add_goal"
      assert prompt =~ "Active Goals"
      assert prompt =~ "Test goal"
    end

    test "returns base prompt when no nodes exist" do
      agent = make_agent()
      {:ok, state} = ETS.init([])

      config = %{store: ETS, store_state: state}
      ctx = Context.new(deps: %{decisions_config: config})

      prompt = DecisionsPlugin.system_prompt(agent, ctx)
      assert prompt =~ "Decisions"
      refute prompt =~ "Active Goals"
    end

    test "returns nil when store not initialized" do
      agent = make_agent()
      ctx = Context.new(deps: %{decisions_config: %{}})

      assert DecisionsPlugin.system_prompt(agent, ctx) == nil
    end
  end

  describe "tool execution" do
    setup do
      {:ok, state} = ETS.init([])

      config = %{
        store: ETS,
        store_state: state
      }

      ctx = Context.new(deps: %{decisions_config: config})
      %{ctx: ctx}
    end

    test "add_goal creates a goal node", %{ctx: ctx} do
      args = %{"label" => "Implement authentication", "confidence" => 0.8}

      {:ok, result, %ContextUpdate{} = update} = Tools.add_goal(ctx, args)

      assert result.status == "added"
      assert result.type == "goal"
      assert result.label == "Implement authentication"
      assert is_binary(result.id)

      # Verify update contains new store state
      assert length(update.operations) > 0
    end

    test "record_decision creates a decision linked to parent", %{ctx: ctx} do
      # First add a goal
      {:ok, goal_result, update} = Tools.add_goal(ctx, %{"label" => "Goal"})
      ctx = ContextUpdate.apply(update, ctx)

      # Record a decision linked to the goal
      args = %{
        "label" => "Use JWT tokens",
        "parent_id" => goal_result.id,
        "edge_type" => "leads_to",
        "rationale" => "Simpler for API auth"
      }

      {:ok, result, update} = Tools.record_decision(ctx, args)
      ctx = ContextUpdate.apply(update, ctx)

      assert result.status == "recorded"
      assert result.type == "decision"

      # Verify edge was created
      config = ctx.deps[:decisions_config]
      {:ok, edges} = ETS.get_edges(config[:store_state], goal_result.id, :outgoing)
      assert length(edges) == 1
      assert hd(edges).to_id == result.id
    end

    test "query_decisions returns active goals", %{ctx: ctx} do
      {:ok, _, update} = Tools.add_goal(ctx, %{"label" => "Goal 1"})
      ctx = ContextUpdate.apply(update, ctx)
      {:ok, _, update} = Tools.add_goal(ctx, %{"label" => "Goal 2"})
      ctx = ContextUpdate.apply(update, ctx)

      {:ok, result, _update} = Tools.query_decisions(ctx, %{"query_type" => "active_goals"})

      assert result.status == "found"
      assert result.count == 2
      labels = Enum.map(result.nodes, & &1.label) |> Enum.sort()
      assert labels == ["Goal 1", "Goal 2"]
    end

    test "returns error when system not initialized" do
      ctx = Context.new(deps: %{})

      {:ok, result, _update} = Tools.add_goal(ctx, %{"label" => "Test"})
      assert result.status == "error"
      assert result.message =~ "not initialized"
    end
  end
end
