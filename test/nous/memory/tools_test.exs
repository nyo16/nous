defmodule Nous.Memory.ToolsTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Memory.{Store, Tools}
  alias Nous.Tool.ContextUpdate

  setup do
    {:ok, table} = Store.ETS.init([])

    config = %{
      store: Store.ETS,
      store_state: table,
      agent_id: "test_agent",
      session_id: "test_session",
      user_id: "test_user"
    }

    ctx = Context.new(deps: %{memory_config: config})

    %{ctx: ctx, config: config}
  end

  describe "remember/2" do
    test "stores a memory and returns entry info", %{ctx: ctx} do
      args = %{"content" => "User prefers dark mode"}

      {:ok, result, %ContextUpdate{} = update} = Tools.remember(ctx, args)

      assert result.status == "remembered"
      assert result.content == "User prefers dark mode"
      assert result.type == "semantic"
      assert result.importance == 0.5
      assert is_binary(result.id)

      # Verify the update contains the new store state
      assert length(update.operations) > 0
    end

    test "stores with custom type, importance, and evergreen", %{ctx: ctx} do
      args = %{
        "content" => "Always use mix format",
        "type" => "procedural",
        "importance" => 0.9,
        "evergreen" => true
      }

      {:ok, result, _update} = Tools.remember(ctx, args)

      assert result.status == "remembered"
      assert result.type == "procedural"
      assert result.importance == 0.9
    end

    test "auto-tags with scoping from config", %{ctx: ctx} do
      args = %{"content" => "Some fact"}
      {:ok, result, update} = Tools.remember(ctx, args)

      # Apply update and verify the entry is stored with scoping
      new_ctx = ContextUpdate.apply(update, ctx)
      new_config = new_ctx.deps[:memory_config]
      store_state = new_config[:store_state]

      {:ok, entry} = Store.ETS.fetch(store_state, result.id)
      assert entry.agent_id == "test_agent"
      assert entry.session_id == "test_session"
      assert entry.user_id == "test_user"
    end

    test "returns error when memory system not initialized" do
      ctx = Context.new(deps: %{})
      args = %{"content" => "test"}

      {:ok, result, _update} = Tools.remember(ctx, args)
      assert result.status == "error"
      assert result.message =~ "not initialized"
    end
  end

  describe "recall/2" do
    test "finds stored memories by query", %{ctx: ctx} do
      # Store some memories first
      {:ok, _, update} = Tools.remember(ctx, %{"content" => "User's favorite color is blue"})
      ctx = ContextUpdate.apply(update, ctx)

      {:ok, _, update} =
        Tools.remember(ctx, %{"content" => "User works on an Elixir project"})

      ctx = ContextUpdate.apply(update, ctx)

      # Now recall
      {:ok, result, _update} = Tools.recall(ctx, %{"query" => "favorite color"})

      assert result.status == "found"
      assert result.count > 0
      assert is_list(result.memories)

      first = hd(result.memories)
      assert is_binary(first.id)
      assert is_binary(first.content)
      assert is_number(first.score)
    end

    test "returns empty list when no memories match", %{ctx: ctx} do
      {:ok, result, _update} = Tools.recall(ctx, %{"query" => "nonexistent topic"})

      assert result.status == "found"
      assert result.memories == []
    end

    test "respects limit parameter", %{ctx: ctx} do
      # Store multiple memories
      ctx =
        Enum.reduce(1..5, ctx, fn i, acc ->
          {:ok, _, update} = Tools.remember(acc, %{"content" => "Memory number #{i}"})
          ContextUpdate.apply(update, acc)
        end)

      {:ok, result, _update} = Tools.recall(ctx, %{"query" => "Memory", "limit" => 2})

      assert length(result.memories) <= 2
    end

    test "returns error when memory system not initialized" do
      ctx = Context.new(deps: %{})

      {:ok, result, _update} = Tools.recall(ctx, %{"query" => "anything"})
      assert result.status == "error"
    end
  end

  describe "forget/2" do
    test "deletes a memory by ID", %{ctx: ctx} do
      # Store a memory
      {:ok, remember_result, update} =
        Tools.remember(ctx, %{"content" => "Temporary note"})

      ctx = ContextUpdate.apply(update, ctx)
      id = remember_result.id

      # Forget it
      {:ok, forget_result, update} = Tools.forget(ctx, %{"id" => id})
      ctx = ContextUpdate.apply(update, ctx)

      assert forget_result.status == "forgotten"
      assert forget_result.id == id

      # Verify it's gone
      config = ctx.deps[:memory_config]
      assert {:error, :not_found} = Store.ETS.fetch(config[:store_state], id)
    end

    test "returns error when memory system not initialized" do
      ctx = Context.new(deps: %{})

      {:ok, result, _update} = Tools.forget(ctx, %{"id" => "some-id"})
      assert result.status == "error"
    end
  end

  describe "all_tools/0" do
    test "returns three tool structs" do
      tools = Tools.all_tools()

      assert length(tools) == 3
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["forget", "recall", "remember"]

      Enum.each(tools, fn tool ->
        assert %Nous.Tool{} = tool
        assert tool.takes_ctx == true
        assert is_function(tool.function)
      end)
    end
  end
end
