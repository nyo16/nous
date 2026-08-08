defmodule Nous.Skill.Registry do
  @moduledoc """
  Discovery, management, and activation of skills.

  The registry maintains skills indexed by name, group, tags, and scope.
  It supports loading/unloading, activation/deactivation, group operations,
  and input matching for auto-activation.

  ## Example

      registry = Nous.Skill.Registry.new()
      |> Nous.Skill.Registry.register(skill)
      |> Nous.Skill.Registry.activate("code_review", agent, ctx)

      active = Nous.Skill.Registry.active_skills(registry)
  """

  alias __MODULE__
  alias Nous.Skill
  alias Nous.Skill.Loader

  require Logger

  @type t :: %Registry{
          skills: %{optional(String.t()) => Skill.t()},
          groups: %{optional(atom()) => [String.t()]},
          tags: %{optional(atom()) => [String.t()]},
          scopes: %{optional(Skill.scope()) => [String.t()]},
          match_terms: %{optional(String.t()) => [String.t()]},
          active: term()
        }

  defstruct skills: %{},
            groups: %{},
            tags: %{},
            scopes: %{},
            match_terms: %{},
            active: MapSet.new()

  @doc """
  Create an empty registry.
  """
  @spec new() :: t()
  def new, do: %Registry{}

  @doc """
  Register a skill in the registry, indexing by name, group, tags, and scope.
  """
  @spec register(t(), Skill.t()) :: t()
  def register(%Registry{} = registry, %Skill{} = skill) do
    %{
      registry
      | skills: Map.put(registry.skills, skill.name, skill),
        groups: add_to_index(registry.groups, skill.group, skill.name),
        tags: Enum.reduce(skill.tags, registry.tags, &add_to_index(&2, &1, skill.name)),
        scopes: add_to_index(registry.scopes, skill.scope, skill.name),
        match_terms: Map.put(registry.match_terms, skill.name, match_terms(skill))
    }
  end

  @doc """
  Register multiple skills at once.
  """
  @spec register_all(t(), [Skill.t()]) :: t()
  def register_all(%Registry{} = registry, skills) do
    Enum.reduce(skills, registry, &register(&2, &1))
  end

  @doc """
  Register all skills found in a directory (recursively scans for `.md` files).

  This is the primary API for loading file-based skills from a folder.

  ## Example

      registry = Registry.new()
      |> Registry.register_directory("priv/skills/")
      |> Registry.register_directory("~/.nous/skills/")

  """
  @spec register_directory(t(), String.t()) :: t()
  def register_directory(%Registry{} = registry, path) when is_binary(path) do
    skills = Loader.load_directory(path)

    Logger.debug("Loaded #{length(skills)} skill(s) from directory: #{path}")

    register_all(registry, skills)
  end

  @doc """
  Register all skills from multiple directories.

  ## Example

      registry = Registry.new()
      |> Registry.register_directories(["priv/skills/", "~/.nous/skills/", ".nous/skills/"])

  """
  @spec register_directories(t(), [String.t()]) :: t()
  def register_directories(%Registry{} = registry, paths) when is_list(paths) do
    Enum.reduce(paths, registry, &register_directory(&2, &1))
  end

  @doc """
  Resolve a mixed list of skill specs into a populated registry.

  Accepts:
  - Modules implementing `Nous.Skill` behaviour
  - Directory paths (strings ending with `/` or existing dirs)
  - File paths (strings ending with `.md`)
  - `Skill.t()` structs
  - `{:group, atom()}` tuples (registers all built-in skills for that group)

  ## Example

      registry = Registry.resolve([
        MyApp.Skills.CodeReview,         # module
        "priv/skills/",                  # directory
        "priv/skills/custom.md",         # single file
        {:group, :testing},              # built-in group
        %Skill{name: "inline", ...}      # inline struct
      ])

  """
  @spec resolve([module() | String.t() | Skill.t() | {:group, atom()}]) :: t()
  def resolve(specs) when is_list(specs) do
    Enum.reduce(specs, new(), fn spec, registry ->
      resolve_spec(registry, spec)
    end)
  end

  @doc """
  Activate a skill by name.

  Loads the skill if not already loaded, marks it as active.
  Returns `{instructions, tools, updated_registry}`.
  """
  @spec activate(t(), String.t(), Nous.Agent.t(), Nous.Agent.Context.t()) ::
          {String.t() | nil, [Nous.Tool.t()], t()}
  def activate(%Registry{} = registry, name, agent, ctx) do
    case Map.get(registry.skills, name) do
      nil ->
        Logger.warning("Skill not found: #{name}")
        {nil, [], registry}

      skill ->
        {instructions, tools} = load_skill_content(skill, agent, ctx)

        updated_skill = %{skill | status: :active}

        updated_registry = %{
          registry
          | skills: Map.put(registry.skills, name, updated_skill),
            active: MapSet.put(registry.active, name)
        }

        :telemetry.execute(
          [:nous, :skill, :activate],
          %{},
          %{skill_name: name, group: skill.group, activation_type: skill.activation}
        )

        {instructions, tools, updated_registry}
    end
  end

  @doc """
  Deactivate a skill by name.
  """
  @spec deactivate(t(), String.t()) :: t()
  def deactivate(%Registry{} = registry, name) do
    case Map.get(registry.skills, name) do
      nil ->
        registry

      skill ->
        updated_skill = %{skill | status: :inactive}

        :telemetry.execute(
          [:nous, :skill, :deactivate],
          %{},
          %{skill_name: name, group: skill.group}
        )

        %{
          registry
          | skills: Map.put(registry.skills, name, updated_skill),
            active: MapSet.delete(registry.active, name)
        }
    end
  end

  @doc """
  Activate all skills in a group.
  """
  @spec activate_group(t(), atom(), Nous.Agent.t(), Nous.Agent.Context.t()) ::
          {[{String.t(), [Nous.Tool.t()]}], t()}
  def activate_group(%Registry{} = registry, group, agent, ctx) do
    names = Map.get(registry.groups, group, [])

    {results, updated_registry} =
      Enum.reduce(names, {[], registry}, fn name, {acc, reg} ->
        {instructions, tools, reg} = activate(reg, name, agent, ctx)
        {[{instructions, tools} | acc], reg}
      end)

    {Enum.reverse(results), updated_registry}
  end

  @doc """
  Deactivate all skills in a group.
  """
  @spec deactivate_group(t(), atom()) :: t()
  def deactivate_group(%Registry{} = registry, group) do
    names = Map.get(registry.groups, group, [])
    Enum.reduce(names, registry, &deactivate(&2, &1))
  end

  @doc """
  Get all skills in a group.
  """
  @spec by_group(t(), atom()) :: [Skill.t()]
  def by_group(%Registry{} = registry, group) do
    resolve_names(registry, Map.get(registry.groups, group, []))
  end

  @doc """
  Get all skills with a tag.
  """
  @spec by_tag(t(), atom()) :: [Skill.t()]
  def by_tag(%Registry{} = registry, tag) do
    resolve_names(registry, Map.get(registry.tags, tag, []))
  end

  @doc """
  Get all currently active skills.
  """
  @spec active_skills(t()) :: [Skill.t()]
  def active_skills(%Registry{} = registry) do
    registry
    |> resolve_names(registry.active)
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  Find skills matching user input.

  Checks skills with `{:on_match, fn}` activation or falls back to
  description keyword matching.
  """
  @spec match(t(), String.t()) :: [Skill.t()]
  def match(%Registry{} = registry, input) do
    input_lower = String.downcase(input)

    registry.skills
    |> Map.values()
    |> Enum.filter(fn skill ->
      case skill.activation do
        {:on_match, fun} when is_function(fun, 1) ->
          fun.(input)

        _ ->
          # Fallback: do any description keywords appear in the input?
          registry.match_terms
          |> Map.get(skill.name, [])
          |> Enum.any?(&String.contains?(input_lower, &1))
      end
    end)
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  List all registered skill names.
  """
  @spec list(t()) :: [String.t()]
  def list(%Registry{} = registry) do
    Map.keys(registry.skills)
  end

  @doc """
  Get a skill by name.
  """
  @spec get(t(), String.t()) :: Skill.t() | nil
  def get(%Registry{} = registry, name) do
    Map.get(registry.skills, name)
  end

  @doc """
  Check if a skill is currently active.
  """
  @spec active?(t(), String.t()) :: boolean()
  def active?(%Registry{} = registry, name) do
    MapSet.member?(registry.active, name)
  end

  @doc """
  List every built-in skill shipped with Nous, sorted by name.

  The set is derived from `:nous`'s own module list — every module under
  `Nous.Skills.` implementing the `Nous.Skill` behaviour — so adding a built-in
  skill module is enough to ship it and no entry can be lost to a typo.

  Ordering is load-bearing: `{:group, atom()}` specs register in this order, and
  `by_group/2` and `activate_group/4` iterate it.

  ## Example

      Registry.builtin_skills() |> Enum.map(& &1.name)
      #=> ["architect", "code_review", ...]

  """
  @spec builtin_skills() :: [Skill.t()]
  def builtin_skills do
    builtin_modules()
    |> Enum.map(&builtin_skill/1)
    |> Enum.sort_by(& &1.name)
  end

  # Private helpers

  defp resolve_spec(registry, module) when is_atom(module) do
    skill = Skill.from_module(module)
    register(registry, skill)
  end

  defp resolve_spec(registry, %Skill{} = skill) do
    register(registry, skill)
  end

  defp resolve_spec(registry, {:group, group}) when is_atom(group) do
    # Built-in skills for the group will be registered by the Skills plugin
    # when it discovers built-in skill modules tagged with this group
    builtin_skills = discover_builtin_skills_for_group(group)
    register_all(registry, builtin_skills)
  end

  defp resolve_spec(registry, path) when is_binary(path) do
    cond do
      String.ends_with?(path, "/") or File.dir?(path) ->
        skills = Loader.load_directory(path)
        register_all(registry, skills)

      String.ends_with?(path, ".md") ->
        case Loader.load_file(path) do
          {:ok, skill} -> register(registry, skill)
          {:error, _} -> registry
        end

      true ->
        Logger.warning("Unknown skill spec: #{inspect(path)}")
        registry
    end
  end

  defp resolve_spec(registry, other) do
    Logger.warning("Unknown skill spec: #{inspect(other)}")
    registry
  end

  defp add_to_index(index, nil, _name), do: index

  defp add_to_index(index, key, name) do
    Map.update(index, key, [name], fn names ->
      if name in names, do: names, else: names ++ [name]
    end)
  end

  # A skill's description keywords are constant, so they are downcased and split
  # once here rather than on every user turn (`match/2` runs per turn from the
  # skills plugin). Empty or missing descriptions yield no terms: splitting ""
  # produces [""], and String.contains?/2 matches "" against anything.
  defp match_terms(%Skill{description: description})
       when is_binary(description) and description != "" do
    description |> String.downcase() |> String.split(~r/\s+/)
  end

  defp match_terms(%Skill{}), do: []

  # Resolve skill names from an index to their structs, dropping stale names.
  defp resolve_names(registry, names) do
    names
    |> Enum.map(&Map.get(registry.skills, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp load_skill_content(%Skill{source: :module, source_ref: module}, agent, ctx) do
    instructions = module.instructions(agent, ctx)

    tools =
      if function_exported?(module, :tools, 2) do
        module.tools(agent, ctx)
      else
        []
      end

    {instructions, tools}
  end

  defp load_skill_content(%Skill{source: :file, instructions: instructions}, _agent, _ctx) do
    {instructions, []}
  end

  defp load_skill_content(%Skill{source: :inline, instructions: instructions}, _agent, _ctx) do
    {instructions, []}
  end

  # Discover built-in skill modules for a group
  defp discover_builtin_skills_for_group(group) do
    builtin_modules()
    |> Enum.filter(&(builtin_group(&1) == group))
    |> Enum.map(&builtin_skill/1)
    |> Enum.sort_by(& &1.name)
  end

  defp builtin_skill(module) do
    %{Skill.from_module(module) | scope: :builtin}
  end

  defp builtin_group(module) do
    if function_exported?(module, :group, 0), do: module.group(), else: nil
  end

  @builtin_prefix "Elixir.Nous.Skills."

  # Derived from `:nous`'s own module list, never enumerated by hand: a written
  # list drops a misspelled entry silently, and every name in it is a
  # compile-time dependency of this module.
  #
  # Deliberately not memoized. The scan is one ETS read plus a prefix filter,
  # run once per `{:group, _}` spec at agent init, while caching it would
  # reintroduce exactly the failure being removed here — a built-in added in a
  # running dev VM staying silently absent until restart.
  defp builtin_modules do
    case :application.get_key(:nous, :modules) do
      {:ok, modules} ->
        modules
        |> Enum.filter(&builtin_skill_module?/1)
        |> Enum.sort()

      :undefined ->
        raise "the :nous application is not loaded; built-in skills cannot be discovered"
    end
  end

  defp builtin_skill_module?(module) do
    String.starts_with?(Atom.to_string(module), @builtin_prefix) and
      Code.ensure_loaded?(module) and implements_skill?(module)
  end

  defp implements_skill?(module) do
    attributes = module.module_info(:attributes)
    Skill in List.flatten(Keyword.get_values(attributes, :behaviour))
  end
end
