defmodule Nous.Teams.RoleTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.Role
  alias Nous.Tool

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

    test "allowed_tools takes precedence over denied_tools", %{tools: tools} do
      # When allowed_tools is set, denied_tools is ignored
      role = Role.new(name: :mixed, allowed_tools: ["search"], denied_tools: ["search"])
      filtered = Role.apply_tool_filter(role, tools)

      assert length(filtered) == 1
      assert hd(filtered).name == "search"
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
