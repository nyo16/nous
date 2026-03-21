defmodule Nous.Hook.RunnerTest do
  use ExUnit.Case, async: true

  alias Nous.Hook
  alias Nous.Hook.{Registry, Runner}

  defp make_hook(event, handler, opts \\ []) do
    %Hook{
      event: event,
      type: Keyword.get(opts, :type, :function),
      handler: handler,
      matcher: Keyword.get(opts, :matcher),
      priority: Keyword.get(opts, :priority, 100),
      timeout: Keyword.get(opts, :timeout, 10_000),
      name: Keyword.get(opts, :name)
    }
  end

  describe "run/3 with nil registry" do
    test "returns :allow" do
      assert Runner.run(nil, :pre_tool_use, %{}) == :allow
    end
  end

  describe "run/3 with empty registry" do
    test "returns :allow when no hooks match" do
      registry = Registry.new()
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "test"}) == :allow
    end
  end

  describe "blocking events (pre_tool_use)" do
    test "allows when all hooks return :allow" do
      hooks = [
        make_hook(:pre_tool_use, fn _, _ -> :allow end, name: "h1"),
        make_hook(:pre_tool_use, fn _, _ -> :allow end, name: "h2")
      ]

      registry = Registry.from_hooks(hooks)
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "test"}) == :allow
    end

    test "denies when any hook returns :deny" do
      hooks = [
        make_hook(:pre_tool_use, fn _, _ -> :allow end, name: "h1", priority: 1),
        make_hook(:pre_tool_use, fn _, _ -> :deny end, name: "h2", priority: 2)
      ]

      registry = Registry.from_hooks(hooks)
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "test"}) == :deny
    end

    test "denies with reason" do
      hook = make_hook(:pre_tool_use, fn _, _ -> {:deny, "not allowed"} end)
      registry = Registry.from_hooks([hook])
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "test"}) == {:deny, "not allowed"}
    end

    test "short-circuits on first deny" do
      # Track which hooks run
      test_pid = self()

      hooks = [
        make_hook(
          :pre_tool_use,
          fn _, _ ->
            send(test_pid, :hook_1_ran)
            :deny
          end, priority: 1),
        make_hook(
          :pre_tool_use,
          fn _, _ ->
            send(test_pid, :hook_2_ran)
            :allow
          end, priority: 2)
      ]

      registry = Registry.from_hooks(hooks)
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "test"}) == :deny

      assert_received :hook_1_ran
      refute_received :hook_2_ran
    end

    test "applies modifications and continues" do
      hooks = [
        make_hook(
          :pre_tool_use,
          fn _, _ ->
            {:modify, %{arguments: %{"modified" => true}}}
          end, priority: 1),
        make_hook(
          :pre_tool_use,
          fn _, payload ->
            if payload[:arguments][:modified] || payload.arguments["modified"] do
              :allow
            else
              :deny
            end
          end, priority: 2)
      ]

      registry = Registry.from_hooks(hooks)
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "test", arguments: %{}}) == :allow
    end

    test "errors fail open" do
      hook = make_hook(:pre_tool_use, fn _, _ -> raise "boom" end)
      registry = Registry.from_hooks([hook])
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "test"}) == :allow
    end
  end

  describe "non-blocking events (post_tool_use)" do
    test "collects modifications" do
      hooks = [
        make_hook(:post_tool_use, fn _, _ -> {:modify, %{extra: "data"}} end),
        make_hook(:post_tool_use, fn _, _ -> :allow end)
      ]

      registry = Registry.from_hooks(hooks)

      assert Runner.run(registry, :post_tool_use, %{tool_name: "test"}) ==
               {:modify, %{extra: "data"}}
    end

    test "merges multiple modifications" do
      hooks = [
        make_hook(:post_tool_use, fn _, _ -> {:modify, %{a: 1}} end, priority: 1),
        make_hook(:post_tool_use, fn _, _ -> {:modify, %{b: 2}} end, priority: 2)
      ]

      registry = Registry.from_hooks(hooks)

      assert Runner.run(registry, :post_tool_use, %{tool_name: "test"}) ==
               {:modify, %{a: 1, b: 2}}
    end

    test "runs all hooks even if one errors" do
      test_pid = self()

      hooks = [
        make_hook(:post_tool_use, fn _, _ -> raise "boom" end, priority: 1),
        make_hook(
          :post_tool_use,
          fn _, _ ->
            send(test_pid, :hook_2_ran)
            :allow
          end, priority: 2)
      ]

      registry = Registry.from_hooks(hooks)
      Runner.run(registry, :post_tool_use, %{tool_name: "test"})

      assert_received :hook_2_ran
    end
  end

  describe "module-based hooks" do
    defmodule AllowHook do
      @behaviour Nous.Hook
      @impl true
      def handle(_event, _payload), do: :allow
    end

    defmodule DenyHook do
      @behaviour Nous.Hook
      @impl true
      def handle(_event, %{tool_name: "dangerous"}), do: :deny
      def handle(_event, _payload), do: :allow
    end

    test "module hook that allows" do
      hook = make_hook(:pre_tool_use, AllowHook, type: :module)
      registry = Registry.from_hooks([hook])
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "test"}) == :allow
    end

    test "module hook that denies" do
      hook = make_hook(:pre_tool_use, DenyHook, type: :module)
      registry = Registry.from_hooks([hook])
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "dangerous"}) == :deny
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "safe"}) == :allow
    end
  end

  describe "matcher filtering" do
    test "only runs hooks matching tool name" do
      test_pid = self()

      hooks = [
        make_hook(
          :pre_tool_use,
          fn _, _ ->
            send(test_pid, :delete_hook_ran)
            :deny
          end, matcher: "delete_file"),
        make_hook(
          :pre_tool_use,
          fn _, _ ->
            send(test_pid, :read_hook_ran)
            :allow
          end, matcher: "read_file")
      ]

      registry = Registry.from_hooks(hooks)
      assert Runner.run(registry, :pre_tool_use, %{tool_name: "read_file"}) == :allow

      refute_received :delete_hook_ran
      assert_received :read_hook_ran
    end
  end

  describe "run_hooks/3 direct" do
    test "handles empty list" do
      assert Runner.run_hooks([], :pre_tool_use, %{}) == :allow
    end
  end
end
