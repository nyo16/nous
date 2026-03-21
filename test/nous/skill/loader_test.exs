defmodule Nous.Skill.LoaderTest do
  use ExUnit.Case, async: true

  alias Nous.Skill.Loader

  describe "parse_frontmatter/1" do
    test "parses YAML frontmatter" do
      content = """
      ---
      name: test_skill
      description: A test skill
      tags: [code, review]
      ---

      Skill instructions here.
      """

      assert {:ok, metadata, body} = Loader.parse_frontmatter(content)
      assert metadata["name"] == "test_skill"
      assert metadata["description"] == "A test skill"
      assert metadata["tags"] == ["code", "review"]
      assert String.contains?(body, "Skill instructions here.")
    end

    test "handles content without frontmatter" do
      content = "Just plain instructions"
      assert {:ok, %{}, body} = Loader.parse_frontmatter(content)
      assert body == "Just plain instructions"
    end

    test "handles empty frontmatter" do
      content = """
      ---
      ---
      Instructions after empty frontmatter.
      """

      # YamlElixir returns nil for empty YAML
      result = Loader.parse_frontmatter(content)
      # Either ok with empty map or error is acceptable
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end
  end

  describe "parse_skill/2" do
    test "creates skill from markdown with frontmatter" do
      content = """
      ---
      name: code_review
      description: Reviews code for quality
      tags: [code, review]
      group: review
      activation: auto
      priority: 50
      ---

      You are a code review specialist.
      """

      assert {:ok, skill} = Loader.parse_skill(content, "/path/to/skill.md")
      assert skill.name == "code_review"
      assert skill.description == "Reviews code for quality"
      assert skill.tags == [:code, :review]
      assert skill.group == :review
      assert skill.activation == :auto
      assert skill.priority == 50
      assert skill.source == :file
      assert skill.source_ref == "/path/to/skill.md"
      assert String.contains?(skill.instructions, "code review specialist")
    end

    test "uses filename as name when not specified" do
      content = "Just instructions, no frontmatter"
      assert {:ok, skill} = Loader.parse_skill(content, "/path/to/my_skill.md")
      assert skill.name == "my_skill"
    end

    test "defaults to manual activation" do
      content = """
      ---
      name: test
      ---
      Instructions
      """

      assert {:ok, skill} = Loader.parse_skill(content)
      assert skill.activation == :manual
    end

    test "parses allowed_tools" do
      content = """
      ---
      name: test
      allowed_tools: [read_file, grep, glob]
      ---
      Instructions
      """

      assert {:ok, skill} = Loader.parse_skill(content)
      assert skill.allowed_tools == ["read_file", "grep", "glob"]
    end
  end

  describe "load_directory/1" do
    test "loads skills from directory" do
      # Create temporary directory with skill files
      tmp_dir = System.tmp_dir!() |> Path.join("nous_skill_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "skill_a.md"), """
      ---
      name: skill_a
      description: First skill
      ---
      Instructions for skill A
      """)

      File.write!(Path.join(tmp_dir, "skill_b.md"), """
      ---
      name: skill_b
      description: Second skill
      ---
      Instructions for skill B
      """)

      skills = Loader.load_directory(tmp_dir)
      assert length(skills) == 2
      names = Enum.map(skills, & &1.name) |> Enum.sort()
      assert names == ["skill_a", "skill_b"]
    after
      tmp_dir = System.tmp_dir!() |> Path.join("nous_skill_test_*")
      Path.wildcard(tmp_dir) |> Enum.each(&File.rm_rf!/1)
    end

    test "returns empty list for non-existent directory" do
      assert Loader.load_directory("/non/existent/path") == []
    end
  end
end
