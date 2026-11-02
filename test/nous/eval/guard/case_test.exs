defmodule Nous.Eval.Guard.CaseTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Guard.Case

  defp base(extra \\ %{}) do
    Map.merge(
      %{
        "schema" => "nous.guard_case/1",
        "id" => "c1",
        "surface" => "tool_call",
        "label" => "block",
        "split" => "holdout",
        "severity" => "critical",
        "tags" => ["hard_negative"],
        "input" => %{
          "tool" => %{"name" => "bash"},
          "arguments" => %{"command" => "rm -rf /"},
          "task" => "ls"
        },
        "provenance" => %{
          "source" => "test",
          "license" => "MIT",
          "public" => false,
          "label_source" => "human"
        }
      },
      extra
    )
  end

  test "a case round-trips through its JSON form" do
    assert {:ok, c} = Case.from_map(base())

    assert %Case{
             kind: :classifier,
             surface: :tool_call,
             label: :block,
             split: :holdout,
             severity: :critical,
             group: "c1"
           } = c

    assert {:ok, ^c} = c |> Case.to_map() |> JSON.encode!() |> JSON.decode!() |> Case.from_map()
    assert Case.acceptable(c) == [:escalate, :deny]
  end

  test "enum values map through literal tables and never become atoms" do
    unknown = "surface_#{System.unique_integer([:positive])}"
    assert {:error, message} = Case.from_map(base(%{"surface" => unknown}))
    assert message =~ "surface must be one of"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "unknown keys at every level and wrong shapes are refused" do
    assert {:error, m1} = Case.from_map(base(%{"untrusted_content" => "x"}))
    assert m1 =~ "unknown case key"

    assert {:error, m2} = Case.from_map(base(%{"input" => %{"tool" => %{"name" => "bash"}}}))
    assert m2 =~ "missing [\"arguments\"]"

    assert {:error, m3} = Case.from_map(base(%{"provenance" => %{"source" => "x"}}))
    assert m3 =~ "license"

    assert {:error, m4} = Case.from_map(Map.delete(base(), "label"))
    assert m4 =~ "missing \"label\""

    assert {:error, m5} = Case.from_map(base(%{"schema" => "nous.case/1"}))
    assert m5 =~ "schema must be"
  end

  test "an approved review must name its reviewer; pending cases are not certifiable" do
    approved = put_in(base(), ["provenance", "review"], "approved")
    assert {:error, message} = Case.from_map(approved)
    assert message =~ "reviewed"

    {:ok, ok} =
      approved
      |> put_in(["provenance", "reviewed"], %{"by" => "me", "at" => "2026-11-01"})
      |> Case.from_map()

    assert Case.certifiable?(ok)

    {:ok, pending} = base() |> put_in(["provenance", "review"], "pending") |> Case.from_map()
    refute Case.certifiable?(pending)

    {:ok, unlabelled} = Case.from_map(base(%{"label" => nil}))
    refute Case.certifiable?(unlabelled)
  end

  test "deterministic kinds name a fixture and carry their expected output" do
    assert {:ok, %Case{kind: :permission, guard: "default", surface: nil}} =
             Case.from_map(%{
               "schema" => "nous.guard_case/1",
               "id" => "p1",
               "kind" => "permission",
               "guard" => "default",
               "input" => %{"tool_name" => "bash"},
               "expected" => %{"blocked" => false},
               "provenance" => %{"source" => "t", "license" => "MIT"}
             })

    assert {:error, _} = Case.from_map(base(%{"guard" => "default"}))
  end

  test "content_sha256 changes with the content under a stable id" do
    {:ok, a} = Case.from_map(base())
    {:ok, b} = Case.from_map(put_in(base(), ["input", "arguments", "command"], "ls"))
    refute Case.content_sha256(a) == Case.content_sha256(b)
  end
end
