defmodule Nous.Eval.ScoringTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Case, Score, ScorerError, Scoring}
  alias Nous.Eval.Scorer.Spec
  alias Nous.Eval.Scorers
  alias Nous.Eval.TraceBuilder, as: B

  doctest Nous.Eval.Scoring

  defp fun(name, fun, spec_opts \\ []) do
    struct!(Spec, [module: Scorers.Function, opts: [name: name, fun: fun]] ++ spec_opts)
  end

  defp const(name, value, spec_opts \\ []), do: fun(name, fn _ -> value end, spec_opts)

  defp run(specs, opts \\ []) do
    {:ok, prepared} = Scoring.init(specs)
    input_opts = Keyword.take(opts, [:case])

    Scoring.score(
      prepared,
      B.input(B.new() |> B.build(), input_opts),
      Keyword.drop(opts, [:case])
    )
  end

  describe "init/1" do
    test "rejects unknown scorer options with the module" do
      spec = %Spec{module: Scorers.Contains, opts: [values: ["a"], vaules: ["b"]]}
      assert {:error, {Scorers.Contains, reason}} = Scoring.init([spec])
      assert reason =~ "unknown options [:vaules]"
    end

    test "rejects modules that are not scorers and bad composition" do
      assert {:error, {String, :not_a_scorer}} = Scoring.init([%Spec{module: String}])

      assert {:error, {Scorers.Function, {:invalid_weight, -1}}} =
               Scoring.init([const("x", true, weight: -1)])
    end

    test "rejects invalid regexes and empty value lists at init, not at scoring time" do
      assert {:error, {Scorers.Regex, _}} =
               Scoring.init([%Spec{module: Scorers.Regex, opts: [patterns: ["("]]}])

      assert {:error, {Scorers.Contains, _}} =
               Scoring.init([%Spec{module: Scorers.Contains, opts: [values: []]}])
    end
  end

  describe "verdict composition" do
    test "all gates pass" do
      assert %{verdict: :pass, case_score: 1.0, scorer_errors: []} =
               run([const("a", true), const("b", true)])
    end

    test "a failed gate fails the sample and zeroes case_score whatever the soft scores" do
      result = run([const("gate", false), const("soft", 1.0, required: false)])
      assert %{verdict: :fail, case_score: +0.0} = result
      assert ["gate", "soft"] = Enum.map(result.scores, & &1.name)
    end

    test "an error takes precedence over a failed gate and keeps the other scores" do
      result =
        run([
          const("gate", false),
          fun("broken", fn _ -> raise "boom" end),
          const("ok", true)
        ])

      assert %{verdict: :error, case_score: nil} = result

      assert [%ScorerError{scorer: "function", kind: :raised, reason: reason}] =
               result.scorer_errors

      assert reason =~ "boom"
      assert ["gate", "ok"] = Enum.map(result.scores, & &1.name)
    end

    test "the soft group passes at the threshold by weighted mean" do
      # (2·1.0 + 1·0.0) / 3 = 0.667
      specs = [
        const("a", 1.0, required: false, weight: 2),
        const("b", 0.0, required: false, weight: 1)
      ]

      assert %{verdict: :pass, case_score: score} = run(specs)
      assert_in_delta score, 2 / 3, 1.0e-9

      assert %{verdict: :fail} = run(specs, case: %Case{id: "c", input: "q", threshold: 0.7})

      assert %{verdict: :pass} =
               run(specs, case: %Case{id: "c", input: "q", threshold: 0.7}, threshold: 0.6)
    end

    test "the default soft threshold is 0.5" do
      assert %{verdict: :pass} = run([const("s", 0.5, required: false)])
      assert %{verdict: :fail, case_score: 0.4} = run([const("s", 0.4, required: false)])
    end

    test "weight 0 is tracked but never decides" do
      result = run([const("gate", true), const("cost", false, required: false, weight: 0)])
      assert %{verdict: :pass, case_score: 1.0} = result
      assert Enum.any?(result.scores, &(&1.name == "cost" and &1.value == :fail))
    end

    test "a required scorer may not skip unless skippable" do
      skip = fn _ -> {:skip, "not applicable"} end

      assert %{
               verdict: :error,
               scorer_errors: [%ScorerError{kind: :invalid_config, reason: reason}]
             } =
               run([fun("gate", skip), const("other", true)])

      assert reason =~ "required scorer skipped"

      assert %{verdict: :pass, skipped: [{"function", "not applicable"}]} =
               run([fun("gate", skip, skippable: true), const("other", true)])
    end

    test "a skipped soft scorer is left out of the mean" do
      result =
        run([
          const("s1", 0.9, required: false),
          fun("s2", fn _ -> {:skip, "n/a"} end, required: false)
        ])

      assert %{verdict: :pass, case_score: 0.9, skipped: [{"function", "n/a"}]} = result
    end

    test "labels count through declared label_values, unmapped labels are excluded" do
      labelled = fn label ->
        fn _ ->
          %Score{
            name: "judge",
            value: {:label, label},
            passed?: true,
            metadata: %{label_values: %{"good" => 1.0, "meh" => 0.25}}
          }
        end
      end

      assert %{case_score: 0.25, verdict: :fail} =
               run([fun("j", labelled.("meh"), required: false)])

      assert %{case_score: 0.8, verdict: :pass} =
               run([
                 fun("j", labelled.("unmapped"), required: false),
                 const("s", 0.8, required: false)
               ])
    end

    test "every score of a multi-score scorer inherits its declaration" do
      two = fn _ ->
        [
          %Score{name: "m.a", value: :pass, passed?: true},
          %Score{name: "m.b", value: :fail, passed?: false}
        ]
      end

      assert %{verdict: :fail, scores: [_, _]} = run([fun("m", two)])
      # Soft: the two scores average to 0.5, exactly the default threshold.
      assert %{verdict: :pass, case_score: 0.5} = run([fun("m", two, required: false)])
    end
  end

  describe "isolation" do
    test "a timed-out scorer errors and the others keep their scores" do
      slow = fun("slow", fn _ -> Process.sleep(5_000) end)
      result = run([slow, const("fast", true)], timeout: 50)

      assert %{verdict: :error, scorer_errors: [%ScorerError{kind: :timeout}]} = result
      assert [%Score{name: "fast"}] = result.scores
    end

    test "throws and exits are :raised" do
      result =
        run([
          fun("throw", fn _ -> throw(:oops) end),
          fun("exit", fn _ -> exit(:bye) end),
          const("ok", true)
        ])

      assert [%ScorerError{kind: :raised}, %ScorerError{kind: :raised}] = result.scorer_errors
      assert [%Score{name: "ok"}] = result.scores
    end
  end

  describe "score validation" do
    test "out-of-range floats are :non_finite, other bad values :invalid_config" do
      assert %{scorer_errors: [%ScorerError{kind: :non_finite}]} = run([const("x", 1.5)])

      bad = fn value -> fn _ -> %Score{name: "x", value: value, passed?: true} end end
      assert %{scorer_errors: [%ScorerError{kind: :non_finite}]} = run([fun("x", bad.(:nan))])
      assert %{scorer_errors: [%ScorerError{kind: :invalid_config}]} = run([fun("x", bad.(1))])

      assert %{scorer_errors: [%ScorerError{kind: :invalid_config}]} =
               run([fun("x", bad.({:label, :good}))])

      assert %{scorer_errors: [%ScorerError{kind: :invalid_config}]} =
               run([fun("x", fn _ -> %Score{name: :x, value: :pass, passed?: true} end)])

      assert %{scorer_errors: [%ScorerError{kind: :invalid_config}]} =
               run([fun("x", fn _ -> %Score{name: "x", value: :pass, passed?: nil} end)])

      assert %{scorer_errors: [%ScorerError{kind: :invalid_config}]} =
               run([const("x", {:ok, []})])

      assert %{scorer_errors: [%ScorerError{kind: :invalid_config}]} =
               run([const("x", :whatever)])
    end
  end
end
