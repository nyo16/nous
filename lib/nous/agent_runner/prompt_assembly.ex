defmodule Nous.AgentRunner.PromptAssembly do
  @moduledoc false
  # System-prompt and model-settings assembly helpers for Nous.AgentRunner:
  # todo injection, plugin system-prompt fragments, and structured-output
  # settings/synthetic-tool merging. Internal to the runner.

  alias Nous.{Message, OutputSchema, Plugin}

  require Logger

  # Apply plugin system prompt fragments to context
  # Only applied once per iteration (on first iteration, or when system prompt needs updating)
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

  def priority_icon("high"), do: "[HIGH]"
  def priority_icon("medium"), do: "[MED]"
  def priority_icon("low"), do: "[LOW]"
  def priority_icon(_), do: "-"

  # --- Structured Output Helpers ---

  # Inject structured output settings into model_settings
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

    # Inject synthetic tool(s) into existing tools list
    case tool_settings do
      # Plural: multiple synthetic tools ({:one_of, schemas})
      %{__structured_output_tools__: tools_list} when is_list(tools_list) ->
        existing_tools = merged[:tools] || []

        formatted_tools =
          Enum.map(tools_list, fn tool ->
            case provider do
              :anthropic -> convert_synthetic_tool_anthropic(tool)
              _ -> tool
            end
          end)

        merged = Map.put(merged, :tools, existing_tools ++ formatted_tools)

        case tool_settings[:__structured_output_tool_choice__] do
          nil -> merged
          choice -> Map.put(merged, :tool_choice, choice)
        end

      # Singular: single synthetic tool (standard :tool_call mode)
      %{__structured_output_tool__: tool} ->
        existing_tools = merged[:tools] || []

        # Convert synthetic tool to provider format
        formatted_tool =
          case provider do
            :anthropic -> convert_synthetic_tool_anthropic(tool)
            _ -> tool
          end

        merged = Map.put(merged, :tools, existing_tools ++ [formatted_tool])

        case tool_settings[:__structured_output_tool_choice__] do
          nil -> merged
          choice -> Map.put(merged, :tool_choice, choice)
        end

      _ ->
        merged
    end
  end

  # Convert synthetic tool to Anthropic format (atom keys)
  def convert_synthetic_tool_anthropic(tool) do
    func = tool["function"]
    # Use ToolSchema.to_anthropic with a minimal Tool struct
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
