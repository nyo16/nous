defmodule Nous.Tools.TodoTools do
  @moduledoc """
  Built-in tools for task tracking and progress management.

  TodoTools allows AI agents to break down complex tasks, track progress,
  and maintain focus on multi-step operations. Todos are automatically
  injected into the system prompt when `enable_todos: true`.

  ## Setup

  Enable todos when creating an agent:

      agent = Nous.new("lmstudio:qwen/qwen3-30b",
        instructions: "You are a helpful assistant",
        enable_todos: true,  # Enable todo tracking
        tools: [
          &TodoTools.add_todo/2,
          &TodoTools.update_todo/2,
          &TodoTools.complete_todo/2,
          &TodoTools.list_todos/2
        ]
      )

  Initial todos (optional):

      {:ok, result} = Nous.run(agent, "Build a REST API",
        deps: %{todos: []}  # Start with empty todo list
      )

  ## How It Works

  1. Todos are stored in `ctx.deps.todos`
  2. Tools return `__update_context__` to update the todo list
  3. AgentRunner merges updates back into context
  4. Before each model request, todos are injected into system prompt
  5. AI sees current progress and can self-organize

  ## Example

      # AI receives complex task
      {:ok, r1} = Nous.run(agent, "Analyze codebase and create report")

      # AI breaks it down:
      # - Calls add_todo("Read all source files")
      # - Calls add_todo("Analyze dependencies")
      # - Calls add_todo("Write report")

      # AI starts working:
      # - Calls update_todo(id: 1, status: "in_progress")
      # - Reads files...
      # - Calls complete_todo(id: 1)

      # System prompt automatically shows:
      # ✅ Completed (1): Read all source files
      # ⏳ In Progress (0):
      # 📝 Pending (2): Analyze dependencies, Write report
  """

  @doc """
  Add a new todo item.

  ## Arguments

  - text: The todo description (required)
  - status: Initial status - "pending", "in_progress", or "completed" (default: "pending")
  - priority: Priority level - "low", "medium", "high" (default: "medium")

  ## Returns

  - success: true/false
  - todo: The created todo item
  - todos: Updated full todo list
  - __update_context__: Context updates for AgentRunner
  """
  def add_todo(ctx, args) do
    # Support multiple parameter names (AI might use different names)
    text = Map.get(args, "text") || Map.get(args, "title") || Map.get(args, "description")
    status = Map.get(args, "status", "pending")
    priority = Map.get(args, "priority", "medium")

    if !text || text == "" do
      %{
        success: false,
        error: "Todo text is required"
      }
    else
      current_todos = ctx.deps[:todos] || []

      new_todo = %{
        id: generate_id(),
        text: text,
        status: status,
        priority: priority,
        created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      updated_todos = [new_todo | current_todos]

      %{
        success: true,
        todo: new_todo,
        todos: updated_todos,
        message: "Todo added: #{text}",
        __update_context__: %{todos: updated_todos}
      }
    end
  end

  @doc """
  Update an existing todo item.

  ## Arguments

  - id: Todo ID (required)
  - text: New text (optional)
  - status: New status - "pending", "in_progress", "completed" (optional)
  - priority: New priority - "low", "medium", "high" (optional)

  ## Returns

  - success: true/false
  - todo: The updated todo item
  - todos: Updated full todo list
  - __update_context__: Context updates for AgentRunner
  """
  def update_todo(ctx, args) do
    id = Map.get(args, "id")
    new_text = Map.get(args, "text")
    new_status = Map.get(args, "status")
    new_priority = Map.get(args, "priority")

    current_todos = ctx.deps[:todos] || []

    case find_todo(current_todos, id) do
      nil ->
        %{
          success: false,
          error: "Todo not found with id: #{id}",
          available_ids: Enum.map(current_todos, & &1.id)
        }

      todo ->
        updated_todo = todo
        |> maybe_update(:text, new_text)
        |> maybe_update(:status, new_status)
        |> maybe_update(:priority, new_priority)
        |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

        updated_todos = replace_todo(current_todos, id, updated_todo)

        %{
          success: true,
          todo: updated_todo,
          todos: updated_todos,
          message: "Todo updated: #{updated_todo.text}",
          __update_context__: %{todos: updated_todos}
        }
    end
  end

  @doc """
  Mark a todo as completed.

  ## Arguments

  - id: Todo ID (required)

  ## Returns

  - success: true/false
  - todo: The completed todo item
  - todos: Updated full todo list
  - __update_context__: Context updates for AgentRunner
  """
  def complete_todo(ctx, args) do
    id = Map.get(args, "id")

    current_todos = ctx.deps[:todos] || []

    case find_todo(current_todos, id) do
      nil ->
        %{
          success: false,
          error: "Todo not found with id: #{id}",
          available_ids: Enum.map(current_todos, & &1.id)
        }

      todo ->
        completed_todo = todo
        |> Map.put(:status, "completed")
        |> Map.put(:completed_at, DateTime.utc_now() |> DateTime.to_iso8601())
        |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

        updated_todos = replace_todo(current_todos, id, completed_todo)

        %{
          success: true,
          todo: completed_todo,
          todos: updated_todos,
          message: "Todo completed: #{completed_todo.text}",
          __update_context__: %{todos: updated_todos}
        }
    end
  end

  @doc """
  Delete a todo item.

  ## Arguments

  - id: Todo ID (required)

  ## Returns

  - success: true/false
  - todos: Updated full todo list
  - __update_context__: Context updates for AgentRunner
  """
  def delete_todo(ctx, args) do
    id = Map.get(args, "id")

    current_todos = ctx.deps[:todos] || []

    case find_todo(current_todos, id) do
      nil ->
        %{
          success: false,
          error: "Todo not found with id: #{id}"
        }

      todo ->
        updated_todos = Enum.reject(current_todos, &(&1.id == id))

        %{
          success: true,
          todos: updated_todos,
          message: "Todo deleted: #{todo.text}",
          __update_context__: %{todos: updated_todos}
        }
    end
  end

  @doc """
  List all todos with optional filtering.

  ## Arguments

  - status: Filter by status - "pending", "in_progress", "completed" (optional)
  - priority: Filter by priority - "low", "medium", "high" (optional)

  ## Returns

  - success: true
  - todos: Filtered todo list
  - total: Total number of todos
  - by_status: Count by status
  """
  def list_todos(ctx, args) do
    status_filter = Map.get(args, "status")
    priority_filter = Map.get(args, "priority")

    current_todos = ctx.deps[:todos] || []

    filtered_todos = current_todos
    |> filter_by_status(status_filter)
    |> filter_by_priority(priority_filter)

    %{
      success: true,
      todos: filtered_todos,
      total: length(filtered_todos),
      by_status: %{
        pending: count_by_status(current_todos, "pending"),
        in_progress: count_by_status(current_todos, "in_progress"),
        completed: count_by_status(current_todos, "completed")
      }
    }
  end

  # Private helper functions

  defp generate_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp find_todo(todos, id) do
    Enum.find(todos, &(&1.id == id))
  end

  defp replace_todo(todos, id, updated_todo) do
    Enum.map(todos, fn todo ->
      if todo.id == id, do: updated_todo, else: todo
    end)
  end

  defp maybe_update(todo, _key, nil), do: todo
  defp maybe_update(todo, key, value), do: Map.put(todo, key, value)

  defp filter_by_status(todos, nil), do: todos
  defp filter_by_status(todos, status), do: Enum.filter(todos, &(&1.status == status))

  defp filter_by_priority(todos, nil), do: todos
  defp filter_by_priority(todos, priority), do: Enum.filter(todos, &(&1.priority == priority))

  defp count_by_status(todos, status) do
    Enum.count(todos, &(&1.status == status))
  end
end
