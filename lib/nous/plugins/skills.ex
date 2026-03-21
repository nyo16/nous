defmodule Nous.Plugins.Skills do
  @moduledoc """
  Plugin that integrates the Skills system into the agent lifecycle.

  This plugin bridges `Nous.Skill` definitions into the existing plugin
  pipeline, handling skill discovery, activation, and injection of
  instructions and tools.

  ## Automatic Inclusion

  When `skills: [...]` is provided to `Agent.new/2`, this plugin is
  automatically added to the plugins list.

  ## Lifecycle

  1. **init** — resolves skill specs, builds registry, auto-activates `:auto` skills
  2. **system_prompt** — injects instructions from all active skills
  3. **tools** — provides tools from all active skills
  4. **before_request** — matches user input against skills for dynamic activation

  ## Example

      agent = Agent.new("openai:gpt-4",
        skills: [
          MyApp.Skills.CodeReview,
          "priv/skills/",
          {:group, :testing}
        ]
      )
  """

  @behaviour Nous.Plugin

  alias Nous.Skill.Registry

  require Logger

  @impl true
  def init(agent, ctx) do
    if agent.skills == [] do
      ctx
    else
      # Resolve all skill specs into a registry
      registry = Registry.resolve(agent.skills)

      Logger.debug("Skills plugin initialized with #{length(Registry.list(registry))} skill(s)")

      # Auto-activate skills with activation: :auto
      registry =
        registry.skills
        |> Map.values()
        |> Enum.filter(&(&1.activation == :auto))
        |> Enum.reduce(registry, fn skill, reg ->
          {_instructions, _tools, reg} = Registry.activate(reg, skill.name, agent, ctx)
          reg
        end)

      %{ctx | deps: Map.put(ctx.deps, :skill_registry, registry)}
    end
  end

  @impl true
  def system_prompt(agent, ctx) do
    registry = get_registry(ctx)

    if registry do
      active = Registry.active_skills(registry)

      if Enum.empty?(active) do
        nil
      else
        active
        |> Enum.map(fn skill ->
          {instructions, _tools} = load_instructions(skill, agent, ctx)

          if instructions && instructions != "" do
            "## Skill: #{skill.name}\n\n#{instructions}"
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          parts -> Enum.join(parts, "\n\n---\n\n")
        end
      end
    end
  end

  @impl true
  def tools(agent, ctx) do
    registry = get_registry(ctx)

    if registry do
      Registry.active_skills(registry)
      |> Enum.flat_map(fn skill ->
        {_instructions, tools} = load_instructions(skill, agent, ctx)
        tools
      end)
    else
      []
    end
  end

  @impl true
  def before_request(agent, ctx, tools) do
    registry = get_registry(ctx)

    if registry do
      # Get latest user message for matching
      user_input = get_latest_user_input(ctx)

      if user_input do
        # Find matching skills that aren't already active
        matched = Registry.match(registry, user_input)

        registry =
          Enum.reduce(matched, registry, fn skill, reg ->
            if not Registry.active?(reg, skill.name) do
              Logger.debug("Auto-activating skill: #{skill.name}")
              {_instructions, _tools, reg} = Registry.activate(reg, skill.name, agent, ctx)
              reg
            else
              reg
            end
          end)

        # Collect tools from newly activated skills
        new_tools =
          matched
          |> Enum.flat_map(fn skill ->
            {_instructions, skill_tools} = load_instructions(skill, agent, ctx)
            skill_tools
          end)

        ctx = %{ctx | deps: Map.put(ctx.deps, :skill_registry, registry)}
        {ctx, tools ++ new_tools}
      else
        {ctx, tools}
      end
    else
      {ctx, tools}
    end
  end

  # Private helpers

  defp get_registry(ctx) do
    Map.get(ctx.deps, :skill_registry)
  end

  defp load_instructions(%Nous.Skill{source: :module, source_ref: module}, agent, ctx) do
    instructions = module.instructions(agent, ctx)

    tools =
      if function_exported?(module, :tools, 2) do
        module.tools(agent, ctx)
      else
        []
      end

    {instructions, tools}
  end

  defp load_instructions(%Nous.Skill{instructions: instructions}, _agent, _ctx) do
    {instructions, []}
  end

  defp get_latest_user_input(ctx) do
    ctx.messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if msg.role == :user do
        case msg.content do
          text when is_binary(text) ->
            text

          parts when is_list(parts) ->
            Enum.find_value(parts, fn
              %{type: :text, text: text} -> text
              _ -> nil
            end)

          _ ->
            nil
        end
      end
    end)
  end
end
