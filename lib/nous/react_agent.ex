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
      agent = ReActAgent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
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

  alias Nous.Agent

  # 30_000 tokens fits inside a 32k-window local model with room for the reply, and
  # is ample for ReAct's narrow steps. `keep_recent: 8` keeps the last few
  # observe/act pairs verbatim so the model can still see what it just did.
  #
  # Two directions to tune it, and they pull opposite ways. A large-window cloud
  # model can afford far more. A SLOW model wants LESS: measured on a 27B Q8 local
  # model at ~13 tokens/sec, one ReAct-shaped request took 72.7s, and a request
  # carrying a prompt near this ceiling exceeded even a 5-minute per-request budget.
  # The budget that keeps a fast model sharp is the one that makes a slow model time
  # out, so there is no single right number here — only a safe starting point.
  @default_summarization %{max_context_tokens: 30_000, keep_recent: 8}

  @type t :: Agent.t()

  @doc """
  Create a new ReAct agent.

  Wraps `Nous.Agent.new/2` with ReAct behaviour module.

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
      agent = ReActAgent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        model_settings: %{temperature: 0.3, max_tokens: 2000}
      )

  ## Returns

  A configured Agent struct with ReAct behaviour.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(model_string, opts \\ []) do
    # Use the new behaviour-based implementation
    # Remove ReAct-specific options that are handled by the behaviour
    agent_opts =
      opts
      |> Keyword.put(:behaviour_module, Nous.Agents.ReActAgent)
      |> Keyword.delete(:react_system_prompt)
      |> Keyword.delete(:require_planning)
      |> Keyword.delete(:track_history)
      |> with_context_management()

    # Create the underlying agent with ReAct behaviour
    Agent.new(model_string, agent_opts)
  end

  # ReAct is the one agent shape whose defining feature is looping, so it is the
  # one that must not be handed an unbounded transcript. Measured here against a
  # local model on a single "plan the area of a rectangle" task:
  #
  #   no context management -> a 170,732-token request against a 32,000-token
  #                            window, refused by the server after 775s
  #   with this default     -> done in 3 iterations, 4,866 peak tokens, 19.8s
  #
  # Enabling it costs nothing on the common path: the plugin prunes oversized tool
  # results first, which is free, and only pays for an LLM summarization if the
  # transcript is still over budget after that.
  #
  # The budget is deliberately below the plugin's own 100_000 default. ReAct steps
  # are narrow by construction, and a ceiling above a small local model's entire
  # window protects nobody — at 100_000 every measurement above fails exactly as it
  # did. Callers on a large-window model should raise it.
  #
  # Supplying your own `plugins:` or `summarization_config` replaces this; nothing
  # is forced on a caller who has an opinion.
  #
  # Only `:plugins` is set here. `%Nous.Agent{}` carries no `:deps` — dependencies
  # arrive per run — so the matching budget is applied in `run/3` and
  # `run_stream/3` rather than here, where it would be silently dropped.
  defp with_context_management(opts) do
    Keyword.put_new_lazy(opts, :plugins, fn -> [Nous.Plugins.Summarization] end)
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

    react_deps =
      existing_deps
      |> Map.merge(%{
        todos: [],
        plans: [],
        notes: [],
        tool_history: []
      })
      |> Map.put_new(:summarization_config, @default_summarization)

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

    react_deps =
      existing_deps
      |> Map.merge(%{
        todos: [],
        plans: [],
        notes: [],
        tool_history: []
      })
      |> Map.put_new(:summarization_config, @default_summarization)

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
