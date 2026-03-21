defmodule Nous.SkillTest do
  use ExUnit.Case, async: true

  alias Nous.Skill

  describe "struct defaults" do
    test "has sensible defaults" do
      skill = %Skill{}
      assert skill.name == ""
      assert skill.activation == :manual
      assert skill.scope == :project
      assert skill.source == :inline
      assert skill.status == :discovered
      assert skill.priority == 100
      assert skill.tags == []
      assert skill.tools == []
    end
  end

  describe "from_module/1" do
    defmodule TestSkill do
      use Nous.Skill, tags: [:test, :example], group: :testing

      @impl true
      def name, do: "test_skill"

      @impl true
      def description, do: "A test skill"

      @impl true
      def instructions(_agent, _ctx), do: "Test instructions"

      @impl true
      def match?(input), do: String.contains?(input, "test")
    end

    test "builds skill struct from module" do
      skill = Skill.from_module(TestSkill)
      assert skill.name == "test_skill"
      assert skill.description == "A test skill"
      assert skill.tags == [:test, :example]
      assert skill.group == :testing
      assert skill.source == :module
      assert skill.source_ref == TestSkill
      assert skill.status == :loaded
      assert match?({:on_match, _}, skill.activation)
    end

    defmodule MinimalSkill do
      @behaviour Nous.Skill

      @impl true
      def name, do: "minimal"

      @impl true
      def description, do: "Minimal skill"

      @impl true
      def instructions(_agent, _ctx), do: "Minimal instructions"
    end

    test "builds skill from module without optional callbacks" do
      skill = Skill.from_module(MinimalSkill)
      assert skill.name == "minimal"
      assert skill.tags == []
      assert skill.group == nil
      assert skill.activation == :manual
    end
  end

  describe "use macro" do
    defmodule MacroSkill do
      use Nous.Skill, tags: [:macro], group: :coding

      @impl true
      def name, do: "macro_test"
      @impl true
      def description, do: "Macro test"
      @impl true
      def instructions(_, _), do: "test"
    end

    test "sets default tags from use opts" do
      assert MacroSkill.tags() == [:macro]
    end

    test "sets default group from use opts" do
      assert MacroSkill.group() == :coding
    end
  end
end
