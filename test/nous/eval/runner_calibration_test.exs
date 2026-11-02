defmodule Nous.Eval.RunnerCalibrationTest do
  # The runner looks a judge's calibration up in the run store by the judge's
  # own fingerprint id and tells the judge whether it is a gate. With
  # `require_calibration`, a stored, passing calibration lets the judge grade;
  # a missing or failing one refuses the run before any model call.
  use ExUnit.Case, async: true

  alias Nous.Eval.JudgeStub
  alias Nous.Eval.Scorers.Judge
  alias Nous.Eval.Store

  @moduletag :capture_log
  @moduletag :tmp_dir

  @judge_opts [judge: "openai:gpt-4o-2024-08-06", require_calibration: true]

  defmodule Task do
    @moduledoc false
    use Nous.Eval

    @impl true
    def agent(_context), do: Nous.new("openai:test-model", instructions: "Answer briefly.")

    @impl true
    def dataset, do: [%{id: "capital", input: "What is the capital of France?"}]

    @impl true
    def scorers,
      do: [{Judge, [judge: "openai:gpt-4o-2024-08-06", require_calibration: true]}]
  end

  setup %{tmp_dir: dir} do
    # Judge requests carry the judge's own system prompt; the agent under
    # test gets a plain answer.
    JudgeStub.install(fn %{system: system} ->
      if system =~ "Answer briefly", do: "Paris.", else: JudgeStub.verdict("pass")
    end)

    {:ok, state} = Store.File.init(root: dir)
    %{store: {Store.File, [root: dir]}, state: state}
  end

  defp fingerprint_id do
    {:ok, config} = Judge.init(@judge_opts)
    Judge.fingerprint_id(config)
  end

  test "a stored calibration that meets the requirement lets the judge grade", ctx do
    id = fingerprint_id()

    {:ok, _} =
      Store.File.put_calibration(ctx.state, id, Store.Conformance.calibration_fixture(id))

    assert {:ok, run} = Nous.Eval.run(Task, k: 1, store: ctx.store)
    assert [%{verdict: :pass, scorer_errors: []} = sample] = run.samples
    assert [%{metadata: %{calibration: "calibrated"}}] = sample.scores
  end

  test "without a stored calibration the run is refused before any model call", ctx do
    assert {:error, {:scorer_init_failed, Judge, reason}} =
             Nous.Eval.run(Task, k: 1, store: ctx.store)

    assert reason =~ "none is stored"
    refute_received {:judge_request, _, _, _}
  end

  test "a calibration below the required agreement is refused", ctx do
    id = fingerprint_id()
    weak = Store.Conformance.calibration_fixture(id, kappa: 0.3)
    {:ok, _} = Store.File.put_calibration(ctx.state, id, weak)

    assert {:error, {:scorer_init_failed, Judge, reason}} =
             Nous.Eval.run(Task, k: 1, store: ctx.store)

    assert reason =~ "requires a calibration"
    refute_received {:judge_request, _, _, _}
  end

  test "without a store the judge is told nothing was looked up and refuses to grade" do
    assert {:ok, run} = Nous.Eval.run(Task, k: 1)
    assert [%{verdict: :error, scores: []} = sample] = run.samples
    assert [%{kind: :invalid_config}] = sample.scorer_errors
  end
end
