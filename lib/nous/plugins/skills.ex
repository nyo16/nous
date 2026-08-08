defmodule Nous.Plugins.Skills do
  @moduledoc """
  Plugin that integrates the Skills system into the agent lifecycle.

  This plugin bridges `Nous.Skill` definitions into the existing plugin
  pipeline, handling skill discovery, activation, and injection of
  instructions and tools.

  ## Automatic Inclusion

  When `skills: [...]` is provided to `Nous.Agent.new/2`, this plugin is
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

  alias Nous.Message
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
      registry
      |> Registry.active_skills()
      |> Enum.map(&skill_section(&1, agent, ctx))
      |> Enum.reject(&is_nil/1)
      |> join_sections()
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
    user_input = registry && get_latest_user_input(ctx)

    if user_input do
      activate_matches(registry, user_input, agent, ctx, tools)
    else
      {ctx, tools}
    end
  end

  # Private helpers

  defp get_registry(ctx) do
    Map.get(ctx.deps, :skill_registry)
  end

  defp skill_section(skill, agent, ctx) do
    {instructions, _tools} = load_instructions(skill, agent, ctx)

    if instructions && instructions != "" do
      "## Skill: #{skill.name}\n\n#{instructions}"
    end
  end

  defp join_sections([]), do: nil
  defp join_sections(parts), do: Enum.join(parts, "\n\n---\n\n")

  # Activates every skill the turn's input matched, then hands back the tools
  # those skills contribute. Tools come from `matched` rather than from the
  # newly-activated subset so an already-active skill keeps exporting its
  # tools on later turns.
  defp activate_matches(registry, user_input, agent, ctx, tools) do
    matched = Registry.match(registry, user_input)

    registry =
      Enum.reduce(matched, registry, fn skill, reg ->
        activate_if_inactive(reg, skill, agent, ctx)
      end)

    new_tools =
      Enum.flat_map(matched, fn skill ->
        {_instructions, skill_tools} = load_instructions(skill, agent, ctx)
        skill_tools
      end)

    ctx = %{ctx | deps: Map.put(ctx.deps, :skill_registry, registry)}
    {ctx, tools ++ new_tools}
  end

  defp activate_if_inactive(reg, skill, agent, ctx) do
    if Registry.active?(reg, skill.name) do
      reg
    else
      Logger.debug("Auto-activating skill: #{skill.name}")
      {_instructions, _tools, reg} = Registry.activate(reg, skill.name, agent, ctx)
      reg
    end
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
    |> Enum.find_value(&user_text/1)
  end

  # Nous.Message.extract_text/1 is the one definition of how text is pulled out
  # of binary and multimodal content. A private clone here matched
  # `%{type: :text, text: ...}`, but ContentPart carries its text under
  # `:content` — so every list-content user message yielded nil and skill
  # auto-activation was dead for multimodal input.
  #
  # The "" -> nil conversion is load-bearing, not redundant: extract_text/1
  # returns "" for a message with no text content, "" is truthy in Elixir, and
  # Enum.find_value/2 would therefore stop on the first text-free user message
  # and match skills against an empty query.
  defp user_text(%Message{role: :user} = msg) do
    case Message.extract_text(msg) do
      "" -> nil
      text -> text
    end
  end

  defp user_text(_msg), do: nil
end
