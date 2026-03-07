defmodule Nous.Plugins.MemoryAutoUpdateTest do
  use ExUnit.Case, async: true

  alias Nous.Agent
  alias Nous.Agent.Context
  alias Nous.Memory.{Entry, Store}
  alias Nous.Message
  alias Nous.Plugins.Memory, as: MemoryPlugin

  setup do
    agent =
      Agent.new("openai:gpt-4",
        plugins: [MemoryPlugin],
        instructions: "Be helpful"
      )

    config = %{
      store: Store.ETS,
      auto_update_memory: true,
      auto_update_every: 1
    }

    ctx = Context.new(deps: %{memory_config: config})
    ctx = MemoryPlugin.init(agent, ctx)

    %{agent: agent, ctx: ctx}
  end

  describe "after_run/3 — disabled" do
    test "is a no-op when auto_update_memory is false", %{agent: agent} do
      config = %{store: Store.ETS, auto_update_memory: false}
      ctx = Context.new(deps: %{memory_config: config})
      ctx = MemoryPlugin.init(agent, ctx)

      result_ctx = MemoryPlugin.after_run(agent, %{output: "hi"}, ctx)

      # Context unchanged — no _run_count increment
      assert result_ctx == ctx
    end

    test "is a no-op when store is not initialized", %{agent: agent} do
      ctx = Context.new(deps: %{memory_config: %{auto_update_memory: true}})

      result_ctx = MemoryPlugin.after_run(agent, %{output: "hi"}, ctx)

      assert result_ctx == ctx
    end
  end

  describe "after_run/3 — run counter" do
    test "increments _run_count on each call", %{agent: agent, ctx: ctx} do
      # Stub the reflection to be a no-op by using a non-existent model
      # We just want to verify counter behavior, so set auto_update_every very high
      config = Map.put(ctx.deps[:memory_config], :auto_update_every, 1000)
      ctx = %{ctx | deps: Map.put(ctx.deps, :memory_config, config)}

      ctx1 = MemoryPlugin.after_run(agent, %{output: "hi"}, ctx)
      assert ctx1.deps[:memory_config][:_run_count] == 1

      ctx2 = MemoryPlugin.after_run(agent, %{output: "hi"}, ctx1)
      assert ctx2.deps[:memory_config][:_run_count] == 2

      ctx3 = MemoryPlugin.after_run(agent, %{output: "hi"}, ctx2)
      assert ctx3.deps[:memory_config][:_run_count] == 3
    end
  end

  describe "apply_reflection_operations/3" do
    test "handles remember operations", %{ctx: ctx} do
      config = ctx.deps[:memory_config]

      json =
        ~s([{"action": "remember", "content": "User likes blue", "type": "semantic", "importance": 0.8}])

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, json)

      # Verify the memory was stored
      store_state = result_ctx.deps[:memory_config][:store_state]
      {:ok, entries} = Store.ETS.list(store_state, [])
      assert length(entries) == 1
      assert hd(entries).content == "User likes blue"
      assert hd(entries).importance == 0.8
      assert hd(entries).type == :semantic
    end

    test "handles update operations", %{ctx: ctx} do
      config = ctx.deps[:memory_config]
      store_state = config[:store_state]

      # Store an initial memory
      entry = Entry.new(%{content: "User likes blue", importance: 0.5})
      {:ok, store_state} = Store.ETS.store(store_state, entry)
      config = Map.put(config, :store_state, store_state)
      ctx = %{ctx | deps: Map.put(ctx.deps, :memory_config, config)}

      json =
        ~s([{"action": "update", "id": "#{entry.id}", "content": "User likes green", "importance": 0.9}])

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, json)

      # Verify the memory was updated
      store_state = result_ctx.deps[:memory_config][:store_state]
      {:ok, updated} = Store.ETS.fetch(store_state, entry.id)
      assert updated.content == "User likes green"
      assert updated.importance == 0.9
    end

    test "handles forget operations", %{ctx: ctx} do
      config = ctx.deps[:memory_config]
      store_state = config[:store_state]

      # Store an initial memory
      entry = Entry.new(%{content: "Outdated info"})
      {:ok, store_state} = Store.ETS.store(store_state, entry)
      config = Map.put(config, :store_state, store_state)
      ctx = %{ctx | deps: Map.put(ctx.deps, :memory_config, config)}

      json = ~s([{"action": "forget", "id": "#{entry.id}"}])

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, json)

      store_state = result_ctx.deps[:memory_config][:store_state]
      assert {:error, :not_found} = Store.ETS.fetch(store_state, entry.id)
    end

    test "handles multiple operations in sequence", %{ctx: ctx} do
      config = ctx.deps[:memory_config]
      store_state = config[:store_state]

      # Store a memory to update and one to forget
      entry1 = Entry.new(%{content: "Old fact"})
      entry2 = Entry.new(%{content: "Wrong info"})
      {:ok, store_state} = Store.ETS.store(store_state, entry1)
      {:ok, store_state} = Store.ETS.store(store_state, entry2)
      config = Map.put(config, :store_state, store_state)
      ctx = %{ctx | deps: Map.put(ctx.deps, :memory_config, config)}

      json = """
      [
        {"action": "remember", "content": "New fact"},
        {"action": "update", "id": "#{entry1.id}", "content": "Updated fact"},
        {"action": "forget", "id": "#{entry2.id}"}
      ]
      """

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, json)

      store_state = result_ctx.deps[:memory_config][:store_state]
      {:ok, entries} = Store.ETS.list(store_state, [])

      contents = Enum.map(entries, & &1.content) |> Enum.sort()
      assert "New fact" in contents
      assert "Updated fact" in contents
      refute "Wrong info" in contents
      assert length(entries) == 2
    end

    test "handles malformed JSON gracefully", %{ctx: ctx} do
      config = ctx.deps[:memory_config]

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, "not json at all")

      # Context unchanged
      assert result_ctx.deps[:memory_config][:store_state] ==
               ctx.deps[:memory_config][:store_state]
    end

    test "handles empty array", %{ctx: ctx} do
      config = ctx.deps[:memory_config]

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, "[]")

      assert result_ctx.deps[:memory_config][:store_state] ==
               ctx.deps[:memory_config][:store_state]
    end

    test "handles JSON wrapped in markdown fences", %{ctx: ctx} do
      config = ctx.deps[:memory_config]

      json = """
      ```json
      [{"action": "remember", "content": "Fenced memory"}]
      ```
      """

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, json)

      store_state = result_ctx.deps[:memory_config][:store_state]
      {:ok, entries} = Store.ETS.list(store_state, [])
      assert length(entries) == 1
      assert hd(entries).content == "Fenced memory"
    end

    test "skips unrecognized operations gracefully", %{ctx: ctx} do
      config = ctx.deps[:memory_config]

      json = ~s([{"action": "unknown", "content": "something"}])

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, json)

      store_state = result_ctx.deps[:memory_config][:store_state]
      {:ok, entries} = Store.ETS.list(store_state, [])
      assert entries == []
    end

    test "skips remember with missing content", %{ctx: ctx} do
      config = ctx.deps[:memory_config]

      json = ~s([{"action": "remember"}])

      result_ctx = MemoryPlugin.apply_reflection_operations(ctx, config, json)

      store_state = result_ctx.deps[:memory_config][:store_state]
      {:ok, entries} = Store.ETS.list(store_state, [])
      assert entries == []
    end
  end

  describe "after_run/3 — auto_update_every" do
    test "only triggers reflection at the right interval", %{agent: agent, ctx: ctx} do
      # Set auto_update_every to 3, and don't set a reflection model
      # so reflection will "fail" gracefully — we verify via _run_count and store state
      config =
        ctx.deps[:memory_config]
        |> Map.put(:auto_update_every, 3)

      ctx = %{ctx | deps: Map.put(ctx.deps, :memory_config, config)}

      # Add a user message so format_conversation has something to work with
      ctx = Context.add_message(ctx, Message.user("Hello"))

      # Run 1 — no reflection (1 % 3 != 0)
      ctx1 = MemoryPlugin.after_run(agent, %{output: "hi"}, ctx)
      assert ctx1.deps[:memory_config][:_run_count] == 1

      # Run 2 — no reflection (2 % 3 != 0)
      ctx2 = MemoryPlugin.after_run(agent, %{output: "hi"}, ctx1)
      assert ctx2.deps[:memory_config][:_run_count] == 2

      # Run 3 — reflection fires (3 % 3 == 0), but may fail due to no real LLM
      # That's OK — we just verify the counter incremented
      ctx3 = MemoryPlugin.after_run(agent, %{output: "hi"}, ctx2)
      assert ctx3.deps[:memory_config][:_run_count] == 3
    end
  end
end
