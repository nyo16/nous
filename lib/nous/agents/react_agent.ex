defmodule Nous.Agents.ReActAgent do
  @moduledoc """
  ReAct (Reasoning and Acting) Agent behaviour implementation.

  ReAct is a prompting paradigm where AI agents interleave:
  - **Reasoning**: Thinking about what to do next
  - **Acting**: Using tools to gather information or perform actions
  - **Observing**: Processing results to inform the next step

  This module implements `Nous.Agent.Behaviour` with enhanced capabilities:
  - Structured planning with facts survey
  - Built-in todo list management
  - Note-taking for observations
  - Loop prevention (warns on duplicate tool calls)
  - Mandatory `final_answer` for task completion

  ## Built-in Tools

  - `plan` - Create structured plan before taking action
  - `note` - Record observations and insights
  - `add_todo` - Track subtasks
  - `complete_todo` - Mark tasks done
  - `list_todos` - View current todos
  - `final_answer` - Complete the task (required)

  ## Example

      agent = Agent.new("openai:gpt-4",
        behaviour_module: Nous.Agents.ReActAgent,
        tools: [&search/2, &calculate/2]
      )

      {:ok, result} = Agent.run(agent,
        "Find the oldest F1 driver and when they won their first championship"
      )

  ## Based on Research

  This implementation draws from:
  - "ReAct: Synergizing Reasoning and Acting in Language Models" (Yao et al., 2023)
  - HuggingFace smolagents toolcalling_agent patterns
  """

  @behaviour Nous.Agent.Behaviour

  alias Nous.{Message, Messages, Tool}
  alias Nous.Agent.Context
  alias Nous.Tools.ReActTools

  # System prompt that teaches the ReAct pattern
  @react_system_prompt """
  You are a ReAct (Reasoning + Acting) agent that solves problems through structured thinking and tool use.

  MANDATORY WORKFLOW:
  1. PLAN FIRST: Call 'plan' to create a structured approach
     - Identify known facts, facts to look up, facts to derive
     - Create step-by-step action plan

  2. TRACK TASKS: Use 'add_todo' for each major step
     - Break complex problems into subtasks
     - Track progress as you work

  3. ACT & OBSERVE: Use tools to gather information
     - Each tool call creates an observation
     - Call 'note' to record important findings
     - Mark 'complete_todo' as you finish each step

  4. COMPLETE: Call 'final_answer' when done
     - REQUIRED to finish the task
     - Provide complete, well-reasoned answer

  IMPORTANT RULES:
  - Never repeat the exact same tool call with identical parameters
  - Always explain your reasoning before acting
  - Use 'list_todos' to check progress
  - Complete all pending todos before calling final_answer
  - Call 'note' to document important observations

  EXAMPLE FLOW:
  1. User asks question
  2. You call 'plan' with the question
  3. You call 'add_todo' for each step
  4. You use tools (search, calculate, etc.) to gather info
  5. You call 'complete_todo' as you finish each step
  6. You call 'final_answer' with the complete solution

  Remember: Think step-by-step, document your process, and always provide a final_answer!
  """

  @doc """
  Initialize context for ReAct execution.

  Sets up ReAct-specific state:
  - `todos` - Task list
  - `plans` - Planning history
  - `notes` - Observations
  - `tool_history` - Loop detection
  - `final_answer` - Captured final answer
  """
  @impl true
  def init_context(_agent, ctx) do
    # Initialize ReAct-specific deps
    ctx
    |> Context.merge_deps(%{
      todos: Map.get(ctx.deps, :todos, []),
      plans: Map.get(ctx.deps, :plans, []),
      notes: Map.get(ctx.deps, :notes, []),
      tool_history: Map.get(ctx.deps, :tool_history, []),
      final_answer: nil
    })
  end

  @doc """
  Build messages with ReAct system prompt.

  Combines the ReAct system prompt with any user instructions.
  """
  @impl true
  def build_messages(agent, ctx) do
    # Build system prompt
    system_prompt = build_react_system_prompt(agent, ctx)

    # Filter out existing system messages
    non_system_messages = Enum.reject(ctx.messages, &Message.is_system?/1)

    # Return messages with ReAct system prompt first
    if system_prompt do
      [Message.system(system_prompt) | non_system_messages]
    else
      non_system_messages
    end
  end

  @doc """
  Process response and check for final_answer.

  Updates context and sets `needs_response` to false when
  final_answer tool is called.
  """
  @impl true
  def process_response(_agent, response, ctx) do
    # Add message to context
    ctx = Context.add_message(ctx, response)

    # Check if final_answer was called
    tool_calls = response.tool_calls || []

    has_final_answer =
      Enum.any?(tool_calls, fn call ->
        call.name == "final_answer" or call[:name] == "final_answer"
      end)

    if has_final_answer do
      # Extract final answer from tool call
      final_call =
        Enum.find(tool_calls, fn call ->
          call.name == "final_answer" or call[:name] == "final_answer"
        end)

      answer =
        get_in(final_call, [:arguments, "answer"]) ||
          get_in(final_call, [:arguments, :answer]) ||
          "No answer provided"

      ctx
      |> Context.merge_deps(%{final_answer: answer})
      |> Context.set_needs_response(false)
    else
      # Continue processing - needs_response is already set by add_message
      ctx
    end
  end

  @doc """
  Extract output from final_answer or last assistant message.
  """
  @impl true
  def extract_output(_agent, ctx) do
    # First check for captured final_answer
    case ctx.deps[:final_answer] do
      nil ->
        # Fall back to last assistant message
        case find_last_assistant_text(ctx.messages) do
          nil -> {:error, :no_output}
          text -> {:ok, text}
        end

      answer ->
        {:ok, answer}
    end
  end

  @doc """
  Get all tools including ReAct-specific tools.
  """
  @impl true
  def get_tools(agent) do
    react_tools() ++ agent.tools
  end

  @doc """
  Track tool calls for loop detection.
  """
  @impl true
  def after_tool(_agent, call, _result, ctx) do
    # Record tool call in history
    history_entry = %{
      name: call.name || call[:name],
      arguments: call.arguments || call[:arguments],
      timestamp: DateTime.utc_now()
    }

    tool_history = [history_entry | ctx.deps[:tool_history] || []]

    # Check for duplicate calls (loop detection)
    if is_duplicate_call?(call, ctx.deps[:tool_history] || []) do
      require Logger
      Logger.warning("ReAct loop detection: duplicate tool call #{call.name || call[:name]}")
    end

    Context.merge_deps(ctx, %{tool_history: tool_history})
  end

  # Private helpers

  defp build_react_system_prompt(agent, ctx) do
    # Start with base ReAct prompt
    base_prompt = @react_system_prompt

    # Add user instructions if present
    user_instructions = agent.instructions || ctx.system_prompt

    if user_instructions do
      """
      #{base_prompt}

      ADDITIONAL CONTEXT:
      #{user_instructions}
      """
    else
      base_prompt
    end
  end

  defp react_tools do
    [
      Tool.from_function(&ReActTools.plan/2,
        name: "plan",
        description:
          "Create a structured plan for solving the task. Analyzes known facts, facts to look up, and facts to derive. Use this FIRST before taking any actions."
      ),
      Tool.from_function(&ReActTools.note/2,
        name: "note",
        description:
          "Record an observation, insight, or intermediate finding. Use this to document important information discovered during your work."
      ),
      Tool.from_function(&ReActTools.add_todo/2,
        name: "add_todo",
        description:
          "Add a task to your todo list. Use this to break down complex problems into manageable subtasks. Parameters: item (required), priority (optional: high/medium/low)."
      ),
      Tool.from_function(&ReActTools.complete_todo/2,
        name: "complete_todo",
        description:
          "Mark a todo item as complete. Parameters: id (todo number) OR item (description matching the todo)."
      ),
      Tool.from_function(&ReActTools.list_todos/2,
        name: "list_todos",
        description:
          "View all current todos with their status. Shows pending and completed tasks to help track progress."
      ),
      Tool.from_function(&ReActTools.final_answer/2,
        name: "final_answer",
        description:
          "Provide the final answer to complete the task. REQUIRED to finish. Only call this after you have gathered all necessary information and solved the problem. Parameter: answer (your complete solution)."
      )
    ]
  end

  defp find_last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = msg -> Messages.extract_text(msg)
      _ -> nil
    end)
  end

  defp is_duplicate_call?(call, history) do
    call_name = call.name || call[:name]
    call_args = call.arguments || call[:arguments]

    Enum.any?(history, fn entry ->
      entry.name == call_name and entry.arguments == call_args
    end)
  end
end
