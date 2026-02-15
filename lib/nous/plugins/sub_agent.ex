defmodule Nous.Plugins.SubAgent do
  @moduledoc """
  Plugin that enables agents to delegate tasks to specialized sub-agents.

  Provides two tools:

    - `delegate_task` — run a single sub-agent for one task (sequential)
    - `spawn_agents` — run multiple sub-agents in parallel via `Task.Supervisor`

  ## Usage

      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.SubAgent],
        deps: %{
          sub_agent_templates: %{
            "researcher" => Agent.new("openai:gpt-4o-mini",
              instructions: "You are a research specialist. Find accurate information."
            ),
            "coder" => Agent.new("openai:gpt-4",
              instructions: "You are a coding specialist. Write clean Elixir code."
            )
          }
        }
      )

  ## Templates

  Pre-configured agent templates can be provided via `deps[:sub_agent_templates]`.
  Templates can be either `%Nous.Agent{}` structs or config maps:

      # Using Agent structs (recommended)
      "researcher" => Agent.new("openai:gpt-4o-mini", instructions: "Research specialist")

      # Using config maps (legacy)
      "researcher" => %{model: "openai:gpt-4o-mini", instructions: "Research specialist"}

  Both `delegate_task` and `spawn_agents` can reference templates by name or
  provide inline model/instructions for ad-hoc sub-agents.

  ## Parallel Configuration

  Configure concurrency and timeout for `spawn_agents` via `deps`:

    - `:parallel_max_concurrency` — max concurrent sub-agents (default: 5)
    - `:parallel_timeout` — per-task timeout in ms (default: 120_000)
  """

  @behaviour Nous.Plugin

  alias Nous.{Agent, Tool}

  require Logger

  @default_max_concurrency 5
  @default_timeout 120_000

  # ===========================================================================
  # Plugin callbacks
  # ===========================================================================

  @impl true
  def init(_agent, ctx) do
    templates = ctx.deps[:sub_agent_templates] || %{}

    deps =
      ctx.deps
      |> Map.put_new(:sub_agent_templates, templates)
      |> Map.put(:__sub_agent_pubsub__, ctx.pubsub)
      |> Map.put(:__sub_agent_pubsub_topic__, ctx.pubsub_topic)

    %{ctx | deps: deps}
  end

  @impl true
  def tools(_agent, _ctx) do
    [delegate_task_tool(), spawn_agents_tool()]
  end

  @impl true
  def system_prompt(_agent, ctx) do
    templates = ctx.deps[:sub_agent_templates] || %{}

    template_list =
      case Map.keys(templates) do
        [] -> "No templates configured. Use inline model and instructions for each task."
        names -> "Available templates: #{Enum.join(names, ", ")}"
      end

    """
    ## Sub-Agents

    You have two tools for delegating work to sub-agents:

    - `delegate_task` — run a single sub-agent for a focused task
    - `spawn_agents` — run multiple sub-agents in parallel

    #{template_list}

    ### When to use `delegate_task`
    - A single task that needs specialized handling
    - Sequential delegation where one result informs the next

    ### When to use `spawn_agents`
    - Researching multiple topics simultaneously
    - Analyzing different parts of a codebase in parallel
    - Generating content for separate sections at once
    - Any set of tasks where one result doesn't depend on another

    ### When NOT to use sub-agents
    - A single focused question you can answer directly
    - Tasks that share state or need to coordinate with each other

    ### Writing good sub-agent prompts
    Each sub-agent starts fresh with zero context. Include everything it needs:
    - What specifically to do
    - Any constraints (length, format, focus area)
    - Relevant background the sub-agent won't have
    """
  end

  # ===========================================================================
  # Tool definitions
  # ===========================================================================

  defp delegate_task_tool do
    %Tool{
      name: "delegate_task",
      description: """
      Delegate a task to a specialized sub-agent. The sub-agent runs independently \
      with its own context and returns a result. Use this when a task requires \
      specialized expertise or should be handled separately.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "The task description/prompt for the sub-agent"
          },
          "template" => %{
            "type" => "string",
            "description" =>
              "Name of a pre-configured agent template (e.g., 'researcher', 'coder')"
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Model string for inline agent config (e.g., 'openai:gpt-4o-mini'). Used when no template is specified."
          },
          "instructions" => %{
            "type" => "string",
            "description" =>
              "Instructions for inline agent config. Used when no template is specified."
          }
        },
        "required" => ["task"]
      },
      function: &__MODULE__.delegate_task/2,
      takes_ctx: true
    }
  end

  defp spawn_agents_tool do
    %Tool{
      name: "spawn_agents",
      description: """
      Spawn multiple sub-agents to work on tasks in parallel. Each sub-agent \
      runs independently with its own context and returns a result. Use this \
      when you have multiple independent tasks that can be worked on simultaneously, \
      such as researching different topics, analyzing separate modules, or \
      generating content for different sections.

      Each task in the array runs as a separate agent concurrently. Results are \
      collected and returned together once all tasks complete.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "tasks" => %{
            "type" => "array",
            "description" =>
              "List of tasks to run in parallel. Each task spawns a separate sub-agent.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "task" => %{
                  "type" => "string",
                  "description" => "The task description/prompt for this sub-agent"
                },
                "template" => %{
                  "type" => "string",
                  "description" =>
                    "Name of a pre-configured agent template (e.g., 'researcher', 'coder')"
                },
                "model" => %{
                  "type" => "string",
                  "description" =>
                    "Model for inline config (e.g., 'openai:gpt-4o-mini'). Used when no template."
                },
                "instructions" => %{
                  "type" => "string",
                  "description" =>
                    "Instructions for inline config. Used when no template is specified."
                }
              },
              "required" => ["task"]
            }
          }
        },
        "required" => ["tasks"]
      },
      function: &__MODULE__.spawn_agents/2,
      takes_ctx: true
    }
  end

  # ===========================================================================
  # delegate_task — single sub-agent
  # ===========================================================================

  @doc false
  def delegate_task(ctx, args) do
    task = Map.fetch!(args, "task")
    template_name = Map.get(args, "template")

    case resolve_agent(ctx, template_name, args) do
      {:ok, agent} ->
        case run_sub_agent(agent, task, ctx) do
          {:ok, result} ->
            %{
              success: true,
              result: result.output,
              tokens_used: result.tokens_used,
              iterations: result.iterations
            }

          {:error, error_msg} ->
            %{success: false, error: error_msg}
        end

      {:error, reason} ->
        %{success: false, error: reason}
    end
  end

  # ===========================================================================
  # spawn_agents — parallel sub-agents
  # ===========================================================================

  @doc false
  def spawn_agents(ctx, %{"tasks" => tasks}) when is_list(tasks) do
    max_concurrency = ctx.deps[:parallel_max_concurrency] || @default_max_concurrency
    timeout = ctx.deps[:parallel_timeout] || @default_timeout
    task_count = length(tasks)

    Logger.info(
      "Spawning #{task_count} parallel sub-agents (max_concurrency: #{max_concurrency})"
    )

    results =
      Nous.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        Enum.with_index(tasks),
        fn {task_spec, index} ->
          run_parallel_task(ctx, task_spec, index)
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(tasks)
      |> Enum.map(fn {stream_result, task_spec} ->
        format_parallel_result(stream_result, task_spec)
      end)

    succeeded = Enum.count(results, & &1.success)
    failed = task_count - succeeded

    Logger.info("Parallel sub-agents complete: #{succeeded} succeeded, #{failed} failed")

    %{
      total: task_count,
      succeeded: succeeded,
      failed: failed,
      results: results
    }
  end

  def spawn_agents(_ctx, _args) do
    %{success: false, error: "Missing required 'tasks' array"}
  end

  # ===========================================================================
  # Shared internals
  # ===========================================================================

  defp resolve_agent(ctx, template_name, _args) when is_binary(template_name) do
    templates = ctx.deps[:sub_agent_templates] || %{}

    case Map.get(templates, template_name) do
      nil ->
        available = Map.keys(templates) |> Enum.join(", ")
        {:error, "Template '#{template_name}' not found. Available: #{available}"}

      %Agent{} = agent ->
        {:ok, agent}

      %{} = config ->
        {:ok, agent_from_config(config)}
    end
  end

  defp resolve_agent(_ctx, nil, args) do
    model = Map.get(args, "model")

    if model do
      {:ok,
       Agent.new(model,
         instructions: Map.get(args, "instructions", "Complete the given task thoroughly.")
       )}
    else
      {:error, "Either 'template' or 'model' must be provided."}
    end
  end

  defp agent_from_config(config) do
    model = Map.get(config, :model) || Map.get(config, "model")
    instructions = Map.get(config, :instructions) || Map.get(config, "instructions", "")
    tools = Map.get(config, :tools) || Map.get(config, "tools", [])
    model_settings = Map.get(config, :model_settings) || Map.get(config, "model_settings", %{})

    Agent.new(model,
      instructions: instructions,
      tools: tools,
      model_settings: model_settings
    )
  end

  defp run_sub_agent(agent, task, parent_ctx, index \\ nil) do
    label = if index, do: "[sub-agent #{index}]", else: "[sub-agent]"
    Logger.info("#{label} Starting: #{String.slice(task, 0, 80)}")

    # Isolated deps — only pass through explicitly shared keys
    shared_keys = []
    sub_deps = Map.take(parent_ctx.deps, shared_keys)

    # Propagate PubSub with scoped topic
    parent_pubsub = parent_ctx.deps[:__sub_agent_pubsub__]
    parent_topic = parent_ctx.deps[:__sub_agent_pubsub_topic__]

    sub_suffix = if index, do: "parallel:#{index}", else: "sub"
    sub_topic = if parent_topic, do: "#{parent_topic}:#{sub_suffix}", else: nil

    run_opts = [
      deps: sub_deps,
      max_iterations: 10,
      pubsub: parent_pubsub,
      pubsub_topic: sub_topic
    ]

    case Agent.run(agent, task, run_opts) do
      {:ok, result} ->
        Logger.info("#{label} Completed successfully")

        {:ok,
         %{
           output: result.output,
           tokens_used: result.usage.total_tokens,
           iterations: result.iterations
         }}

      {:error, error} ->
        error_msg = if is_exception(error), do: Exception.message(error), else: inspect(error)
        Logger.warning("#{label} Failed: #{error_msg}")
        {:error, error_msg}
    end
  rescue
    e ->
      label = if index, do: "[sub-agent #{index}]", else: "[sub-agent]"
      Logger.error("#{label} Crashed: #{Exception.message(e)}")
      {:error, "Sub-agent execution failed: #{Exception.message(e)}"}
  end

  # ===========================================================================
  # Parallel-specific helpers
  # ===========================================================================

  defp run_parallel_task(ctx, task_spec, index) do
    task_prompt = Map.fetch!(task_spec, "task")
    template_name = Map.get(task_spec, "template")

    case resolve_agent(ctx, template_name, task_spec) do
      {:ok, agent} ->
        run_sub_agent(agent, task_prompt, ctx, index)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_parallel_result({:ok, {:ok, result}}, task_spec) do
    %{
      task: Map.get(task_spec, "task"),
      success: true,
      output: result.output,
      tokens_used: result.tokens_used,
      iterations: result.iterations
    }
  end

  defp format_parallel_result({:ok, {:error, reason}}, task_spec) do
    %{
      task: Map.get(task_spec, "task"),
      success: false,
      error: reason
    }
  end

  defp format_parallel_result({:exit, reason}, task_spec) do
    %{
      task: Map.get(task_spec, "task"),
      success: false,
      error: "Sub-agent crashed: #{inspect(reason)}"
    }
  end
end
