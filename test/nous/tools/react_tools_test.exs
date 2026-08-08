defmodule Nous.Tools.ReActToolsTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.RunContext
  alias Nous.Tools.ReActTools

  # Every ReAct tool is a state transition expressed as a `__update_context__`
  # payload; the runner folds it back with `Context.merge_tool_deps/2` before
  # the next call (`agent_runner/tool_execution.ex`). Threading through the
  # real merge is what makes the id allocation and ordering below testable
  # across iterations instead of inside a single call.
  defp advance(%Context{} = ctx, result) do
    Context.merge_tool_deps(ctx, Map.get(result, :__update_context__, %{}))
  end

  defp run_ctx(%Context{} = ctx), do: RunContext.new(ctx.deps)

  defp add(ctx, args) do
    result = ReActTools.add_todo(run_ctx(ctx), args)
    {result, advance(ctx, result)}
  end

  defp three_todos do
    ctx = Context.new()
    {_, ctx} = add(ctx, %{"item" => "first", "priority" => "high"})
    {_, ctx} = add(ctx, %{"item" => "second"})
    {_, ctx} = add(ctx, %{"item" => "third", "priority" => "low"})
    ctx
  end

  describe "add_todo/2" do
    test "ids increment and insertion order survives across calls" do
      ctx = three_todos()

      assert Enum.map(ctx.deps.todos, & &1.id) == [1, 2, 3]
      assert Enum.map(ctx.deps.todos, & &1.item) == ["first", "second", "third"]
      assert Enum.all?(ctx.deps.todos, &(&1.status == :pending))
    end

    test "reports the id it allocated and the resulting total" do
      {first, ctx} = add(Context.new(), %{"item" => "first"})
      {second, _ctx} = add(ctx, %{"item" => "second"})

      assert first.todo_id == 1
      assert first.message =~ "#1: first"
      assert first.message =~ "(1 total todos)"

      assert second.todo_id == 2
      assert second.message =~ "(2 total todos)"
    end

    test "accepts \"task\" as an alias for \"item\" and defaults the priority" do
      {result, ctx} = add(Context.new(), %{"task" => "aliased"})

      assert result.success
      assert [%{item: "aliased", priority: "medium"}] = ctx.deps.todos
    end
  end

  describe "complete_todo/2" do
    test "flips exactly the addressed todo and leaves the rest pending" do
      ctx = three_todos()

      result = ReActTools.complete_todo(run_ctx(ctx), %{"id" => 2})
      ctx = advance(ctx, result)

      assert result.completed_id == 2
      assert result.stats == %{completed: 1, pending: 2, total: 3}
      assert result.message =~ "(2 remaining)"

      assert Enum.map(ctx.deps.todos, &{&1.id, &1.status}) ==
               [{1, :pending}, {2, :completed}, {3, :pending}]

      # Only the completed todo gains a timestamp.
      timestamped = Enum.filter(ctx.deps.todos, &Map.has_key?(&1, :completed_at))
      assert Enum.map(timestamped, & &1.id) == [2]
    end

    test "matching by item text returns the todo's id, not its position" do
      ctx = three_todos()

      # Index 1, id 2 — the two differ, so a positional return value fails here.
      result = ReActTools.complete_todo(run_ctx(ctx), %{"item" => "SEC"})

      assert result.completed_id == 2
      assert %{id: 2, status: :completed} = Enum.at(advance(ctx, result).deps.todos, 1)
    end

    test "an unmatched id reports failure and cannot clobber the todo list" do
      ctx = three_todos()

      result = ReActTools.complete_todo(run_ctx(ctx), %{"id" => 99})

      assert result.success == false
      assert result.message =~ "Todo not found"
      # An empty update is what keeps the merge a no-op; a `%{todos: []}` here
      # would silently erase the list on a mistyped id.
      assert result.__update_context__ == %{}
      assert advance(ctx, result).deps.todos == ctx.deps.todos
    end

    test "an unmatched item text reports failure" do
      ctx = three_todos()

      result = ReActTools.complete_todo(run_ctx(ctx), %{"item" => "nothing like this"})

      assert result.success == false
      assert advance(ctx, result).deps.todos == ctx.deps.todos
    end

    test "neither id nor item reports failure rather than completing something" do
      ctx = three_todos()

      result = ReActTools.complete_todo(run_ctx(ctx), %{"priority" => "high"})

      assert result.success == false
      assert Enum.all?(advance(ctx, result).deps.todos, &(&1.status == :pending))
    end
  end

  describe "list_todos/2" do
    test "an empty list says so and carries no stats to misread" do
      result = ReActTools.list_todos(RunContext.new(%{}), %{})

      assert result.todos == []
      assert result.message =~ "No todos yet"
      refute Map.has_key?(result, :stats)
    end

    test "splits pending from completed and renders the priority of each" do
      ctx = three_todos()
      ctx = advance(ctx, ReActTools.complete_todo(run_ctx(ctx), %{"id" => 3}))

      result = ReActTools.list_todos(run_ctx(ctx), %{})

      assert result.stats == %{pending: 2, completed: 1, total: 3}
      assert result.message =~ "Progress: 1/3 completed"

      # Status icon then priority icon: a completed todo listed under PENDING
      # (or a "high" rendered as the default) changes these lines.
      assert result.message =~ "📝 🔴 #1: first"
      assert result.message =~ "📝 🟡 #2: second"
      assert result.message =~ "✅ 🟢 #3: third"

      [pending_section, completed_section] = String.split(result.message, "✅ COMPLETED:")
      assert pending_section =~ "#1: first"
      assert pending_section =~ "#2: second"
      refute pending_section =~ "#3: third"
      assert completed_section =~ "#3: third"
    end

    test "omits the completed section entirely when nothing is done" do
      result = ReActTools.list_todos(run_ctx(three_todos()), %{})

      assert result.message =~ "📝 PENDING:"
      refute result.message =~ "✅ COMPLETED:"
    end
  end

  describe "plan/2 and note/2" do
    test "plans and notes accumulate most-recent-first in their own deps keys" do
      ctx = Context.new()

      first = ReActTools.plan(run_ctx(ctx), %{"task" => "map the repo"})
      ctx = advance(ctx, first)
      second = ReActTools.plan(run_ctx(ctx), %{"problem" => "then fix it"})
      ctx = advance(ctx, second)

      assert Enum.map(ctx.deps.plans, & &1.task) == ["then fix it", "map the repo"]

      note = ReActTools.note(run_ctx(ctx), %{"content" => "the parser is recursive"})
      ctx = advance(ctx, note)

      assert note.message =~ "the parser is recursive"
      assert [%{content: "the parser is recursive"}] = ctx.deps.notes
      # Notes must not disturb the plans already recorded.
      assert length(ctx.deps.plans) == 2
    end

    test "plan accepts task, query and problem, and falls back to a placeholder" do
      ctx = RunContext.new(%{})

      for {args, expected} <- [
            {%{"task" => "a"}, "a"},
            {%{"query" => "b"}, "b"},
            {%{"problem" => "c"}, "c"},
            {%{}, "Current task"}
          ] do
        assert %{__update_context__: %{plans: [%{task: task} | _]}} = ReActTools.plan(ctx, args)
        assert task == expected
      end
    end
  end

  describe "final_answer/2" do
    test "summarises the run from the deps it was handed" do
      ctx = three_todos()
      ctx = advance(ctx, ReActTools.complete_todo(run_ctx(ctx), %{"id" => 1}))
      ctx = advance(ctx, ReActTools.plan(run_ctx(ctx), %{"task" => "a plan"}))
      ctx = advance(ctx, ReActTools.note(run_ctx(ctx), %{"content" => "a note"}))

      result = ReActTools.final_answer(run_ctx(ctx), %{"answer" => "42"})

      assert result.final_answer == "42"

      assert result.metadata == %{
               todos_completed: 1,
               todos_pending: 2,
               plans_count: 1,
               notes_count: 1
             }

      assert result.message =~ "Todos completed: 1/3"
      assert result.message =~ "42"
    end

    test "reports zeroes rather than crashing on an empty run" do
      result = ReActTools.final_answer(RunContext.new(%{}), %{"answer" => "nothing to do"})

      assert result.metadata == %{
               todos_completed: 0,
               todos_pending: 0,
               plans_count: 0,
               notes_count: 0
             }

      # A completion tool must never carry a context update: the runner would
      # merge it after the answer is already formed.
      refute Map.has_key?(result, :__update_context__)
    end
  end
end
