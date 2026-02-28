defmodule Nous.Plugins.MemoryTest do
  use ExUnit.Case, async: true

  alias Nous.Agent
  alias Nous.Agent.Context
  alias Nous.Memory.{Entry, Store}
  alias Nous.Plugins.Memory, as: MemoryPlugin

  setup do
    agent =
      Agent.new("openai:gpt-4",
        plugins: [MemoryPlugin],
        instructions: "Be helpful"
      )

    config = %{store: Store.ETS}

    ctx = Context.new(deps: %{memory_config: config})

    %{agent: agent, ctx: ctx}
  end

  describe "init/2" do
    test "initializes the ETS store and stores state in deps", %{agent: agent, ctx: ctx} do
      ctx = MemoryPlugin.init(agent, ctx)
      config = ctx.deps[:memory_config]

      assert config[:store_state] != nil
      assert config[:auto_inject] == true
      assert config[:inject_strategy] == :first_only
      assert config[:inject_limit] == 5
      assert config[:_inject_done] == false
    end

    test "warns and passes through if no store configured", %{agent: agent} do
      ctx = Context.new(deps: %{})
      result = MemoryPlugin.init(agent, ctx)

      # Should not crash, just pass through
      assert result == ctx
    end

    test "respects custom config values", %{agent: agent} do
      config = %{
        store: Store.ETS,
        auto_inject: false,
        inject_strategy: :every_iteration,
        inject_limit: 10,
        inject_min_score: 0.5
      }

      ctx = Context.new(deps: %{memory_config: config})
      ctx = MemoryPlugin.init(agent, ctx)
      config = ctx.deps[:memory_config]

      assert config[:auto_inject] == false
      assert config[:inject_strategy] == :every_iteration
      assert config[:inject_limit] == 10
      assert config[:inject_min_score] == 0.5
    end
  end

  describe "tools/2" do
    test "returns remember, recall, forget tools", %{agent: agent, ctx: ctx} do
      tools = MemoryPlugin.tools(agent, ctx)

      assert length(tools) == 3
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["forget", "recall", "remember"]
    end
  end

  describe "system_prompt/2" do
    test "returns memory instructions when store is initialized", %{agent: agent, ctx: ctx} do
      ctx = MemoryPlugin.init(agent, ctx)
      prompt = MemoryPlugin.system_prompt(agent, ctx)

      assert is_binary(prompt)
      assert prompt =~ "remember"
      assert prompt =~ "recall"
      assert prompt =~ "forget"
    end

    test "returns nil when store is not initialized", %{agent: agent} do
      ctx = Context.new(deps: %{})
      prompt = MemoryPlugin.system_prompt(agent, ctx)

      assert is_nil(prompt)
    end
  end

  describe "before_request/3" do
    test "injects relevant memories on first iteration", %{agent: agent, ctx: ctx} do
      # Initialize the plugin
      ctx = MemoryPlugin.init(agent, ctx)
      config = ctx.deps[:memory_config]
      store_state = config[:store_state]

      # Store a memory directly
      entry =
        Entry.new(%{
          content: "User prefers dark mode in their IDE",
          importance: 0.8
        })

      {:ok, store_state} = Store.ETS.store(store_state, entry)
      config = Map.put(config, :store_state, store_state)
      ctx = %{ctx | deps: Map.put(ctx.deps, :memory_config, config)}

      # Add a user message
      user_msg = Nous.Message.user("What theme do I prefer?")
      ctx = Context.add_message(ctx, user_msg)

      # Run before_request
      {ctx, _tools} = MemoryPlugin.before_request(agent, ctx, [])

      # Should have injected a memory message
      system_msgs =
        ctx.messages
        |> Enum.filter(fn m -> m.role == :system && m.content =~ "Relevant Memories" end)

      assert length(system_msgs) > 0
      memory_msg = hd(system_msgs)
      assert memory_msg.content =~ "dark mode"
    end

    test "does not inject on second call with :first_only strategy", %{agent: agent, ctx: ctx} do
      ctx = MemoryPlugin.init(agent, ctx)

      # Store a memory
      config = ctx.deps[:memory_config]
      entry = Entry.new(%{content: "Important fact"})
      {:ok, store_state} = Store.ETS.store(config[:store_state], entry)
      config = Map.put(config, :store_state, store_state)
      ctx = %{ctx | deps: Map.put(ctx.deps, :memory_config, config)}

      # Add user message
      ctx = Context.add_message(ctx, Nous.Message.user("Tell me the fact"))

      # First call - should inject
      {ctx, _} = MemoryPlugin.before_request(agent, ctx, [])
      msg_count_after_first = length(ctx.messages)

      # Second call - should NOT inject (first_only strategy)
      {ctx, _} = MemoryPlugin.before_request(agent, ctx, [])
      assert length(ctx.messages) == msg_count_after_first
    end

    test "does not inject when auto_inject is false", %{agent: agent} do
      config = %{store: Store.ETS, auto_inject: false}
      ctx = Context.new(deps: %{memory_config: config})
      ctx = MemoryPlugin.init(agent, ctx)

      ctx = Context.add_message(ctx, Nous.Message.user("Hello"))

      {ctx, _} = MemoryPlugin.before_request(agent, ctx, [])

      system_msgs =
        ctx.messages
        |> Enum.filter(fn m -> m.role == :system && (m.content || "") =~ "Relevant Memories" end)

      assert system_msgs == []
    end

    test "does not inject when there are no user messages", %{agent: agent, ctx: ctx} do
      ctx = MemoryPlugin.init(agent, ctx)

      {ctx, _} = MemoryPlugin.before_request(agent, ctx, [])

      system_msgs =
        ctx.messages
        |> Enum.filter(fn m -> m.role == :system && (m.content || "") =~ "Relevant Memories" end)

      assert system_msgs == []
    end
  end
end
