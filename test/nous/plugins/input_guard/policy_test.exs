defmodule Nous.Plugins.InputGuard.PolicyTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Plugins.InputGuard.{Policy, Result}

  defp build_ctx do
    Context.new(messages: [Nous.Message.user("test")])
  end

  describe "apply/4" do
    test "safe severity returns context unchanged" do
      ctx = build_ctx()
      result = %Result{severity: :safe}

      {result_ctx, []} = Policy.apply(result, ctx, [], %{})
      assert result_ctx == ctx
    end

    test ":block action sets needs_response to false and adds assistant message" do
      ctx = build_ctx()
      result = %Result{severity: :blocked, reason: "injection detected"}

      {result_ctx, []} =
        Policy.apply(result, ctx, [], %{policy: %{blocked: :block}})

      assert result_ctx.needs_response == false
      last = List.last(result_ctx.messages)
      assert last.role == :assistant
      assert last.content =~ "injection detected"
    end

    test ":warn action adds system message and continues" do
      ctx = build_ctx()
      result = %Result{severity: :suspicious, reason: "might be injection"}

      {result_ctx, []} =
        Policy.apply(result, ctx, [], %{policy: %{suspicious: :warn}})

      system_msgs = Enum.filter(result_ctx.messages, &(&1.role == :system))
      assert length(system_msgs) == 1
      assert hd(system_msgs).content =~ "InputGuard warning"
      assert hd(system_msgs).content =~ "might be injection"
    end

    test ":log action returns context unchanged" do
      ctx = build_ctx()
      result = %Result{severity: :blocked, reason: "test"}

      {result_ctx, []} = Policy.apply(result, ctx, [], %{policy: %{blocked: :log}})
      assert result_ctx == ctx
    end

    test ":callback action calls on_violation function" do
      test_pid = self()
      ctx = build_ctx()
      result = %Result{severity: :blocked, reason: "test"}

      config = %{
        policy: %{blocked: :callback},
        on_violation: fn r -> send(test_pid, {:called, r.reason}) end
      }

      {_ctx, []} = Policy.apply(result, ctx, [], config)
      assert_receive {:called, "test"}
    end

    test "function/2 policy action receives result and context" do
      ctx = build_ctx()
      result = %Result{severity: :blocked, reason: "custom"}

      custom_fn = fn res, c ->
        Context.merge_deps(c, %{custom_action: res.reason})
      end

      {result_ctx, []} =
        Policy.apply(result, ctx, [], %{policy: %{blocked: custom_fn}})

      assert result_ctx.deps[:custom_action] == "custom"
    end

    test "nil action for severity passes through" do
      ctx = build_ctx()
      result = %Result{severity: :suspicious, reason: "test"}

      # Policy has no entry for :suspicious
      {result_ctx, []} = Policy.apply(result, ctx, [], %{policy: %{}})
      assert result_ctx == ctx
    end
  end
end
