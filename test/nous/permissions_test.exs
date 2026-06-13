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
    test "no tool requires approval (name-only check)" do
      policy = Permissions.permissive_policy()
      refute Permissions.requires_approval?(policy, "bash")
      refute Permissions.requires_approval?(policy, "file_write")
    end
  end

  describe "requires_approval?/3 (category-aware) under :permissive" do
    test "execute-category tools still require approval by default" do
      policy = Permissions.permissive_policy()
      # The single :permissive switch must NOT silently enable unattended RCE.
      assert Permissions.requires_approval?(policy, "bash", :execute)
      assert Permissions.requires_approval?(policy, "custom_shell", :execute)
    end

    test "non-execute categories remain auto-approved under :permissive" do
      policy = Permissions.permissive_policy()
      refute Permissions.requires_approval?(policy, "file_write", :write)
      refute Permissions.requires_approval?(policy, "file_read", :read)
      refute Permissions.requires_approval?(policy, "anything", nil)
    end

    test "allow_unattended_execute: true opts execute tools back out" do
      policy = Permissions.build_policy(mode: :permissive, allow_unattended_execute: true)
      refute Permissions.requires_approval?(policy, "bash", :execute)
    end

    test ":default and :strict modes are unaffected by category arg" do
      default = Permissions.default_policy()
      assert Permissions.requires_approval?(default, "bash", :execute)
      refute Permissions.requires_approval?(default, "file_read", :read)

      strict = Permissions.strict_policy()
      assert Permissions.requires_approval?(strict, "anything", :read)
    end

    test "3-arity agrees with 2-arity for non-permissive modes" do
      policy = Permissions.default_policy()

      for name <- ["bash", "file_read", "file_write"] do
        assert Permissions.requires_approval?(policy, name) ==
                 Permissions.requires_approval?(policy, name, :execute)
      end
    end
  end

  describe "strict_policy/0" do
    test "all tools require approval" do
      policy = Permissions.strict_policy()
      assert Permissions.requires_approval?(policy, "file_read")
      assert Permissions.requires_approval?(policy, "bash")
    end

    test "strict mode is deny-by-default at the filter layer (no allowlist)" do
      # Regression test for H-18: previously blocked? ignored mode, so
      # strict_policy() with empty deny lists silently allowed every tool.
      policy = Permissions.strict_policy()
      assert Permissions.blocked?(policy, "bash")
      assert Permissions.blocked?(policy, "file_read")
    end

    test "strict mode honors allow_names allowlist" do
      policy =
        Permissions.build_policy(mode: :strict, allow: ["file_read", "search_web"])

      refute Permissions.blocked?(policy, "file_read")
      refute Permissions.blocked?(policy, "search_web")
      assert Permissions.blocked?(policy, "bash")
    end

    test "strict mode honors allow_prefixes" do
      policy = Permissions.build_policy(mode: :strict, allow_prefixes: ["search_"])
      refute Permissions.blocked?(policy, "search_web")
      assert Permissions.blocked?(policy, "bash")
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

  describe "allowlist enforcement across modes" do
    test "allow list is deny-by-default in :default mode (not just :strict)" do
      # Regression: allow lists were only honored in :strict, so
      # build_policy(allow: [...]) on the default mode allowed everything.
      policy = Permissions.build_policy(allow: ["file_read"])

      refute Permissions.blocked?(policy, "file_read")
      assert Permissions.blocked?(policy, "bash")
    end

    test "allow_prefixes are honored in :default mode" do
      policy = Permissions.build_policy(allow_prefixes: ["file_"])

      refute Permissions.blocked?(policy, "file_write")
      assert Permissions.blocked?(policy, "bash")
    end

    test "deny still wins over allow" do
      policy = Permissions.build_policy(allow: ["bash"], deny: ["bash"])
      assert Permissions.blocked?(policy, "bash")
    end
  end

  describe "mode validation and fail-closed" do
    test "build_policy rejects an unknown mode" do
      assert_raise ArgumentError, fn -> Permissions.build_policy(mode: :strick) end
    end

    test "blocked?/2 fails closed for an unknown mode" do
      policy = %Policy{mode: :bogus}
      assert Permissions.blocked?(policy, "anything")
    end

    test "requires_approval?/2 fails closed for an unknown mode" do
      policy = %Policy{mode: :bogus}
      assert Permissions.requires_approval?(policy, "anything")
    end
  end
end
