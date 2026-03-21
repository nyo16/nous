defmodule Nous.HookTest do
  use ExUnit.Case, async: true

  alias Nous.Hook

  describe "struct creation" do
    test "creates hook with required fields" do
      hook = %Hook{event: :pre_tool_use, type: :function, handler: fn _, _ -> :allow end}
      assert hook.event == :pre_tool_use
      assert hook.type == :function
      assert hook.priority == 100
      assert hook.timeout == 10_000
      assert hook.matcher == nil
      assert hook.name == nil
    end

    test "creates hook with all fields" do
      hook = %Hook{
        event: :post_tool_use,
        type: :module,
        handler: SomeModule,
        matcher: "tool_name",
        priority: 50,
        timeout: 5_000,
        name: "my_hook"
      }

      assert hook.event == :post_tool_use
      assert hook.priority == 50
      assert hook.name == "my_hook"
    end
  end

  describe "new/2" do
    test "creates hook from opts" do
      handler = fn _, _ -> :allow end
      hook = Hook.new(:pre_tool_use, handler: handler, priority: 10, name: "test")
      assert hook.event == :pre_tool_use
      assert hook.handler == handler
      assert hook.priority == 10
      assert hook.name == "test"
    end
  end

  describe "blocking_event?/1" do
    test "pre_tool_use is blocking" do
      assert Hook.blocking_event?(:pre_tool_use)
    end

    test "pre_request is blocking" do
      assert Hook.blocking_event?(:pre_request)
    end

    test "post_tool_use is not blocking" do
      refute Hook.blocking_event?(:post_tool_use)
    end

    test "session_start is not blocking" do
      refute Hook.blocking_event?(:session_start)
    end
  end

  describe "matches?/2" do
    test "nil matcher matches everything" do
      hook = %Hook{
        event: :pre_tool_use,
        type: :function,
        handler: fn _, _ -> :allow end,
        matcher: nil
      }

      assert Hook.matches?(hook, %{tool_name: "anything"})
      assert Hook.matches?(hook, %{})
    end

    test "string matcher matches exact tool name" do
      hook = %Hook{
        event: :pre_tool_use,
        type: :function,
        handler: fn _, _ -> :allow end,
        matcher: "delete_file"
      }

      assert Hook.matches?(hook, %{tool_name: "delete_file"})
      refute Hook.matches?(hook, %{tool_name: "read_file"})
    end

    test "regex matcher matches tool name pattern" do
      hook = %Hook{
        event: :pre_tool_use,
        type: :function,
        handler: fn _, _ -> :allow end,
        matcher: ~r/^delete/
      }

      assert Hook.matches?(hook, %{tool_name: "delete_file"})
      assert Hook.matches?(hook, %{tool_name: "delete_user"})
      refute Hook.matches?(hook, %{tool_name: "read_file"})
    end

    test "function matcher calls predicate" do
      hook = %Hook{
        event: :pre_tool_use,
        type: :function,
        handler: fn _, _ -> :allow end,
        matcher: fn %{tool_name: name} -> String.starts_with?(name, "write") end
      }

      assert Hook.matches?(hook, %{tool_name: "write_file"})
      refute Hook.matches?(hook, %{tool_name: "read_file"})
    end
  end
end
