defmodule Nous.Skill.RegistryTest do
  use ExUnit.Case, async: true

  alias Nous.Skill
  alias Nous.Skill.Registry

  defp make_skill(name, opts \\ []) do
    %Skill{
      name: name,
      description: Keyword.get(opts, :description, "A skill named #{name}"),
      tags: Keyword.get(opts, :tags, []),
      group: Keyword.get(opts, :group),
      activation: Keyword.get(opts, :activation, :manual),
      scope: Keyword.get(opts, :scope, :project),
      source: :inline,
      instructions: Keyword.get(opts, :instructions, "Instructions for #{name}"),
      priority: Keyword.get(opts, :priority, 100),
      status: :loaded
    }
  end

  describe "new/0" do
    test "creates empty registry" do
      registry = Registry.new()
      assert registry.skills == %{}
      assert registry.active == MapSet.new()
    end
  end

  describe "register/2" do
    test "adds skill to registry" do
      registry = Registry.new() |> Registry.register(make_skill("test"))
      assert Registry.get(registry, "test") != nil
    end

    test "indexes by group" do
      skill = make_skill("review_tool", group: :review)
      registry = Registry.new() |> Registry.register(skill)
      assert length(Registry.by_group(registry, :review)) == 1
    end

    test "indexes by tags" do
      skill = make_skill("tagged", tags: [:code, :quality])
      registry = Registry.new() |> Registry.register(skill)
      assert length(Registry.by_tag(registry, :code)) == 1
      assert length(Registry.by_tag(registry, :quality)) == 1
    end
  end

  describe "activate/4 and deactivate/2" do
    test "activates a skill" do
      skill = make_skill("test_skill")
      registry = Registry.new() |> Registry.register(skill)

      {instructions, _tools, registry} =
        Registry.activate(registry, "test_skill", nil, nil)

      assert instructions == "Instructions for test_skill"
      assert Registry.active?(registry, "test_skill")
    end

    test "deactivates a skill" do
      skill = make_skill("test_skill")
      registry = Registry.new() |> Registry.register(skill)

      {_, _, registry} = Registry.activate(registry, "test_skill", nil, nil)
      assert Registry.active?(registry, "test_skill")

      registry = Registry.deactivate(registry, "test_skill")
      refute Registry.active?(registry, "test_skill")
    end

    test "returns nil for non-existent skill" do
      registry = Registry.new()
      {instructions, tools, _registry} = Registry.activate(registry, "nonexistent", nil, nil)
      assert instructions == nil
      assert tools == []
    end
  end

  describe "activate_group/4 and deactivate_group/2" do
    test "activates all skills in a group" do
      skills = [
        make_skill("s1", group: :review),
        make_skill("s2", group: :review),
        make_skill("s3", group: :testing)
      ]

      registry = Registry.register_all(Registry.new(), skills)
      {_results, registry} = Registry.activate_group(registry, :review, nil, nil)

      assert Registry.active?(registry, "s1")
      assert Registry.active?(registry, "s2")
      refute Registry.active?(registry, "s3")
    end

    test "deactivates all skills in a group" do
      skills = [
        make_skill("s1", group: :review),
        make_skill("s2", group: :review)
      ]

      registry = Registry.register_all(Registry.new(), skills)
      {_, registry} = Registry.activate_group(registry, :review, nil, nil)
      registry = Registry.deactivate_group(registry, :review)

      refute Registry.active?(registry, "s1")
      refute Registry.active?(registry, "s2")
    end
  end

  describe "active_skills/1" do
    test "returns only active skills sorted by priority" do
      skills = [
        make_skill("s1", priority: 200),
        make_skill("s2", priority: 50),
        make_skill("s3", priority: 100)
      ]

      registry = Registry.register_all(Registry.new(), skills)
      {_, _, registry} = Registry.activate(registry, "s1", nil, nil)
      {_, _, registry} = Registry.activate(registry, "s2", nil, nil)

      active = Registry.active_skills(registry)
      assert length(active) == 2
      assert hd(active).name == "s2"
    end
  end

  describe "match/2" do
    test "matches skills with on_match activation" do
      skill =
        make_skill("review",
          activation: {:on_match, &String.contains?(&1, "review")}
        )

      registry = Registry.new() |> Registry.register(skill)

      assert length(Registry.match(registry, "please review this code")) == 1
      assert length(Registry.match(registry, "write a function")) == 0
    end

    test "falls back to description keyword matching" do
      skill = make_skill("debugger", description: "debugging tool for errors")
      registry = Registry.new() |> Registry.register(skill)

      matched = Registry.match(registry, "I have a debugging issue")
      assert length(matched) >= 1
    end

    test "description keywords are downcased and split at registration" do
      skill = make_skill("debugger", description: "Debugging Tool for Errors")
      registry = Registry.new() |> Registry.register(skill)

      assert registry.match_terms["debugger"] == ["debugging", "tool", "for", "errors"]

      # The precomputed terms are what match/2 uses, so casing still folds.
      assert [%Skill{name: "debugger"}] = Registry.match(registry, "a DEBUGGING issue")
    end

    test "an empty description yields no terms and never matches" do
      registry = Registry.new() |> Registry.register(make_skill("blank", description: ""))

      assert registry.match_terms["blank"] == []
      assert Registry.match(registry, "literally anything") == []
    end
  end

  describe "list/1" do
    test "returns all skill names" do
      registry =
        Registry.new()
        |> Registry.register(make_skill("a"))
        |> Registry.register(make_skill("b"))

      names = Registry.list(registry) |> Enum.sort()
      assert names == ["a", "b"]
    end
  end

  describe "resolve/1" do
    test "resolves module specs" do
      defmodule ResolveTestSkill do
        use Nous.Skill, tags: [:test], group: :testing
        @impl true
        def name, do: "resolve_test"
        @impl true
        def description, do: "Test skill for resolution"
        @impl true
        def instructions(_, _), do: "Test"
      end

      registry = Registry.resolve([ResolveTestSkill])
      assert Registry.get(registry, "resolve_test") != nil
    end

    test "resolves inline skill structs" do
      skill = make_skill("inline_test")
      registry = Registry.resolve([skill])
      assert Registry.get(registry, "inline_test") != nil
    end

    test "resolves mixed specs" do
      skill = make_skill("inline")
      registry = Registry.resolve([skill])
      assert length(Registry.list(registry)) >= 1
    end
  end

  # Pinned at the switch from a hard-coded builtin list to derivation from the
  # `:nous` module list. Losing an entry is a silent capability regression, so
  # the whole set is enumerated rather than counted.
  @builtin_names ~w(
    architect
    code_review
    commit_message
    debug
    doc_gen
    ecto_patterns
    elixir_idioms
    elixir_testing
    explain_code
    otp_patterns
    phoenix_liveview
    python_data_science
    python_fastapi
    python_security
    python_testing
    python_typing
    python_uv
    refactor
    security_scan
    task_breakdown
    test_gen
  )

  describe "builtin_skills/0" do
    test "derives exactly the shipped built-in set, sorted by name" do
      assert Enum.map(Registry.builtin_skills(), & &1.name) == @builtin_names
    end

    test "covers every skill module file on disk" do
      # The derivation's whole point: a file under lib/nous/skills/ ships as a
      # built-in with no list to edit, so a count mismatch means one is unreachable.
      files = Path.wildcard("lib/nous/skills/*.ex")

      assert files != [], "expected mix test to run from the project root"
      assert length(Registry.builtin_skills()) == length(files)
    end

    test "every derived built-in loads and implements the behaviour" do
      for skill <- Registry.builtin_skills() do
        assert skill.source == :module
        assert skill.scope == :builtin

        module = skill.source_ref
        assert Code.ensure_loaded?(module)

        behaviours =
          module.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert Skill in behaviours, "#{inspect(module)} does not implement Nous.Skill"
      end
    end

    test "every derived built-in activates and yields instructions" do
      registry = Registry.register_all(Registry.new(), Registry.builtin_skills())

      for name <- @builtin_names do
        {instructions, tools, _registry} = Registry.activate(registry, name, nil, nil)

        assert is_binary(instructions) and instructions != "", "#{name} yielded no instructions"
        assert is_list(tools)
      end
    end
  end

  describe "resolve/1 with {:group, _}" do
    test "registers every built-in in the group with :builtin scope" do
      registry = Registry.resolve([{:group, :review}])

      assert Enum.sort(Registry.list(registry)) ==
               ["code_review", "python_security", "security_scan"]

      assert Enum.all?(Registry.by_group(registry, :review), &(&1.scope == :builtin))
    end

    test "registers group members in deterministic name order" do
      registry = Registry.resolve([{:group, :coding}])

      assert Enum.map(Registry.by_group(registry, :coding), & &1.name) ==
               ~w(ecto_patterns elixir_idioms explain_code otp_patterns phoenix_liveview
                  python_data_science python_fastapi python_typing python_uv refactor)
    end

    test "an unknown group registers nothing" do
      assert Registry.list(Registry.resolve([{:group, :no_such_group}])) == []
    end
  end
end
