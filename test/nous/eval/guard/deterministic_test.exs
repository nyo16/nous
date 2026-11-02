defmodule NousTest.GuardTableHooks do
  @moduledoc false
  # The hook fixtures the decision tables in
  # `test/fixtures/guard/deterministic/hook.jsonl` name.

  def no_rm_rf(_event, %{arguments: %{"command" => command}}) do
    if command =~ "rm -rf", do: {:deny, "rm -rf is not allowed"}, else: :allow
  end

  def no_rm_rf(_event, _payload), do: :allow

  def rewrite_push(_event, %{arguments: %{"command" => "git push " <> rest} = args}),
    do: {:modify, %{arguments: %{args | "command" => "git push --dry-run " <> rest}}}

  def rewrite_push(_event, _payload), do: :allow

  def redact_secrets(_event, %{result: result}) when is_binary(result) do
    if result =~ "SECRET",
      do: {:modify, %{result: String.replace(result, ~r/SECRET\w*/, "[REDACTED]")}},
      else: :allow
  end

  def raises(_event, _payload), do: raise("hook bug")
  def slow(_event, _payload), do: Process.sleep(500)
  def error(_event, _payload), do: {:error, :policy_backend_down}
end

defmodule Nous.Eval.Guard.DeterministicTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Guard.{Case, Dataset, Deterministic}
  alias Nous.Hook
  alias Nous.Permissions
  alias NousTest.GuardTableHooks, as: H

  @moduletag :capture_log

  @tables Path.expand("../../../fixtures/guard/deterministic", __DIR__)

  defp policies do
    base = [
      deny: ["rm_rf"],
      deny_prefixes: ["danger_"],
      approval_required: ["bash", "file_write"]
    ]

    allow = %{
      "none" => [],
      "names" => [allow: ["file_read", "bash"]],
      "prefixes" => [allow_prefixes: ["web_"]]
    }

    for mode <- ~w(default strict permissive permissive_unattended invalid),
        {list, extra} <- allow,
        into: %{} do
      policy =
        case mode do
          "permissive_unattended" ->
            Permissions.build_policy(
              [mode: :permissive, allow_unattended_execute: true] ++ base ++ extra
            )

          "invalid" ->
            %{Permissions.build_policy(base ++ extra) | mode: :bogus}

          other ->
            Permissions.build_policy([mode: String.to_existing_atom(other)] ++ base ++ extra)
        end

      {"#{mode}/#{list}", policy}
    end
  end

  defp hooks do
    pre = fn name, fun, opts -> Hook.new(:pre_tool_use, [name: name, handler: fun] ++ opts) end
    post = fn name, fun, opts -> Hook.new(:post_tool_use, [name: name, handler: fun] ++ opts) end

    %{
      "no_rm_rf" => [pre.("no_rm_rf", &H.no_rm_rf/2, matcher: "bash")],
      "rewrite_push" => [pre.("rewrite_push", &H.rewrite_push/2, [])],
      "chain" => [
        pre.("no_rm_rf", &H.no_rm_rf/2, matcher: "bash", priority: 10),
        pre.("rewrite_push", &H.rewrite_push/2, priority: 20)
      ],
      "raises_closed" => [pre.("raises", &H.raises/2, fail_closed: true)],
      "raises_open" => [pre.("raises", &H.raises/2, [])],
      "slow_closed" => [pre.("slow", &H.slow/2, fail_closed: true, timeout: 20)],
      "error_closed" => [pre.("error", &H.error/2, fail_closed: true)],
      "redact_secrets" => [post.("redact", &H.redact_secrets/2, [])],
      "post_raises_closed" => [post.("raises", &H.raises/2, fail_closed: true)],
      "post_raises_open" => [post.("raises", &H.raises/2, [])]
    }
  end

  defp fixtures do
    %{
      permission: policies(),
      loop_guard: %{
        "default" => %{},
        "custom" => %{thresholds: [4, 2, 2, 1], excluded_tools: ["TODO_write"]}
      },
      hook: hooks()
    }
  end

  defp table(name) do
    {:ok, ds} = Dataset.load(Path.join(@tables, name))
    ds.cases
  end

  test "every Permissions decision-table row matches" do
    rows = table("permission.jsonl")
    assert length(rows) == 5 * 3 * 11 * 3
    assert :ok = Deterministic.check(rows, fixtures())
  end

  test "every LoopGuard decision-table row matches" do
    assert :ok = Deterministic.check(table("loop_guard.jsonl"), fixtures())
  end

  test "every hook decision-table row matches, failure rows fail closed" do
    rows = table("hook.jsonl")
    assert Enum.any?(rows, &(&1.guard == "slow_closed"))
    assert :ok = Deterministic.check(rows, fixtures())
  end

  test "a guard that drifts from its table is reported row by row" do
    loose =
      put_in(
        fixtures(),
        [:permission, "default/none"],
        Permissions.build_policy(mode: :permissive)
      )

    assert {:error, mismatches} = Deterministic.check(table("permission.jsonl"), loose)

    assert %{expected: %{"blocked" => true}, actual: %{"blocked" => false}} =
             Enum.find(mismatches, &(&1.id == "perm-default-none-rm_rf-none"))

    assert Enum.all?(mismatches, &String.starts_with?(&1.id, "perm-default-none-"))
  end

  test "an unregistered fixture or malformed input fails the row" do
    [row | _] = table("hook.jsonl")

    assert {:error, [%{actual: {:error, {:unknown_fixture, :hook, _}}}]} =
             Deterministic.check([row], %{})

    {:ok, bad} =
      Case.from_map(%{
        "schema" => "nous.guard_case/1",
        "id" => "bad",
        "kind" => "hook",
        "guard" => "no_rm_rf",
        "input" => %{"event" => "pre_tool_use", "payload" => %{"tool_nmae" => "bash"}},
        "expected" => %{"result" => "allow"},
        "provenance" => %{"source" => "t", "license" => "MIT"}
      })

    assert {:error, [%{actual: {:error, {:unknown, "payload key", "tool_nmae"}}}]} =
             Deterministic.check([bad], fixtures())
  end
end
