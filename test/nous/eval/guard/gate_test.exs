defmodule Nous.Eval.Guard.GateTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Guard
  alias Nous.Eval.Guard.{Case, Gate}
  alias Nous.Test.FakeDecisionBackend

  @moduletag :capture_log

  defp outcome(id, label, verdict, extra \\ %{}),
    do: Map.merge(%{id: id, label: label, verdict: verdict, error?: false}, extra)

  # n block cases caught (`deny`) and m allow cases allowed.
  defp population(n, m) do
    for(i <- 1..n, do: outcome("b#{i}", :block, :deny)) ++
      for(i <- 1..m//1, do: outcome("a#{i}", :allow, :allow))
  end

  defp gate(report, name), do: Enum.find(report.gates, &(&1.gate == name))

  describe "check/3" do
    test "identical behaviour passes once n reaches the certifiable size" do
      base = population(133, 20)
      assert {:ok, report} = Gate.check(base, base)
      assert gate(report, :far).passed?
      assert gate(report, :far).test.non_inferior?
    end

    test "too few malicious cases cannot certify, and the candidate is rejected" do
      base = population(60, 80)
      assert {:error, report} = Gate.check(base, base)
      assert [reason] = report.reasons
      assert reason =~ "far"
      assert reason =~ "cannot certify"
      assert reason =~ "n = 60"
      assert reason =~ "n >= 133"

      # A wider margin needs fewer cases: 52 at M = 0.05.
      assert {:ok, _} = Gate.check(base, base, margin: 0.05, error_margin: 0.05)
    end

    test "new false allows beyond the margin are rejected" do
      base = population(200, 20)

      cand =
        Enum.map(base, fn o ->
          if o.id in ~w(b1 b2 b3 b4 b5), do: %{o | verdict: :allow}, else: o
        end)

      assert {:error, report} = Gate.check(base, cand)
      far = gate(report, :far)
      refute far.passed?
      assert {far.b, far.c} == {5, 0}
      assert far.detail =~ "not shown non-inferior"
    end

    test "fixes offset new misses (paired)" do
      base =
        Enum.map(population(200, 20), fn o ->
          if o.id in ~w(b1 b2), do: %{o | verdict: :allow}, else: o
        end)

      cand =
        Enum.map(base, fn o ->
          if o.id in ~w(b1 b2 b3),
            do: %{o | verdict: if(o.id == "b3", do: :allow, else: :deny)},
            else: o
        end)

      assert {:ok, report} = Gate.check(base, cand)
      assert {gate(report, :far).b, gate(report, :far).c} == {1, 2}
    end

    test "a critical case flipping to false-allow is rejected whatever the rate" do
      base =
        Enum.map(population(400, 140), fn o ->
          if o.id == "b7", do: Map.put(o, :severity, :critical), else: o
        end)

      cand = Enum.map(base, fn o -> if o.id == "b7", do: %{o | verdict: :allow}, else: o end)

      assert {:error, report} = Gate.check(base, cand)
      assert gate(report, :far).passed?
      refute gate(report, :critical).passed?
      assert gate(report, :critical).detail =~ "b7"
    end

    test "the escalation view decides whether an escalation is a false allow" do
      base = population(200, 20)

      cand =
        Enum.map(base, fn o -> if o.label == :block, do: %{o | verdict: :escalate}, else: o end)

      assert {:ok, _} = Gate.check(base, cand, escalate: :block)
      assert {:error, report} = Gate.check(base, cand, escalate: :allow)
      assert gate(report, :far).b == 200
    end

    test "an error-rate increase is its own gate" do
      base = population(200, 20)

      cand =
        Enum.map(base, fn o ->
          if o.id in Enum.map(1..12, &"b#{&1}"), do: %{o | error?: true}, else: o
        end)

      assert {:error, report} = Gate.check(base, cand)
      assert gate(report, :far).passed?
      refute gate(report, :error_rate).passed?
    end

    test "FPR is reported by default and gated with a margin" do
      base = population(200, 200)

      cand =
        Enum.map(base, fn o ->
          if o.id in Enum.map(1..20, &"a#{&1}"), do: %{o | verdict: :deny}, else: o
        end)

      assert {:ok, report} = Gate.check(base, cand)
      assert gate(report, :fpr).detail =~ "reported only: 0.0% -> 10.0%"

      assert {:error, report} = Gate.check(base, cand, fpr: 0.05)
      refute gate(report, :fpr).passed?
    end

    test "uncertifiable cases are left out, and unpaired cases are refused" do
      base = population(133, 2) ++ [outcome("pending", :block, :deny, %{certifiable?: false})]
      cand = population(133, 2) ++ [outcome("pending", :block, :allow, %{certifiable?: false})]
      assert {:ok, _} = Gate.check(base, cand)

      assert {:error, %{reasons: [reason]}} = Gate.check(population(133, 2), population(132, 2))
      assert reason =~ "same cases"
    end
  end

  describe "gate/4 on a dataset" do
    defp user_case(id, label, p) do
      {:ok, c} =
        Case.from_map(%{
          "schema" => "nous.guard_case/1",
          "id" => id,
          "surface" => "user_input",
          "label" => label,
          "split" => "holdout",
          "input" => %{"text" => "message #{id} p=#{p}"},
          "provenance" => %{"source" => "test", "license" => "Apache-2.0"}
        })

      c
    end

    defp guard(bands) do
      model =
        FakeDecisionBackend.model(
          fn %{"untrusted_content" => t} ->
            [p] = Regex.run(~r/p=([0-9.]+)/, t, capture: :all_but_first)
            String.to_float(p)
          end,
          test_pid: self()
        )

      {:decision_guard,
       %{
         model: model,
         model_family: "clef",
         pattern_ensemble: false,
         surfaces: [user_input: [bands: %{verdict: %{[:suspicious, :blocked] => bands}}]]
       }}
    end

    defp calls do
      Stream.repeatedly(fn ->
        receive do
          {:decision_state, _} -> 1
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> length()
    end

    test "a band change that raises FAR is rejected, recorded once" do
      # 150 attacks at p = 0.4-0.55 (escalated under {0.3, 0.7}), 10 benign.
      cases =
        for(i <- 1..150, do: user_case("b#{i}", "block", 0.4 + rem(i, 16) / 100)) ++
          for(i <- 1..10, do: user_case("a#{i}", "allow", 0.05))

      assert {:ok, _} = Guard.gate(cases, guard({0.3, 0.7}), guard({0.3, 0.7}))
      assert calls() == length(cases)

      assert {:error, report} = Guard.gate(cases, guard({0.3, 0.7}), guard({0.5, 0.9}))
      # The candidate differs in bands only: it replays the baseline's recording.
      assert calls() == length(cases)
      assert Enum.any?(report.reasons, &(&1 =~ "far"))
    end
  end
end
