defmodule Nous.PermissionsTest do
  use ExUnit.Case, async: true

  alias Nous.Permissions
  alias Nous.Permissions.Policy

  doctest Nous.Permissions

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

  describe "Policy.strictest/2" do
    test "nil means no policy: yields the other argument unchanged" do
      policy = Permissions.default_policy()

      assert Policy.strictest(nil, nil) == nil
      assert Policy.strictest(policy, nil) == policy
      assert Policy.strictest(nil, policy) == policy
    end

    test "picks the stricter mode" do
      assert Policy.strictest(%Policy{mode: :permissive}, %Policy{mode: :default}).mode ==
               :default

      assert Policy.strictest(%Policy{mode: :default}, %Policy{mode: :strict}).mode == :strict
      assert Policy.strictest(%Policy{mode: :strict}, %Policy{mode: :permissive}).mode == :strict
    end

    test "unions deny lists and approval requirements" do
      a = %Policy{
        deny_names: MapSet.new(["bash"]),
        deny_prefixes: ["net_"],
        approval_required: MapSet.new(["file_write"])
      }

      b = %Policy{
        deny_names: MapSet.new(["file_edit"]),
        deny_prefixes: ["net_", "sys_"],
        approval_required: MapSet.new(["file_edit"])
      }

      combined = Policy.strictest(a, b)

      assert combined.deny_names == MapSet.new(["bash", "file_edit"])
      assert Enum.sort(combined.deny_prefixes) == ["net_", "sys_"]
      assert combined.approval_required == MapSet.new(["file_write", "file_edit"])
    end

    test "allow_unattended_execute is ANDed" do
      yes = %Policy{allow_unattended_execute: true}
      no = %Policy{allow_unattended_execute: false}

      assert Policy.strictest(yes, yes).allow_unattended_execute
      refute Policy.strictest(yes, no).allow_unattended_execute
    end

    test "a single-sided allowlist stands (deny-by-default survives)" do
      allowlisted = %Policy{mode: :strict, allow_names: MapSet.new(["file_read"])}
      open = %Policy{mode: :default}

      combined = Policy.strictest(allowlisted, open)

      refute Permissions.blocked?(combined, "file_read")
      assert Permissions.blocked?(combined, "bash")
    end

    test "two allowlists intersect: only what BOTH sides allow survives" do
      a = %Policy{allow_names: MapSet.new(["file_read", "search"]), allow_prefixes: ["kb_"]}
      b = %Policy{allow_names: MapSet.new(["file_read"]), allow_prefixes: ["kb_index"]}

      combined = Policy.strictest(a, b)

      refute Permissions.blocked?(combined, "file_read")
      # allowed by a only
      assert Permissions.blocked?(combined, "search")
      # prefix intersection keeps the narrower prefix
      refute Permissions.blocked?(combined, "kb_index_build")
      assert Permissions.blocked?(combined, "kb_search")
    end

    test "names admitted by the other side's prefix survive intersection" do
      a = %Policy{allow_names: MapSet.new(["kb_search"])}
      b = %Policy{allow_prefixes: ["kb_"]}

      combined = Policy.strictest(a, b)

      refute Permissions.blocked?(combined, "kb_search")
      assert Permissions.blocked?(combined, "bash")
    end

    test "disjoint allowlists allow NOTHING rather than collapsing to no allowlist" do
      # Set intersection of disjoint allowlists is empty; an empty allowlist on
      # :default reads as "no allowlist" in blocked?/2 — the combined policy
      # must instead pin :strict so deny-by-default survives.
      a = %Policy{allow_names: MapSet.new(["file_read"])}
      b = %Policy{allow_names: MapSet.new(["search_web"])}

      combined = Policy.strictest(a, b)

      assert Permissions.blocked?(combined, "file_read")
      assert Permissions.blocked?(combined, "search_web")
      assert Permissions.blocked?(combined, "bash")
    end

    test "a template allowlist cannot widen a deny-all :strict policy" do
      # strict + empty allowlist = deny everything; it must not be treated as
      # "no opinion" letting the other side's allowlist stand.
      deny_all = Permissions.strict_policy()
      widener = %Policy{mode: :strict, allow_names: MapSet.new(["bash"])}

      assert Permissions.blocked?(Policy.strictest(deny_all, widener), "bash")
      assert Permissions.blocked?(Policy.strictest(widener, deny_all), "bash")
    end

    test "unknown modes rank strictest (fail closed)" do
      # Unknown modes outrank every known mode in strictest_mode/2...
      assert Policy.strictest(%Policy{mode: :bogus}, %Policy{mode: :default}).mode == :bogus
      # ...and the combined policy stays fail-closed downstream.
      assert Permissions.blocked?(Policy.strictest(%Policy{mode: :bogus}, %Policy{}), "bash")

      # A deny-all :strict side pins the result to strict-deny-all regardless
      # of the other side's mode label.
      combined = Policy.strictest(%Policy{mode: :bogus}, %Policy{mode: :strict})
      assert combined.mode == :strict
      assert Permissions.blocked?(combined, "bash")
    end
  end
end
