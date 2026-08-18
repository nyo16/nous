defmodule Nous.Tools.ReActTools do
  @moduledoc """
  Built-in tools for ReAct (Reasoning and Acting) agents.

  These tools provide structured planning, note-taking, todo management,
  and explicit task completion for ReAct agents.

  ## Tools Included

  - `plan/2` - Create structured plan with facts survey
  - `note/2` - Record observations and insights
  - `add_todo/2` - Add item to todo list
  - `complete_todo/2` - Mark todo as complete
  - `list_todos/2` - View current todos
  - `final_answer/2` - Provide final answer (signals completion)

  ## Usage

      agent = ReActAgent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        instructions: "Solve complex problems step by step"
      )

  The agent will automatically have access to all ReAct tools.
  """

  @typedoc """
  Tool arguments exactly as the model produced them: JSON object keys stay
  strings, values are unvalidated.
  """
  @type args :: %{optional(String.t()) => term()}

  @typedoc """
  Tool result: an atom-keyed map. A `:__update_context__` key, when present,
  is merged back into `ctx.deps` by the runner.
  """
  @type result :: %{required(atom()) => term()}

  require Logger

  @doc """
  Create a structured plan for solving a task.

  Helps the agent organize its approach by identifying:
  - Known facts
  - Facts to look up
  - Facts to derive/calculate
  - Step-by-step action plan

  ## Arguments

  - `task` - The task or problem to plan for (string)
  - Can also be called with no arguments to plan the current conversation

  ## Returns

  A confirmation message. The plan is stored in context for reference.
  """
  @spec plan(Nous.RunContext.t(), args()) :: result()
  def plan(ctx, args) do
    # Support multiple parameter formats
    task =
      Map.get(args, "task") || Map.get(args, "query") || Map.get(args, "problem") ||
        "Current task"

    timestamp = DateTime.utc_now() |> DateTime.to_string()

    plan_record = %{
      task: task,
      timestamp: timestamp,
      created_at: timestamp
    }

    # Store plan in context
    plans = [plan_record | ctx.deps[:plans] || []]

    Logger.info("ReAct: Plan created for task: #{String.slice(task, 0, 60)}...")

    %{
      success: true,
      message: """
      Plan created. Now analyze:

      📋 FACTS SURVEY:
      - What facts do you already know?
      - What facts do you need to look up?
      - What facts do you need to derive/calculate?

      📝 ACTION PLAN:
      - List the steps you'll take to solve this
      - Be specific about which tools you'll use

      Remember: Create todos for each major step!
      """,
      __update_context__: %{plans: plans}
    }
  end

  @doc """
  Record an observation or insight during the reasoning process.

  Use this to document important findings, intermediate results,
  or thoughts that will inform future actions.

  ## Arguments

  - `content` - The note content (string)

  ## Returns

  Confirmation message.
  """
  @spec note(Nous.RunContext.t(), args()) :: result()
  # A schema-violating call gets a sentence it can act on rather than a
  # `FunctionClauseError`. Models do ignore schemas, and a raise told the model only
  # that something exploded, so it retried the same malformed call and spent the
  # iteration budget. The happy path stays the first clause, so a correct call pays
  # nothing for this.
  def note(_ctx, args) when is_map(args) and not is_map_key(args, "content") do
    {:error, "note requires a `content` parameter: the observation or finding to record."}
  end

  def note(ctx, %{"content" => content}) do
    timestamp = DateTime.utc_now() |> DateTime.to_string()

    note_record = %{
      content: content,
      timestamp: timestamp
    }

    notes = [note_record | ctx.deps[:notes] || []]

    Logger.debug("ReAct: Note recorded: #{String.slice(content, 0, 60)}...")

    %{
      success: true,
      message: "Note recorded: #{content}",
      __update_context__: %{notes: notes}
    }
  end

  @doc """
  Add a task to the todo list.

  Use this to break down complex problems into manageable subtasks.
  Track what needs to be done and maintain focus.

  ## Arguments

  - `item` - Description of the todo item (string)
  - `priority` - Optional priority: "high", "medium", "low" (default: "medium")

  ## Returns

  Confirmation with current todo count.
  """
  @spec add_todo(Nous.RunContext.t(), args()) :: result()
  def add_todo(ctx, args) do
    item = Map.get(args, "item") || Map.get(args, "task", "")
    priority = Map.get(args, "priority", "medium")

    timestamp = DateTime.utc_now() |> DateTime.to_string()

    todos = ctx.deps[:todos] || []
    next_id = length(todos) + 1

    new_todo = %{
      id: next_id,
      item: item,
      priority: priority,
      status: :pending,
      created_at: timestamp
    }

    updated_todos = todos ++ [new_todo]

    Logger.info("ReAct: Todo added (##{next_id}): #{item}")

    %{
      success: true,
      message: "✓ Added todo ##{next_id}: #{item} (#{length(updated_todos)} total todos)",
      todo_id: next_id,
      __update_context__: %{todos: updated_todos}
    }
  end

  @doc """
  Mark a todo item as complete.

  ## Arguments

  - `id` - The todo ID to complete (integer)

  OR

  - `item` - Description matching the todo item (string)

  ## Returns

  Confirmation message.
  """
  @spec complete_todo(Nous.RunContext.t(), args()) :: result()
  def complete_todo(ctx, args) do
    todos = ctx.deps[:todos] || []

    # Support both id and item-based completion
    {completed_id, updated_todos} =
      cond do
        Map.has_key?(args, "id") ->
          id = args["id"]
          complete_by_id(todos, id)

        Map.has_key?(args, "item") ->
          item = args["item"]
          complete_by_item(todos, item)

        true ->
          {nil, todos}
      end

    if completed_id do
      completed_count = Enum.count(updated_todos, fn t -> t.status == :completed end)
      pending_count = Enum.count(updated_todos, fn t -> t.status == :pending end)

      Logger.info(
        "ReAct: Todo ##{completed_id} completed (#{completed_count}/#{length(updated_todos)} done)"
      )

      %{
        success: true,
        message: "✓ Completed todo ##{completed_id} (#{pending_count} remaining)",
        completed_id: completed_id,
        stats: %{completed: completed_count, pending: pending_count, total: length(updated_todos)},
        __update_context__: %{todos: updated_todos}
      }
    else
      %{
        success: false,
        message: "Todo not found. Use list_todos to see available todos.",
        __update_context__: %{}
      }
    end
  end

  @doc """
  List all current todos with their status.

  Shows pending and completed tasks to help track progress.

  ## Returns

  Formatted list of todos.
  """
  @spec list_todos(Nous.RunContext.t(), args()) :: result()
  def list_todos(ctx, _args \\ %{}) do
    todos = ctx.deps[:todos] || []

    if Enum.empty?(todos) do
      %{
        success: true,
        message: "No todos yet. Use add_todo to create tasks.",
        todos: []
      }
    else
      pending = Enum.filter(todos, fn t -> t.status == :pending end)
      completed = Enum.filter(todos, fn t -> t.status == :completed end)

      formatted_pending = format_todos(pending, "📝 PENDING")
      formatted_completed = format_todos(completed, "✅ COMPLETED")

      message = """
      #{formatted_pending}

      #{formatted_completed}

      Progress: #{length(completed)}/#{length(todos)} completed
      """

      %{
        success: true,
        message: message,
        todos: todos,
        stats: %{
          pending: length(pending),
          completed: length(completed),
          total: length(todos)
        }
      }
    end
  end

  @doc """
  Provide the final answer to complete the task.

  This tool MUST be called to signal task completion.
  The agent should only use this after gathering all necessary
  information and solving the problem.

  ## Arguments

  - `answer` - The final answer or solution (string)

  ## Returns

  The final answer wrapped with completion metadata.
  """
  @spec final_answer(Nous.RunContext.t(), args()) :: result()
  # Same reasoning as `note/2` above: a missing `answer` is the model's mistake to
  # correct, so tell it what to send.
  def final_answer(_ctx, args) when is_map(args) and not is_map_key(args, "answer") do
    {:error, "final_answer requires an `answer` parameter: your complete solution."}
  end

  def final_answer(ctx, %{"answer" => answer}) do
    todos = ctx.deps[:todos] || []
    plans = ctx.deps[:plans] || []
    notes = ctx.deps[:notes] || []

    completed_todos = Enum.count(todos, fn t -> t.status == :completed end)
    pending_todos = Enum.count(todos, fn t -> t.status == :pending end)

    Logger.info(
      "ReAct: Final answer provided (#{completed_todos}/#{length(todos)} todos completed)"
    )

    if pending_todos > 0 do
      Logger.warning("ReAct: Task completed with #{pending_todos} pending todos")
    end

    %{
      success: true,
      final_answer: answer,
      message: """
      🎯 FINAL ANSWER:
      #{answer}

      📊 Task Summary:
      - Todos completed: #{completed_todos}/#{length(todos)}
      - Plans created: #{length(plans)}
      - Notes recorded: #{length(notes)}
      """,
      metadata: %{
        todos_completed: completed_todos,
        todos_pending: pending_todos,
        plans_count: length(plans),
        notes_count: length(notes)
      }
    }
  end

  # Private helper functions

  defp complete_by_id(todos, id) do
    case Enum.find_index(todos, fn t -> t.id == id end) do
      nil ->
        {nil, todos}

      index ->
        updated_todos =
          List.update_at(todos, index, fn todo ->
            todo
            |> Map.put(:status, :completed)
            |> Map.put(:completed_at, DateTime.utc_now() |> DateTime.to_string())
          end)

        {id, updated_todos}
    end
  end

  defp complete_by_item(todos, item) do
    # Find by matching item text (case-insensitive partial match)
    item_lower = String.downcase(item)

    case Enum.find_index(todos, fn t ->
           String.contains?(String.downcase(t.item), item_lower)
         end) do
      nil ->
        {nil, todos}

      index ->
        todo = Enum.at(todos, index)

        updated_todos =
          List.update_at(todos, index, fn t ->
            t
            |> Map.put(:status, :completed)
            |> Map.put(:completed_at, DateTime.utc_now() |> DateTime.to_string())
          end)

        {todo.id, updated_todos}
    end
  end

  defp format_todos([], _header), do: ""

  defp format_todos(todos, header) do
    formatted_items =
      todos
      |> Enum.map(fn todo ->
        priority_icon =
          case todo.priority do
            "high" -> "🔴"
            "low" -> "🟢"
            _ -> "🟡"
          end

        status_icon = if todo.status == :completed, do: "✅", else: "📝"

        "  #{status_icon} #{priority_icon} ##{todo.id}: #{todo.item}"
      end)
      |> Enum.join("\n")

    """
    #{header}:
    #{formatted_items}
    """
  end
end
