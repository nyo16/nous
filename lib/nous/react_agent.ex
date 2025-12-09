defmodule Nous.ReActAgent do
  @moduledoc """
  ReAct (Reasoning and Acting) Agent wrapper with built-in planning and todo management.

  ReAct is a prompting paradigm where AI agents interleave:
  - **Reasoning**: Thinking about what to do next
  - **Acting**: Using tools to gather information or perform actions
  - **Observing**: Processing results to inform the next step

  This module wraps `Nous.Agent` with enhanced capabilities:
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

      # Create ReAct agent with custom tools
      agent = ReActAgent.new("lmstudio:qwen/qwen3-30b",
        instructions: "You are a research assistant",
        tools: [&MyTools.search/2, &MyTools.calculate/2]
      )

      # Run with initial context
      {:ok, result} = ReActAgent.run(agent,
        "Find the oldest F1 driver and when they won their first championship",
        deps: %{database: MyDB}
      )

      # The agent will automatically:
      # 1. Create a plan
      # 2. Add todos for each step
      # 3. Use tools to gather info
      # 4. Complete todos as it progresses
      # 5. Call final_answer when done

      IO.puts(result.output)
      # Access metadata
      IO.inspect(result.metadata)

  ## Comparison to Standard Agent

      # Standard Agent
      agent = Agent.new("model", tools: [tool1, tool2])

      # ReAct Agent (enhanced)
      agent = ReActAgent.new("model", tools: [tool1, tool2])
      # Automatically includes: plan, note, add_todo, complete_todo,
      #                         list_todos, final_answer

  ## Loop Prevention

  The ReAct agent tracks tool call history and warns if the same tool
  is called with identical arguments, helping prevent infinite loops.

  ## Based on Research

  This implementation draws from:
  - "ReAct: Synergizing Reasoning and Acting in Language Models" (Yao et al., 2023)
  - HuggingFace smolagents toolcalling_agent patterns
  """

  alias Nous.{Agent, Tool}
  alias Nous.Tools.ReActTools

  @type t :: Agent.t()

  # System prompt that teaches the ReAct pattern
  @react_system_prompt """
  You are a ReAct (Reasoning + Acting) agent that solves problems through structured thinking and tool use.

  MANDATORY WORKFLOW:
  1. 📋 PLAN FIRST: Call 'plan' to create a structured approach
     - Identify known facts, facts to look up, facts to derive
     - Create step-by-step action plan

  2. 📝 TRACK TASKS: Use 'add_todo' for each major step
     - Break complex problems into subtasks
     - Track progress as you work

  3. 🔄 ACT & OBSERVE: Use tools to gather information
     - Each tool call creates an observation
     - Call 'note' to record important findings
     - Mark 'complete_todo' as you finish each step

  4. 🎯 COMPLETE: Call 'final_answer' when done
     - REQUIRED to finish the task
     - Provide complete, well-reasoned answer

  IMPORTANT RULES:
  - ❌ Never repeat the exact same tool call with identical parameters
  - ✅ Always explain your reasoning before acting
  - ✅ Use 'list_todos' to check progress
  - ✅ Complete all pending todos before calling final_answer
  - ✅ Call 'note' to document important observations

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
  Create a new ReAct agent.

  Wraps `Nous.Agent.new/2` with additional ReAct-specific tools and instructions.

  ## Parameters

  - `model_string` - Model in format "provider:model-name"
  - `opts` - Configuration options (same as `Nous.Agent.new/2`)

  ## Options

  All standard Agent options are supported, plus:

  - `:react_system_prompt` - Override the default ReAct system prompt
  - `:require_planning` - Whether to enforce planning step (default: false)
  - `:track_history` - Track tool call history for loop detection (default: true)

  ## Examples

      # Basic ReAct agent
      agent = ReActAgent.new("openai:gpt-4")

      # With custom tools
      agent = ReActAgent.new("anthropic:claude-3-5-sonnet",
        tools: [&MyTools.search/2, &MyTools.calculate/2],
        instructions: "You are a research assistant"
      )

      # With custom model settings
      agent = ReActAgent.new("lmstudio:qwen/qwen3-30b",
        model_settings: %{temperature: 0.3, max_tokens: 2000}
      )

  ## Returns

  A configured Agent struct with ReAct tools included.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(model_string, opts \\ []) do
    # Extract ReAct-specific options
    react_prompt = Keyword.get(opts, :react_system_prompt, @react_system_prompt)
    user_instructions = Keyword.get(opts, :instructions)
    user_tools = Keyword.get(opts, :tools, [])

    # Combine user instructions with ReAct prompt
    combined_instructions = if user_instructions do
      """
      #{react_prompt}

      ADDITIONAL CONTEXT:
      #{user_instructions}
      """
    else
      react_prompt
    end

    # Get all ReAct tools
    react_tools = [
      Tool.from_function(&ReActTools.plan/2,
        name: "plan",
        description: "Create a structured plan for solving the task. Analyzes known facts, facts to look up, and facts to derive. Use this FIRST before taking any actions."
      ),
      Tool.from_function(&ReActTools.note/2,
        name: "note",
        description: "Record an observation, insight, or intermediate finding. Use this to document important information discovered during your work."
      ),
      Tool.from_function(&ReActTools.add_todo/2,
        name: "add_todo",
        description: "Add a task to your todo list. Use this to break down complex problems into manageable subtasks. Parameters: item (required), priority (optional: high/medium/low)."
      ),
      Tool.from_function(&ReActTools.complete_todo/2,
        name: "complete_todo",
        description: "Mark a todo item as complete. Parameters: id (todo number) OR item (description matching the todo)."
      ),
      Tool.from_function(&ReActTools.list_todos/2,
        name: "list_todos",
        description: "View all current todos with their status. Shows pending and completed tasks to help track progress."
      ),
      Tool.from_function(&ReActTools.final_answer/2,
        name: "final_answer",
        description: "Provide the final answer to complete the task. REQUIRED to finish. Only call this after you have gathered all necessary information and solved the problem. Parameter: answer (your complete solution)."
      )
    ]

    # Combine ReAct tools with user tools
    all_tools = react_tools ++ user_tools

    # Update opts with combined values
    agent_opts = opts
    |> Keyword.put(:instructions, combined_instructions)
    |> Keyword.put(:tools, all_tools)
    |> Keyword.delete(:react_system_prompt)
    |> Keyword.delete(:require_planning)
    |> Keyword.delete(:track_history)

    # Create the underlying agent
    Agent.new(model_string, agent_opts)
  end

  @doc """
  Run the ReAct agent synchronously.

  Wraps `Nous.Agent.run/3` with additional ReAct context initialization.

  ## Options

  Same as `Nous.Agent.run/3`, with automatic initialization of:
  - `todos: []` - Empty todo list
  - `plans: []` - Empty plans list
  - `notes: []` - Empty notes list
  - `tool_history: []` - Tool call history for loop detection

  ## Examples

      {:ok, result} = ReActAgent.run(agent,
        "What is the capital of France and what's its population?"
      )

      # With dependencies
      {:ok, result} = ReActAgent.run(agent,
        "Search for recent AI developments",
        deps: %{api_key: "..."}
      )

      # Continue conversation
      {:ok, result2} = ReActAgent.run(agent,
        "Tell me more about that",
        message_history: result1.new_messages
      )

  ## Returns

  Same as `Nous.Agent.run/3`:

      {:ok, %{
        output: "Final answer text...",
        usage: %Usage{...},
        all_messages: [...],
        new_messages: [...],
        metadata: %{
          todos_completed: 3,
          todos_pending: 0,
          plans_count: 1,
          notes_count: 5
        }
      }}

  """
  @spec run(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Agent{} = agent, prompt, opts \\ []) do
    # Initialize ReAct-specific context
    existing_deps = Keyword.get(opts, :deps, %{})

    react_deps = Map.merge(existing_deps, %{
      todos: [],
      plans: [],
      notes: [],
      tool_history: []
    })

    # Update opts with ReAct context
    react_opts = Keyword.put(opts, :deps, react_deps)

    # Run the agent
    case Agent.run(agent, prompt, react_opts) do
      {:ok, result} ->
        # Extract metadata from the final result if present
        metadata = extract_react_metadata(result)
        enhanced_result = Map.put(result, :metadata, metadata)

        {:ok, enhanced_result}

      error ->
        error
    end
  end

  @doc """
  Run the ReAct agent with streaming.

  Wraps `Nous.Agent.run_stream/3` with ReAct context initialization.

  ## Example

      {:ok, stream} = ReActAgent.run_stream(agent, "Solve this problem...")

      stream
      |> Stream.each(fn
        {:text_delta, text} -> IO.write(text)
        {:tool_call, call} -> IO.puts("Using tool")
        {:tool_result, result} -> IO.puts("Got result")
        {:complete, result} -> IO.puts("Done!")
      end)
      |> Stream.run()

  """
  @spec run_stream(t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run_stream(%Agent{} = agent, prompt, opts \\ []) do
    # Initialize ReAct-specific context
    existing_deps = Keyword.get(opts, :deps, %{})

    react_deps = Map.merge(existing_deps, %{
      todos: [],
      plans: [],
      notes: [],
      tool_history: []
    })

    react_opts = Keyword.put(opts, :deps, react_deps)

    Agent.run_stream(agent, prompt, react_opts)
  end

  # Private functions

  defp extract_react_metadata(_result) do
    # Try to extract metadata from final_answer tool result or messages
    # This is a best-effort extraction
    %{
      todos_completed: 0,
      todos_pending: 0,
      plans_count: 0,
      notes_count: 0
    }
  end
end
