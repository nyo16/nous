defmodule Nous.PermissionsTest do
  use ExUnit.Case, async: true

  alias Nous.Permissions
  alias Nous.Permissions.Policy

  describe "default_policy/0" do
    test "returns a policy with default mode" do
      policy = Permissions.default_policy()
      assert policy.mode == :default
    end

    test "bash requires approval by default" do
      policy = Permissions.default_policy()
      assert Permissions.requires_approval?(policy, "bash")
    end

    test "read tools do not require approval by default" do
      policy = Permissions.default_policy()
      refute Permissions.requires_approval?(policy, "file_read")
      refute Permissions.requires_approval?(policy, "file_grep")
    end
  end

  describe "permissive_policy/0" do
    test "no tool requires approval" do
      policy = Permissions.permissive_policy()
      refute Permissions.requires_approval?(policy, "bash")
      refute Permissions.requires_approval?(policy, "file_write")
    end
  end

  describe "strict_policy/0" do
    test "all tools require approval" do
      policy = Permissions.strict_policy()
      assert Permissions.requires_approval?(policy, "file_read")
      assert Permissions.requires_approval?(policy, "bash")
    end
  end

  describe "build_policy/1" do
    test "builds from keyword opts" do
      policy =
        Permissions.build_policy(
          mode: :default,
          deny: ["dangerous_tool"],
          deny_prefixes: ["web_"],
          approval_required: ["bash"]
        )

      assert Permissions.blocked?(policy, "dangerous_tool")
      assert Permissions.blocked?(policy, "web_fetch")
      assert Permissions.requires_approval?(policy, "bash")
      refute Permissions.blocked?(policy, "file_read")
    end
  end

  describe "blocked?/2" do
    test "blocks by exact name (case-insensitive)" do
      policy = %Policy{deny_names: MapSet.new(["bash"])}
      assert Permissions.blocked?(policy, "bash")
      assert Permissions.blocked?(policy, "BASH")
      assert Permissions.blocked?(policy, "Bash")
      refute Permissions.blocked?(policy, "file_read")
    end

    test "blocks by prefix (case-insensitive)" do
      policy = %Policy{deny_prefixes: ["web_"]}
      assert Permissions.blocked?(policy, "web_fetch")
      assert Permissions.blocked?(policy, "web_search")
      assert Permissions.blocked?(policy, "Web_Fetch")
      refute Permissions.blocked?(policy, "file_read")
    end

    test "empty policy blocks nothing" do
      policy = %Policy{}
      refute Permissions.blocked?(policy, "bash")
      refute Permissions.blocked?(policy, "anything")
    end
  end

  describe "requires_approval?/2" do
    test "default mode uses approval set" do
      policy = %Policy{mode: :default, approval_required: MapSet.new(["bash"])}
      assert Permissions.requires_approval?(policy, "bash")
      refute Permissions.requires_approval?(policy, "file_read")
    end

    test "permissive mode never requires approval" do
      policy = %Policy{mode: :permissive, approval_required: MapSet.new(["bash"])}
      refute Permissions.requires_approval?(policy, "bash")
    end

    test "strict mode always requires approval" do
      policy = %Policy{mode: :strict}
      assert Permissions.requires_approval?(policy, "file_read")
    end
  end

  describe "filter_tools/2" do
    test "removes blocked tools" do
      tool1 = %Nous.Tool{name: "bash", function: fn _ -> :ok end, parameters: %{}}
      tool2 = %Nous.Tool{name: "file_read", function: fn _ -> :ok end, parameters: %{}}
      tool3 = %Nous.Tool{name: "web_fetch", function: fn _ -> :ok end, parameters: %{}}

      policy = Permissions.build_policy(deny: ["bash"], deny_prefixes: ["web_"])
      filtered = Permissions.filter_tools(policy, [tool1, tool2, tool3])

      assert length(filtered) == 1
      assert hd(filtered).name == "file_read"
    end

    test "empty policy allows all tools" do
      tools = [
        %Nous.Tool{name: "bash", function: fn _ -> :ok end, parameters: %{}},
        %Nous.Tool{name: "file_read", function: fn _ -> :ok end, parameters: %{}}
      ]

      policy = %Policy{}
      assert Permissions.filter_tools(policy, tools) == tools
    end
  end

  describe "partition_tools/2" do
    test "splits into allowed and blocked" do
      tool1 = %Nous.Tool{name: "bash", function: fn _ -> :ok end, parameters: %{}}
      tool2 = %Nous.Tool{name: "file_read", function: fn _ -> :ok end, parameters: %{}}

      policy = Permissions.build_policy(deny: ["bash"])
      {allowed, blocked} = Permissions.partition_tools(policy, [tool1, tool2])

      assert length(allowed) == 1
      assert hd(allowed).name == "file_read"
      assert length(blocked) == 1
      assert hd(blocked).name == "bash"
    end
  end
end
