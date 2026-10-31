defmodule Nous.Teams.RoleTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.Role
  alias Nous.Tool

  doctest Nous.Teams.Role

  describe "new/1" do
    test "creates role with required attributes" do
      role = Role.new(name: :researcher, system_prompt: "Research well")
      assert role.name == :researcher
      assert role.system_prompt == "Research well"
    end

    test "uses defaults for optional attributes" do
      role = Role.new(name: :basic)
      assert role.allowed_tools == nil
      assert role.denied_tools == nil
      assert role.max_iterations == 15
    end

    test "sets allowed_tools" do
      role = Role.new(name: :restricted, allowed_tools: ["search", "read"])
      assert role.allowed_tools == ["search", "read"]
    end

    test "sets denied_tools" do
      role = Role.new(name: :limited, denied_tools: ["delete", "drop"])
      assert role.denied_tools == ["delete", "drop"]
    end
  end

  describe "apply_tool_filter/2" do
    setup do
      tools = [
        %Tool{name: "search", function: &Function.identity/1, description: "Search"},
        %Tool{name: "read_file", function: &Function.identity/1, description: "Read"},
        %Tool{name: "execute", function: &Function.identity/1, description: "Execute"},
        %Tool{name: "delete", function: &Function.identity/1, description: "Delete"}
      ]

      %{tools: tools}
    end

    test "allowed_tools filters to only allowed tools", %{tools: tools} do
      role = Role.new(name: :restricted, allowed_tools: ["search", "read_file"])
      filtered = Role.apply_tool_filter(role, tools)

      assert length(filtered) == 2
      names = Enum.map(filtered, & &1.name)
      assert "search" in names
      assert "read_file" in names
    end

    test "denied_tools removes denied tools", %{tools: tools} do
      role = Role.new(name: :limited, denied_tools: ["delete", "execute"])
      filtered = Role.apply_tool_filter(role, tools)

      assert length(filtered) == 2
      names = Enum.map(filtered, & &1.name)
      assert "search" in names
      assert "read_file" in names
    end

    test "returns all tools when no filters set", %{tools: tools} do
      role = Role.new(name: :unrestricted)
      filtered = Role.apply_tool_filter(role, tools)

      assert length(filtered) == 4
    end

    test "denied_tools applies on top of allowed_tools", %{tools: tools} do
      role =
        Role.new(name: :mixed, allowed_tools: ["search", "read_file"], denied_tools: ["search"])

      filtered = Role.apply_tool_filter(role, tools)

      assert Enum.map(filtered, & &1.name) == ["read_file"]
    end

    test "an empty allowed_tools list allows nothing", %{tools: tools} do
      assert Role.apply_tool_filter(Role.new(name: :none, allowed_tools: []), tools) == []
    end
  end

  describe "to_policy/1" do
    test "is nil for an unrestricted role" do
      assert Role.to_policy(Role.lead()) == nil
      assert Role.to_policy(Role.new(name: :x, denied_tools: [])) == nil
    end

    test "an empty allowlist denies every tool (fails closed)" do
      policy = Role.to_policy(Role.new(name: :none, allowed_tools: []))

      assert Nous.Permissions.blocked?(policy, "search")
      assert Nous.Permissions.blocked?(policy, "anything")
    end

    test "Role.researcher/0 allows the real read-only tools by their actual names" do
      policy = Role.to_policy(Role.researcher())

      names =
        Enum.map([Nous.Tools.FileRead, Nous.Tools.FileGlob, Nous.Tools.FileGrep], fn mod ->
          Tool.from_module(mod).name
        end) ++
          [
            Tool.from_function(&Nous.Tools.TavilySearch.search/2).name,
            Tool.from_function(&Nous.Tools.BraveSearch.web_search/2).name
          ]

      for name <- names, do: refute(Nous.Permissions.blocked?(policy, name), name)

      for name <- ["bash", "file_write", "file_edit"],
          do: assert(Nous.Permissions.blocked?(policy, name), name)
    end
  end

  describe "apply_to_config/2" do
    test "combines with an existing policy, strictest wins" do
      existing = Nous.Permissions.build_policy(deny: ["fetch_page"])
      config = Role.apply_to_config(Role.researcher(), %{permissions: existing})

      # fetch_page is on the researcher allowlist; the existing deny still wins.
      assert Nous.Permissions.blocked?(config.permissions, "fetch_page")
      assert Nous.Permissions.blocked?(config.permissions, "delete_file")
      refute Nous.Permissions.blocked?(config.permissions, "search")
    end

    test "prepends the system prompt and keeps the lower iteration cap" do
      role = Role.new(name: :r, system_prompt: "ROLE PROMPT", max_iterations: 5)

      assert %{instructions: "ROLE PROMPT\n\nmine", max_iterations: 3} =
               Role.apply_to_config(role, %{instructions: "mine", max_iterations: 3})

      assert %{instructions: "ROLE PROMPT", max_iterations: 5} =
               Role.apply_to_config(role, %{})
    end

    test "leaves the config untouched apart from max_iterations for an unrestricted role" do
      role = Role.new(name: :plain)

      assert Role.apply_to_config(role, %{instructions: "mine"}) ==
               %{instructions: "mine", max_iterations: 15}
    end
  end

  describe "default roles" do
    test "researcher has correct settings" do
      role = Role.researcher()
      assert role.name == :researcher
      assert is_binary(role.system_prompt)
      assert is_list(role.allowed_tools)
      assert "search" in role.allowed_tools
      assert "share_discovery" in role.allowed_tools
    end

    test "coder has correct settings" do
      role = Role.coder()
      assert role.name == :coder
      assert is_binary(role.system_prompt)
      assert is_list(role.denied_tools)
      assert "delete_file" in role.denied_tools
    end

    test "lead has no tool restrictions" do
      role = Role.lead()
      assert role.name == :lead
      assert is_binary(role.system_prompt)
      assert role.allowed_tools == nil
      assert role.denied_tools == nil
      assert role.max_iterations == 20
    end
  end
end
