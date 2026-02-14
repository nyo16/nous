defmodule Nous.Plugins.SubAgent do
  @moduledoc """
  Plugin that enables agents to delegate tasks to specialized child agents.

  Provides a `delegate_task` tool that spawns a child agent with its own
  isolated context, runs it to completion, and returns the result.

  ## Usage

      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.SubAgent],
        deps: %{
          sub_agent_templates: %{
            "researcher" => %{
              model: "openai:gpt-4o-mini",
              instructions: "You are a research specialist. Find accurate information.",
              tools: [&MyTools.web_search/2]
            },
            "coder" => %{
              model: "openai:gpt-4",
              instructions: "You are a coding specialist. Write clean Elixir code."
            }
          }
        }
      )

  ## Templates

  Pre-configured agent templates can be provided via `deps[:sub_agent_templates]`.
  The `delegate_task` tool can reference a template by name or provide inline config.
  """

  @behaviour Nous.Plugin

  alias Nous.Tool

  require Logger

  @impl true
  def init(_agent, ctx) do
    # Ensure sub-agent tracking exists
    templates = ctx.deps[:sub_agent_templates] || %{}

    %{ctx | deps: Map.put_new(ctx.deps, :sub_agent_templates, templates)}
  end

  @impl true
  def tools(_agent, _ctx) do
    [delegate_task_tool()]
  end

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

  @doc false
  def delegate_task(ctx, args) do
    task = Map.fetch!(args, "task")
    template_name = Map.get(args, "template")

    config = resolve_agent_config(ctx, template_name, args)

    case config do
      {:ok, agent_config} ->
        run_sub_agent(agent_config, task, ctx)

      {:error, reason} ->
        %{success: false, error: reason}
    end
  end

  defp resolve_agent_config(ctx, template_name, _args) when is_binary(template_name) do
    templates = ctx.deps[:sub_agent_templates] || %{}

    case Map.get(templates, template_name) do
      nil ->
        available = Map.keys(templates) |> Enum.join(", ")
        {:error, "Template '#{template_name}' not found. Available: #{available}"}

      template ->
        {:ok, template}
    end
  end

  defp resolve_agent_config(_ctx, nil, args) do
    model = Map.get(args, "model")

    if model do
      {:ok,
       %{
         model: model,
         instructions: Map.get(args, "instructions", "Complete the given task thoroughly."),
         tools: []
       }}
    else
      {:error, "Either 'template' or 'model' must be provided for sub-agent delegation."}
    end
  end

  defp run_sub_agent(config, task, parent_ctx) do
    model = Map.get(config, :model) || Map.get(config, "model")
    instructions = Map.get(config, :instructions) || Map.get(config, "instructions", "")
    tools = Map.get(config, :tools) || Map.get(config, "tools", [])

    Logger.info("Spawning sub-agent with model #{model} for task: #{String.slice(task, 0, 80)}")

    try do
      agent =
        Nous.Agent.new(model,
          instructions: instructions,
          tools: tools,
          model_settings: Map.get(config, :model_settings, %{})
        )

      # Run with isolated deps (only pass through explicitly shared keys)
      shared_keys = Map.get(config, :shared_deps, [])
      sub_deps = Map.take(parent_ctx.deps, shared_keys)

      case Nous.Agent.run(agent, task, deps: sub_deps, max_iterations: 10) do
        {:ok, result} ->
          Logger.info("Sub-agent completed successfully")

          %{
            success: true,
            result: result.output,
            tokens_used: result.usage.total_tokens,
            iterations: result.iterations
          }

        {:error, error} ->
          error_msg = if is_exception(error), do: Exception.message(error), else: inspect(error)
          Logger.warning("Sub-agent failed: #{error_msg}")
          %{success: false, error: error_msg}
      end
    rescue
      e ->
        Logger.error("Sub-agent crashed: #{Exception.message(e)}")
        %{success: false, error: "Sub-agent execution failed: #{Exception.message(e)}"}
    end
  end
end
