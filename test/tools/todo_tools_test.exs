defmodule Yggdrasil.Tools.TodoToolsTest do
  use ExUnit.Case, async: true

  alias Yggdrasil.Tools.TodoTools
  alias Yggdrasil.RunContext

  describe "add_todo/2" do
    test "adds a new todo with default values" do
      ctx = RunContext.new(%{todos: []})

      result = TodoTools.add_todo(ctx, %{"text" => "Write tests"})

      assert result.success == true
      assert result.todo.text == "Write tests"
      assert result.todo.status == "pending"
      assert result.todo.priority == "medium"
      assert is_integer(result.todo.id)
      assert result.todo.created_at
      assert result.todo.updated_at

      # Check context update
      assert length(result.todos) == 1
      assert result.__update_context__.todos == result.todos
    end

    test "adds todo with custom status and priority" do
      ctx = RunContext.new(%{todos: []})

      result = TodoTools.add_todo(ctx, %{
        "text" => "Fix bug",
        "status" => "in_progress",
        "priority" => "high"
      })

      assert result.success == true
      assert result.todo.status == "in_progress"
      assert result.todo.priority == "high"
    end

    test "fails when text is missing" do
      ctx = RunContext.new(%{todos: []})

      result = TodoTools.add_todo(ctx, %{})

      assert result.success == false
      assert result.error =~ "required"
    end

    test "adds todo to existing list" do
      existing_todo = %{
        id: 1,
        text: "Existing todo",
        status: "pending",
        priority: "medium",
        created_at: "2025-01-01T00:00:00Z",
        updated_at: "2025-01-01T00:00:00Z"
      }

      ctx = RunContext.new(%{todos: [existing_todo]})

      result = TodoTools.add_todo(ctx, %{"text" => "New todo"})

      assert result.success == true
      assert length(result.todos) == 2
      assert Enum.any?(result.todos, &(&1.text == "Existing todo"))
      assert Enum.any?(result.todos, &(&1.text == "New todo"))
    end
  end

  describe "update_todo/2" do
    setup do
      todo = %{
        id: 123,
        text: "Original text",
        status: "pending",
        priority: "medium",
        created_at: "2025-01-01T00:00:00Z",
        updated_at: "2025-01-01T00:00:00Z"
      }

      ctx = RunContext.new(%{todos: [todo]})
      {:ok, ctx: ctx, todo: todo}
    end

    test "updates todo text", %{ctx: ctx} do
      result = TodoTools.update_todo(ctx, %{
        "id" => 123,
        "text" => "Updated text"
      })

      assert result.success == true
      assert result.todo.text == "Updated text"
      assert result.todo.id == 123
      # Should update timestamp
      assert result.todo.updated_at != "2025-01-01T00:00:00Z"
    end

    test "updates todo status", %{ctx: ctx} do
      result = TodoTools.update_todo(ctx, %{
        "id" => 123,
        "status" => "in_progress"
      })

      assert result.success == true
      assert result.todo.status == "in_progress"
      # Text should remain
      assert result.todo.text == "Original text"
    end

    test "updates todo priority", %{ctx: ctx} do
      result = TodoTools.update_todo(ctx, %{
        "id" => 123,
        "priority" => "high"
      })

      assert result.success == true
      assert result.todo.priority == "high"
    end

    test "fails when todo not found", %{ctx: ctx} do
      result = TodoTools.update_todo(ctx, %{
        "id" => 999,
        "text" => "New text"
      })

      assert result.success == false
      assert result.error =~ "not found"
      assert result.available_ids == [123]
    end

    test "returns context update", %{ctx: ctx} do
      result = TodoTools.update_todo(ctx, %{
        "id" => 123,
        "status" => "completed"
      })

      assert result.__update_context__.todos == result.todos
      assert length(result.todos) == 1
    end
  end

  describe "complete_todo/2" do
    setup do
      todo = %{
        id: 456,
        text: "Task to complete",
        status: "in_progress",
        priority: "medium",
        created_at: "2025-01-01T00:00:00Z",
        updated_at: "2025-01-01T00:00:00Z"
      }

      ctx = RunContext.new(%{todos: [todo]})
      {:ok, ctx: ctx, todo: todo}
    end

    test "marks todo as completed", %{ctx: ctx} do
      result = TodoTools.complete_todo(ctx, %{"id" => 456})

      assert result.success == true
      assert result.todo.status == "completed"
      assert result.todo.completed_at
      assert result.todo.updated_at != "2025-01-01T00:00:00Z"
    end

    test "fails when todo not found", %{ctx: ctx} do
      result = TodoTools.complete_todo(ctx, %{"id" => 999})

      assert result.success == false
      assert result.error =~ "not found"
    end

    test "returns context update", %{ctx: ctx} do
      result = TodoTools.complete_todo(ctx, %{"id" => 456})

      assert result.__update_context__.todos == result.todos
    end
  end

  describe "delete_todo/2" do
    setup do
      todos = [
        %{id: 1, text: "Todo 1", status: "pending", priority: "medium",
          created_at: "2025-01-01", updated_at: "2025-01-01"},
        %{id: 2, text: "Todo 2", status: "completed", priority: "low",
          created_at: "2025-01-01", updated_at: "2025-01-01"}
      ]

      ctx = RunContext.new(%{todos: todos})
      {:ok, ctx: ctx}
    end

    test "deletes todo from list", %{ctx: ctx} do
      result = TodoTools.delete_todo(ctx, %{"id" => 1})

      assert result.success == true
      assert length(result.todos) == 1
      assert hd(result.todos).id == 2
      assert result.message =~ "Todo 1"
    end

    test "fails when todo not found", %{ctx: ctx} do
      result = TodoTools.delete_todo(ctx, %{"id" => 999})

      assert result.success == false
      assert result.error =~ "not found"
    end

    test "returns context update", %{ctx: ctx} do
      result = TodoTools.delete_todo(ctx, %{"id" => 1})

      assert result.__update_context__.todos == result.todos
    end
  end

  describe "list_todos/2" do
    setup do
      todos = [
        %{id: 1, text: "Pending task", status: "pending", priority: "high",
          created_at: "2025-01-01", updated_at: "2025-01-01"},
        %{id: 2, text: "In progress task", status: "in_progress", priority: "medium",
          created_at: "2025-01-01", updated_at: "2025-01-01"},
        %{id: 3, text: "Completed task", status: "completed", priority: "low",
          created_at: "2025-01-01", updated_at: "2025-01-01"},
        %{id: 4, text: "Another pending", status: "pending", priority: "medium",
          created_at: "2025-01-01", updated_at: "2025-01-01"}
      ]

      ctx = RunContext.new(%{todos: todos})
      {:ok, ctx: ctx}
    end

    test "lists all todos without filter", %{ctx: ctx} do
      result = TodoTools.list_todos(ctx, %{})

      assert result.success == true
      assert length(result.todos) == 4
      assert result.total == 4
      assert result.by_status.pending == 2
      assert result.by_status.in_progress == 1
      assert result.by_status.completed == 1
    end

    test "filters by status", %{ctx: ctx} do
      result = TodoTools.list_todos(ctx, %{"status" => "pending"})

      assert result.success == true
      assert length(result.todos) == 2
      assert Enum.all?(result.todos, &(&1.status == "pending"))
    end

    test "filters by priority", %{ctx: ctx} do
      result = TodoTools.list_todos(ctx, %{"priority" => "high"})

      assert result.success == true
      assert length(result.todos) == 1
      assert hd(result.todos).priority == "high"
    end

    test "filters by both status and priority", %{ctx: ctx} do
      result = TodoTools.list_todos(ctx, %{
        "status" => "pending",
        "priority" => "medium"
      })

      assert result.success == true
      assert length(result.todos) == 1
      assert hd(result.todos).status == "pending"
      assert hd(result.todos).priority == "medium"
    end

    test "returns empty list when no todos" do
      ctx = RunContext.new(%{todos: []})

      result = TodoTools.list_todos(ctx, %{})

      assert result.success == true
      assert result.todos == []
      assert result.total == 0
      assert result.by_status.pending == 0
    end
  end
end
