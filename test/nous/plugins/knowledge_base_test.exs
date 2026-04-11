defmodule Nous.Plugins.KnowledgeBaseTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.{Entry, Store}
  alias Nous.Plugins.KnowledgeBase, as: KBPlugin

  defp build_agent do
    %Nous.Agent{
      model: %Nous.Model{provider: :openai, model: "gpt-4"},
      tools: [],
      plugins: []
    }
  end

  defp build_ctx(deps \\ %{}) do
    %Nous.Agent.Context{
      messages: [],
      deps: deps
    }
  end

  describe "init/2" do
    test "initializes store and sets defaults" do
      agent = build_agent()
      ctx = build_ctx(%{kb_config: %{store: Store.ETS, kb_id: "test-kb"}})

      result_ctx = KBPlugin.init(agent, ctx)
      config = result_ctx.deps[:kb_config]

      assert config[:store_state] != nil
      assert config[:auto_inject] == true
      assert config[:inject_strategy] == :first_only
      assert config[:inject_limit] == 3
      assert config[:inject_min_score] == 0.3
      assert config[:auto_compile] == false
    end

    test "warns and returns ctx unchanged when no store configured" do
      agent = build_agent()
      ctx = build_ctx(%{kb_config: %{}})

      result_ctx = KBPlugin.init(agent, ctx)
      assert result_ctx == ctx
    end

    test "returns ctx unchanged when no kb_config" do
      agent = build_agent()
      ctx = build_ctx(%{})

      result_ctx = KBPlugin.init(agent, ctx)
      assert result_ctx == ctx
    end
  end

  describe "tools/2" do
    test "returns 9 KB tools" do
      agent = build_agent()
      ctx = build_ctx()

      tools = KBPlugin.tools(agent, ctx)
      assert length(tools) == 9

      names = Enum.map(tools, & &1.name)
      assert "kb_search" in names
      assert "kb_read" in names
      assert "kb_list" in names
      assert "kb_ingest" in names
      assert "kb_add_entry" in names
      assert "kb_link" in names
      assert "kb_backlinks" in names
      assert "kb_health_check" in names
      assert "kb_generate" in names
    end
  end

  describe "system_prompt/2" do
    test "returns prompt when store is initialized" do
      agent = build_agent()
      ctx = build_ctx(%{kb_config: %{store_state: :some_state}})

      prompt = KBPlugin.system_prompt(agent, ctx)
      assert is_binary(prompt)
      assert String.contains?(prompt, "Knowledge Base")
      assert String.contains?(prompt, "kb_search")
    end

    test "returns nil when store not initialized" do
      agent = build_agent()
      ctx = build_ctx(%{kb_config: %{}})

      assert KBPlugin.system_prompt(agent, ctx) == nil
    end
  end

  describe "before_request/3" do
    test "injects relevant entries when auto_inject enabled" do
      {:ok, state} = Store.ETS.init([])

      entry =
        Entry.new(%{
          title: "GenServer Guide",
          content: "How to use GenServer in Elixir",
          summary: "A comprehensive guide"
        })

      Store.ETS.store_entry(state, entry)

      agent = build_agent()

      ctx =
        build_ctx(%{
          kb_config: %{
            store: Store.ETS,
            store_state: state,
            auto_inject: true,
            inject_strategy: :first_only,
            inject_limit: 3,
            inject_min_score: 0.0,
            _inject_done: false
          }
        })

      ctx = %{ctx | messages: [Nous.Message.user("Tell me about GenServer")]}

      {result_ctx, _tools} = KBPlugin.before_request(agent, ctx, [])

      # Should have injected a system message
      assert length(result_ctx.messages) > length(ctx.messages)

      injected = List.last(result_ctx.messages)
      assert injected.role == :system
      assert String.contains?(injected.content, "Relevant Knowledge")
      assert String.contains?(injected.content, "genserver-guide")
    end

    test "does not inject when auto_inject is false" do
      {:ok, state} = Store.ETS.init([])

      agent = build_agent()

      ctx =
        build_ctx(%{
          kb_config: %{
            store: Store.ETS,
            store_state: state,
            auto_inject: false,
            _inject_done: false
          }
        })

      ctx = %{ctx | messages: [Nous.Message.user("test")]}

      {result_ctx, _tools} = KBPlugin.before_request(agent, ctx, [])
      assert length(result_ctx.messages) == length(ctx.messages)
    end

    test "respects first_only strategy" do
      {:ok, state} = Store.ETS.init([])

      agent = build_agent()

      ctx =
        build_ctx(%{
          kb_config: %{
            store: Store.ETS,
            store_state: state,
            auto_inject: true,
            inject_strategy: :first_only,
            inject_limit: 3,
            inject_min_score: 0.0,
            _inject_done: true
          }
        })

      ctx = %{ctx | messages: [Nous.Message.user("test")]}

      {result_ctx, _tools} = KBPlugin.before_request(agent, ctx, [])

      # Should not inject since _inject_done is true
      assert length(result_ctx.messages) == length(ctx.messages)
    end
  end
end
