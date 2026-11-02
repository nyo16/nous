defmodule Nous.Eval.JudgeCalibrationTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Nous.Eval.{Codec, JudgeCalibration, Stats}
  alias Nous.Eval.JudgeCalibration.{Case, Result}
  alias Nous.Eval.JudgeStub
  alias Nous.Eval.Scorers.Judge

  @judge "openai:judge-model-2026-01-01"

  # The scripted judge answers whatever the replayed output asks for
  # ("judge says: <label>"), so each case's judge verdict is fixed by the
  # data and independent of request order.
  defp install_judge do
    JudgeStub.install(fn %{user: user} ->
      [_, label] = Regex.run(~r/judge says: (\S+)/, JudgeStub.fenced(user, "AGENT_OUTPUT"))
      JudgeStub.verdict(label)
    end)
  end

  defp judge_case(id, human, judge, split \\ "holdout") do
    %Case{
      id: id,
      input: "question #{id}",
      output: "answer #{id}; judge says: #{judge}",
      human_label: human,
      annotator: "ana",
      split: split,
      group: id,
      provenance: "fixture"
    }
  end

  describe "calibrate/3 on a binary judge" do
    setup do
      install_judge()

      holdout =
        [
          {"pass", "pass"},
          {"pass", "pass"},
          {"pass", "pass"},
          {"pass", "pass"},
          {"pass", "fail"},
          {"fail", "fail"},
          {"fail", "fail"},
          {"fail", "pass"},
          {"fail", "fail"},
          {"pass", "maybe"}
        ]
        |> Enum.with_index(1)
        |> Enum.map(fn {{human, judge}, i} -> judge_case("h#{i}", human, judge) end)

      tune = [judge_case("t1", "pass", "pass", "tune"), judge_case("t2", "fail", "pass", "tune")]
      %{cases: tune ++ holdout}
    end

    test "metrics match hand-computed values on the holdout split", %{cases: cases} do
      assert {:ok, %Result{} = r} = JudgeCalibration.calibrate([judge: @judge], cases)

      assert {r.n_cases, r.n_tune, r.n_holdout, r.n_scored, r.n_errors} == {12, 2, 10, 9, 1}

      # 7 of 9 scored cases agree.
      assert r.agreement.count == 7 and r.agreement.n == 9
      assert r.agreement.estimate == 7 / 9
      assert {:ok, %{ci: ci}} = Stats.wilson(7, 9)
      assert r.agreement.ci == ci

      # Human pass 5 / fail 4, judge pass 5 / fail 4: p_o = 7/9, p_e = 41/81,
      # κ = (63 − 41) / (81 − 41) = 0.55.
      assert r.kappa_kind == :cohen
      assert_in_delta r.kappa, 0.55, 1.0e-12

      assert r.confusion == %{labels: ["pass", "fail"], matrix: [[4, 1], [1, 3]]}

      # One of the four human-failed cases passed the judge.
      assert %{estimate: 0.25, count: 1, n: 4} = r.false_pass
      assert %{estimate: 0.1, count: 1, n: 10} = r.error_rate
      assert [%{case_id: "h10", kind: :judge_out_of_range}] = r.errors

      assert %Nous.Usage{input_tokens: 900, output_tokens: 180} = r.usage
      assert r.judge["model"] == @judge
      {:ok, config} = Judge.init(judge: @judge)
      assert r.fingerprint_id == Judge.fingerprint_id(config)
    end

    test "only holdout cases reach the judge", %{cases: cases} do
      assert {:ok, _} = JudgeCalibration.calibrate([judge: @judge], cases, concurrency: 2)

      outputs =
        for _ <- 1..10 do
          assert_receive {:judge_request, _, messages, _}
          JudgeStub.fenced(JudgeStub.user_prompt(messages), "AGENT_OUTPUT")
        end

      refute_receive {:judge_request, _, _, _}
      refute Enum.any?(outputs, &(&1 =~ ~r/answer t\d/))
    end

    test "the result round-trips through the codec", %{cases: cases} do
      {:ok, result} = JudgeCalibration.calibrate([judge: @judge], cases)

      assert {:ok, json} = Codec.encode_calibration_json(result)
      assert {:ok, ^result} = Codec.decode_calibration_json(json)
    end

    test "the plain-text report shows the holdout metrics", %{cases: cases} do
      {:ok, result} = JudgeCalibration.calibrate([judge: @judge], cases)
      report = JudgeCalibration.format(result)

      assert report =~ "agreement     77.8% (7/9"
      assert report =~ "kappa         0.55 (Cohen)"
      assert report =~ "false pass    25.0% (1/4"
      assert report =~ "h10: judge_out_of_range"
    end
  end

  test "a Likert judge gets quadratic-weighted κ and false passes from its threshold" do
    install_judge()

    cases =
      [{"1", "1"}, {"2", "3"}, {"3", "3"}, {"1", "2"}, {"3", "3"}]
      |> Enum.with_index(1)
      |> Enum.map(fn {{human, judge}, i} -> judge_case("l#{i}", human, judge) end)

    assert {:ok, r} =
             JudgeCalibration.calibrate(
               [judge: @judge, scale: {:likert, 1, 3}, threshold: 0.5],
               cases
             )

    # Quadratic weights over ranks 0..2: Σw·O = 2, Σw·E = 40/5 = 8, κ = 1 − 2/8.
    assert r.kappa_kind == :quadratic_weighted
    assert_in_delta r.kappa, 0.75, 1.0e-12
    assert r.agreement.count == 3

    # Human "1" (0.0) fails at threshold 0.5; the judge's "2" (0.5) passes one.
    assert %{count: 1, n: 2} = r.false_pass
    assert r.confusion.matrix == [[1, 1, 0], [0, 0, 1], [0, 0, 2]]
  end

  describe "calibrate/3 refuses before calling the judge" do
    test "a human label outside the judge's scale" do
      JudgeStub.install([JudgeStub.verdict("pass")])
      cases = [judge_case("x", "great", "pass")]

      assert {:error, {:unknown_human_label, "x", "great"}} =
               JudgeCalibration.calibrate([judge: @judge], cases)

      refute_received {:judge_request, _, _, _}
    end

    test "evidence a judge case cannot provide, no holdout, bad judge options" do
      cases = [judge_case("x", "pass", "pass")]

      assert {:error, {:unsupported_include, [:tool_calls]}} =
               JudgeCalibration.calibrate([judge: @judge, include: [:output, :tool_calls]], cases)

      assert {:error, :no_holdout_cases} =
               JudgeCalibration.calibrate([judge: @judge], [
                 judge_case("x", "pass", "pass", "tune")
               ])

      assert {:error, "judge: judge is required" <> _} = JudgeCalibration.calibrate([], cases)
    end
  end

  describe "check/3" do
    setup do
      fingerprint = "sha256:" <> String.duplicate("ab", 32)

      result =
        Nous.Eval.Store.Conformance.calibration_fixture(fingerprint,
          kappa: 0.7,
          false_pass: %{estimate: 0.08, ci: {0.02, 0.2}, count: 2, n: 25}
        )

      %{fingerprint: fingerprint, result: result}
    end

    test "passes a matching result above the thresholds", %{fingerprint: fp, result: r} do
      assert JudgeCalibration.check(r, fp, min_kappa: 0.6, max_false_pass: 0.1) == :ok
      assert JudgeCalibration.check(r, fp, %{}) == :ok
    end

    test "fails closed", %{fingerprint: fp, result: r} do
      other = "sha256:" <> String.duplicate("cd", 32)

      assert JudgeCalibration.check(nil, fp, min_kappa: 0.6) == {:error, :missing}
      assert JudgeCalibration.check(r, other, min_kappa: 0.6) == {:error, :stale}

      assert {:error, {:below_threshold, "kappa 0.7 < 0.75"}} =
               JudgeCalibration.check(r, fp, min_kappa: 0.75)

      assert {:error, {:below_threshold, "false-pass rate 0.08 > 0.05"}} =
               JudgeCalibration.check(r, fp, max_false_pass: 0.05)

      assert {:error, {:below_threshold, _}} =
               JudgeCalibration.check(%{r | kappa: nil}, fp, min_kappa: 0.0)

      assert {:error, {:below_threshold, _}} =
               JudgeCalibration.check(%{r | false_pass: nil}, fp, max_false_pass: 1.0)
    end
  end

  describe "load/1 (nous.judge_case/1)" do
    @describetag :tmp_dir

    defp write_jsonl(dir, lines) do
      path = Path.join(dir, "cases.jsonl")
      File.write!(path, Enum.map_join(lines, "\n", &JSON.encode!/1))
      path
    end

    defp line(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => "c1",
          "input" => "Refund order 42",
          "output" => "Refunded.",
          "human_label" => "pass",
          "annotator" => "ana",
          "split" => "holdout",
          "group" => "g1",
          "provenance" => "run main-2026-10-30"
        },
        overrides
      )
    end

    test "loads cases; message inputs, structured outputs and integer labels", %{tmp_dir: dir} do
      path =
        write_jsonl(dir, [
          line(%{"schema" => "nous.judge_case/1", "reference" => "Refund issued."}),
          line(%{
            "id" => "c2",
            "group" => "g2",
            "input" => [
              %{"role" => "system", "content" => "Be terse."},
              %{"role" => "user", "content" => "Hi"}
            ],
            "output" => %{"answer" => "hello"},
            "human_label" => 4,
            "split" => "tune",
            "provenance" => %{"run" => "r1", "sample" => 0}
          })
        ])

      assert {:ok, [c1, c2]} = JudgeCalibration.load(path)
      assert %Case{id: "c1", reference: "Refund issued.", split: "holdout"} = c1
      assert [%Nous.Message{role: :system}, %Nous.Message{role: :user, content: "Hi"}] = c2.input
      assert c2.output == %{"answer" => "hello"}
      assert c2.human_label == "4"
    end

    test "is strict", %{tmp_dir: dir} do
      cases = [
        {[line(%{"verdict" => "pass"})], ~s(unknown key "verdict")},
        {[Map.delete(line(), "provenance")], ~s(missing key "provenance")},
        {[line(%{"split" => "test"})], "split must be"},
        {[line(%{"human_label" => nil})], "human_label must be"},
        {[line(%{"input" => [%{"role" => "tool", "content" => "x"}]})], "input message 1"},
        {[line(%{"schema" => "nous.case/1"})], "unsupported schema"},
        {[line(), line()], ~s(duplicate case id "c1")},
        {[line(), line(%{"id" => "c2", "split" => "tune"})], ~s(group "g1" has cases in both)}
      ]

      for {lines, message} <- cases do
        assert {:error, error} = JudgeCalibration.load(write_jsonl(dir, lines))
        assert error =~ message
      end

      assert {:error, error} = JudgeCalibration.load(Path.join(dir, "cases.yaml"))
      assert error =~ ".jsonl"
    end

    test "new/1 validates maps the same way" do
      assert {:ok, [%Case{id: "c1"}]} = JudgeCalibration.new([line()])

      assert {:error, "case 1: case \"c1\": unknown key \"extra\""} =
               JudgeCalibration.new([line(%{"extra" => 1})])
    end
  end

  test "the dataset hash ignores case order" do
    install_judge()
    a = judge_case("a", "pass", "pass")
    b = judge_case("b", "fail", "fail")

    {:ok, r1} = JudgeCalibration.calibrate([judge: @judge], [a, b])
    {:ok, r2} = JudgeCalibration.calibrate([judge: @judge], [b, a])
    {:ok, r3} = JudgeCalibration.calibrate([judge: @judge], [a, %{b | annotator: "bo"}])

    assert r1.dataset_hash == r2.dataset_hash
    refute r1.dataset_hash == r3.dataset_hash
  end

  test "a stored calibration decodes only from its own schema" do
    assert {:error, {:unsupported_schema, "nous.case/1"}} =
             Codec.decode_calibration(%{"schema" => "nous.case/1"})

    fixture =
      Nous.Eval.Store.Conformance.calibration_fixture("sha256:" <> String.duplicate("ef", 32))

    {:ok, map} = Codec.encode_calibration(fixture)

    bad_kind = put_in(map, ["errors", Access.at(0), "kind"], "exploded")
    assert {:error, {:invalid_field, _, "exploded"}} = Codec.decode_calibration(bad_kind)
  end
end
