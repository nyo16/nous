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
  4. **before_request** — matches user input against skills for dynamic activation,
     then enforces the active skills' `allowed_tools`

  ## Tool restriction (`allowed_tools`)

  A skill with `allowed_tools: [...]` confines the agent to those tool names
  while it is active. Each request, after activation, the plugin derives a
  `Nous.Permissions.Policy` allowlist from the active skills and removes every
  other tool from the request's tool list. Because the runner resolves tool
  calls against that same list, a call to a removed tool is refused as unknown
  and its function never runs; Code Mode's `run_code` is built from the same
  list, so a program cannot reach a removed tool either. The policy is also
  attached to the tool `Nous.RunContext` (it is stored as the request-scoped
  permission policy, which the runner narrows the agent's policy with), so a
  sub-agent spawned while the skill is active inherits the restriction like
  any other permission policy.

  Semantics:

    * `allowed_tools: nil` (the default) does not restrict, and does not widen
      another skill's restriction.
    * Several active skills with `allowed_tools` — the **union** of their
      lists is allowed. Skills are additive capabilities: each was activated
      because the task needs it, so each must keep its own tools. An
      intersection would let two co-active skills with disjoint lists strip
      the agent of every tool.
    * `allowed_tools: []` allows nothing (fail closed), unless another active
      skill allows something.
    * Names are exact (case-insensitive). The allowlist applies to every tool,
      including tools the skill itself provides — list them too.
    * The skill allowlist only narrows: the agent's own `:permissions` policy
      still applies on top, and approval requirements are unchanged.

  The restriction is applied in this plugin's `before_request/3`, so a plugin
  listed *after* `Nous.Plugins.Skills` that adds tools in its own
  `before_request/3` is not covered. The plugin is appended last by default.

  ## `model_override` is not applied

  `Nous.Skill` carries a `model_override` field, but the runner does not
  switch models per skill: a skill file (possibly third-party) choosing the
  provider would decide where the whole conversation is sent. Requests use
  the agent's model (or its `Nous.Router`). A skill that sets the field logs a
  one-time warning.

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

  alias Nous.Permissions
  alias Nous.Permissions.Policy
  alias Nous.Skill
  alias Nous.Skill.Registry

  require Logger

  @model_override_warned_key {__MODULE__, :model_override_warned}

  @impl true
  def init(agent, ctx) do
    if agent.skills == [] do
      ctx
    else
      # Resolve all skill specs into a registry
      registry = Registry.resolve(agent.skills)

      Logger.debug("Skills plugin initialized with #{length(Registry.list(registry))} skill(s)")

      warn_model_override_once(registry)

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
    case get_registry(ctx) do
      nil ->
        {ctx, tools}

      registry ->
        {registry, tools} = activate_matching(registry, agent, ctx, tools)
        policy = allowed_tools_policy(Registry.active_skills(registry))

        deps =
          ctx.deps
          |> Map.put(:skill_registry, registry)
          |> Permissions.put_request_policy(policy)

        {%{ctx | deps: deps}, Permissions.filter_tools(policy, tools)}
    end
  end

  # Private helpers

  defp activate_matching(registry, agent, ctx, tools) do
    # Get latest user message for matching
    case get_latest_user_input(ctx) do
      nil ->
        {registry, tools}

      user_input ->
        matched = Registry.match(registry, user_input)

        registry =
          Enum.reduce(matched, registry, fn skill, reg ->
            if Registry.active?(reg, skill.name) do
              reg
            else
              Logger.debug("Auto-activating skill: #{skill.name}")
              {_instructions, _tools, reg} = Registry.activate(reg, skill.name, agent, ctx)
              reg
            end
          end)

        # Collect tools from newly activated skills
        new_tools =
          Enum.flat_map(matched, fn skill ->
            {_instructions, skill_tools} = load_instructions(skill, agent, ctx)
            skill_tools
          end)

        {registry, tools ++ new_tools}
    end
  end

  # Union of the allowlists of the active skills that declare one; skills with
  # `allowed_tools: nil` neither restrict nor widen. An explicit empty union is
  # "allow nothing": `:strict` with no allowlist is the one shape
  # Nous.Permissions.blocked?/2 reads as deny-all (an empty allowlist on any
  # other mode would read as "no allowlist" and fail open).
  #
  # The non-empty case is approval-neutral on purpose: `:permissive` +
  # `allow_unattended_execute: true` adds no approval requirement on its own,
  # and Policy.strictest/2 lets the agent's mode and execute rule stand.
  defp allowed_tools_policy(active_skills) do
    # Any non-nil allowed_tools restricts. A value that is not a list of names
    # (e.g. `%Skill{allowed_tools: "file_read"}` built in code, which skips the
    # loader's normalisation) contributes no names, so it allows nothing rather
    # than reading as unrestricted.
    case for(
           %Skill{allowed_tools: names} when not is_nil(names) <- active_skills,
           do: restriction_names(names)
         ) do
      [] ->
        nil

      lists ->
        case lists |> List.flatten() |> Enum.uniq() do
          [] ->
            %Policy{mode: :strict}

          names ->
            Permissions.build_policy(
              mode: :permissive,
              allow: names,
              allow_unattended_execute: true
            )
        end
    end
  end

  defp restriction_names(names) when is_list(names), do: Enum.filter(names, &is_binary/1)
  defp restriction_names(_malformed), do: []

  # model_override is parsed but deliberately not applied (see moduledoc).
  # Say so once per VM rather than shipping a silent no-op.
  defp warn_model_override_once(registry) do
    names =
      for {name, %Skill{model_override: override}} <- registry.skills,
          override not in [nil, ""],
          do: name

    if names != [] and not :persistent_term.get(@model_override_warned_key, false) do
      :persistent_term.put(@model_override_warned_key, true)

      Logger.warning(
        "Skill(s) #{Enum.join(Enum.sort(names), ", ")} set model_override, which Nous does " <>
          "not apply: requests use the agent's model (or its router). Remove the field, or " <>
          "configure the model on the agent or via Nous.Router."
      )
    end

    :ok
  end

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
