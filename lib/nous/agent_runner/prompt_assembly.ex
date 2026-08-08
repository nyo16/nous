defmodule Nous.AgentRunner.PromptAssembly do
  @moduledoc false
  # System-prompt and model-settings assembly helpers for Nous.AgentRunner:
  # todo injection, plugin system-prompt fragments, and structured-output
  # settings/synthetic-tool merging. Internal to the runner.

  alias Nous.{Message, Model, OutputSchema, Plugin, Tool}
  alias Nous.Agent
  alias Nous.Agent.Context

  require Logger

  # `deps[:todos]` is written by two independent producers with different
  # shapes — Nous.Tools.TodoTools (string statuses, always a :priority) and
  # Nous.Tools.ReactTools (atom statuses, no :priority) — so a bare map is the
  # only shape guaranteed at this boundary.
  @type todo :: map()

  # Apply plugin system prompt fragments to context
  # Only applied once per iteration (on first iteration, or when system prompt needs updating)
  @spec apply_plugin_system_prompts(Agent.t(), Context.t()) :: Context.t()
  def apply_plugin_system_prompts(agent, ctx) do
    case Plugin.collect_system_prompts(agent.plugins, agent, ctx) do
      nil ->
        ctx

      plugin_prompt ->
        # Update the system message if it exists, otherwise inject one
        updated_messages =
          case ctx.messages do
            [%Message{role: :system} = sys | rest] ->
              updated_content = sys.content <> "\n\n" <> plugin_prompt
              [%{sys | content: updated_content} | rest]

            messages ->
              [Message.system(plugin_prompt) | messages]
          end

        %{ctx | messages: updated_messages}
    end
  end

  # Inject todos into system prompt
  @spec inject_todos_into_prompt(String.t(), map()) :: String.t()
  def inject_todos_into_prompt(instructions, deps) do
    todos = deps[:todos] || []

    if todos == [] do
      Logger.debug("No todos to inject into system prompt")
      instructions
    else
      in_progress = Enum.count(todos, &(&1.status == "in_progress"))
      pending = Enum.count(todos, &(&1.status == "pending"))
      completed = Enum.count(todos, &(&1.status == "completed"))

      Logger.debug(
        "Injecting #{length(todos)} todos into system prompt (in_progress: #{in_progress}, pending: #{pending}, completed: #{completed})"
      )

      todo_section = format_todos_for_prompt(todos)

      """
      #{instructions}

      ## Current Task Progress

      #{todo_section}

      You have access to todo management tools:
      - add_todo(text, status?, priority?) - Create new task
      - update_todo(id, text?, status?, priority?) - Update existing task
      - complete_todo(id) - Mark task as completed
      - list_todos(status?, priority?) - List all tasks

      Use these tools to track your progress and stay organized.
      """
    end
  end

  @spec format_todos_for_prompt([todo()]) :: String.t()
  def format_todos_for_prompt(todos) do
    grouped = Enum.group_by(todos, & &1.status)

    section_defs = [
      {"in_progress", "In Progress",
       fn todo ->
         "  #{priority_icon(todo.priority)} [#{todo.id}] #{todo.text}"
       end},
      {"pending", "Pending",
       fn todo ->
         "  #{priority_icon(todo.priority)} [#{todo.id}] #{todo.text}"
       end},
      {"completed", "Completed",
       fn todo ->
         "  * [#{todo.id}] #{todo.text}"
       end}
    ]

    sections =
      Enum.flat_map(section_defs, fn {status, label, formatter} ->
        case Map.get(grouped, status, []) do
          [] ->
            []

          items ->
            list = Enum.map_join(items, "\n", formatter)
            ["\n#{label} (#{length(items)}):\n#{list}"]
        end
      end)

    case sections do
      [] -> "No tasks yet. Use add_todo() to create tasks."
      _ -> Enum.join(sections, "\n")
    end
  end

  @spec priority_icon(term()) :: String.t()
  def priority_icon("high"), do: "[HIGH]"
  def priority_icon("medium"), do: "[MED]"
  def priority_icon("low"), do: "[LOW]"
  def priority_icon(_), do: "-"

  # --- Structured Output Helpers ---

  # Inject structured output settings into model_settings
  @spec inject_structured_output_settings(Agent.t(), map(), [Tool.t()]) :: map()
  def inject_structured_output_settings(agent, model_settings, all_tools) do
    mode = Keyword.get(agent.structured_output, :mode, :auto)

    so_settings =
      OutputSchema.to_provider_settings(
        agent.output_type,
        agent.model.provider,
        mode: mode,
        has_other_tools: not Enum.empty?(all_tools)
      )

    merge_structured_output_settings(model_settings, so_settings, agent.model.provider)
  end

  # Merge structured output settings into model_settings
  @spec merge_structured_output_settings(map(), map(), Model.provider()) :: map()
  def merge_structured_output_settings(model_settings, so_settings, provider) do
    # Handle synthetic tool injection separately
    {tool_settings, other_settings} =
      Map.split(so_settings, [
        :__structured_output_tool__,
        :__structured_output_tools__,
        :__structured_output_tool_choice__
      ])

    # Merge non-tool settings
    merged = Map.merge(model_settings, other_settings)

    inject_synthetic_tools(merged, tool_settings, provider)
  end

  # Append the synthetic structured-output tool(s) to whatever tools the agent
  # already carries, then apply the accompanying tool_choice. Plural arrives
  # from `{:one_of, schemas}`, singular from standard :tool_call mode; neither
  # key means there is nothing to inject.
  defp inject_synthetic_tools(
         merged,
         %{__structured_output_tools__: tools_list} = tool_settings,
         provider
       )
       when is_list(tools_list) do
    merged
    |> append_tools(Enum.map(tools_list, &format_synthetic_tool(&1, provider)))
    |> put_tool_choice(tool_settings)
  end

  defp inject_synthetic_tools(
         merged,
         %{__structured_output_tool__: tool} = tool_settings,
         provider
       ) do
    merged
    |> append_tools([format_synthetic_tool(tool, provider)])
    |> put_tool_choice(tool_settings)
  end

  defp inject_synthetic_tools(merged, _tool_settings, _provider), do: merged

  defp append_tools(merged, formatted_tools) do
    Map.put(merged, :tools, (merged[:tools] || []) ++ formatted_tools)
  end

  defp put_tool_choice(merged, tool_settings) do
    case tool_settings[:__structured_output_tool_choice__] do
      nil -> merged
      choice -> Map.put(merged, :tool_choice, choice)
    end
  end

  # Anthropic takes its own atom-keyed tool shape; every other provider gets
  # the synthetic tool exactly as OutputSchema built it.
  defp format_synthetic_tool(tool, :anthropic), do: convert_synthetic_tool_anthropic(tool)
  defp format_synthetic_tool(tool, _provider), do: tool

  # Convert synthetic tool to Anthropic format (atom keys).
  #
  # Cannot delegate to `Nous.Tool.Wire.to_anthropic/1`: that takes a `%Nous.Tool{}`
  # and a synthetic tool arrives as a raw string-keyed map. The `|| %{}` / `|| []`
  # fallbacks are load-bearing — Anthropic 400s on a null properties/required.
  @spec convert_synthetic_tool_anthropic(map()) :: %{
          name: String.t() | nil,
          description: String.t() | nil,
          input_schema: map()
        }
  def convert_synthetic_tool_anthropic(tool) do
    func = tool["function"]

    %{
      name: func["name"],
      description: func["description"],
      input_schema: %{
        type: "object",
        properties: func["parameters"]["properties"] || %{},
        required: func["parameters"]["required"] || []
      }
    }
  end
end
