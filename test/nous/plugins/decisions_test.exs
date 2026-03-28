defmodule Nous.Plugins.DecisionsTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Decisions.Node
  alias Nous.Decisions.Store.ETS
  alias Nous.Plugins.Decisions, as: DecisionsPlugin

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
    test "returns empty list" do
      agent = make_agent()
      ctx = Context.new(deps: %{})

      assert DecisionsPlugin.tools(agent, ctx) == []
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
end
