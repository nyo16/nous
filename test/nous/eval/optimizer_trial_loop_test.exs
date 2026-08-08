defmodule Nous.Eval.OptimizerTrialLoopTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Nous.Eval.Optimizer
  alias Nous.Eval.Suite

  # `trial_loop/3`, `run_trials/5`, `attempt_trial/5` and `timed_out?/1` are
  # the loop the three optimizer strategies used to each carry a copy of.
  #
  # A suite with no test cases fails `Suite.validate/1`, so `Runner.run/2`
  # returns `{:error, _}` before an agent or a model is ever resolved. That
  # keeps these tests offline while exercising the real `Optimizer.run_trial/4`
  # and the failed-trial fallback all three strategies rely on.
  #
  # The successful branch of `attempt_trial/5` — the one that consults
  # `:early_stop` — cannot be reached from a test today: `run_trial/4`'s
  # `extract_all_metrics/1` calls `get_in/2` on a `%Nous.Eval.SuiteResult{}`,
  # which implements no Access behaviour, so every successful `Runner.run/2`
  # raises `UndefinedFunctionError`. That defect predates this loop and is not
  # this module's to fix; the early-stop path was verified against a stubbed
  # runner instead. Delete this paragraph and add the coverage once
  # `run_trial/4` can succeed.
  defp suite, do: Suite.new(name: "trial-loop")

  defp loop(opts \\ [], total \\ 3) do
    Optimizer.trial_loop(
      Keyword.put_new(opts, :verbose, false),
      total,
      System.monotonic_time(:millisecond)
    )
  end

  describe "trial_loop/3" do
    test "defaults the budget the strategies used to each hardcode" do
      assert Optimizer.trial_loop([], 5, 123) == %{
               verbose: true,
               index: 0,
               total: 5,
               start_time: 123,
               timeout: 3_600_000,
               early_stop: nil
             }
    end

    test "takes verbose, timeout and early_stop from the strategy's opts" do
      loop = Optimizer.trial_loop([verbose: false, timeout: 50, early_stop: 0.75], 2, 0)

      assert loop.verbose == false
      assert loop.timeout == 50
      assert loop.early_stop == 0.75
    end

    test "keeps the caller's start_time so the budget covers config generation" do
      before = System.monotonic_time(:millisecond) - 10_000

      assert Optimizer.trial_loop([], 1, before).start_time == before
    end
  end

  describe "timed_out?/1" do
    test "is false while the budget holds" do
      refute Optimizer.timed_out?(
               Optimizer.trial_loop([timeout: 60_000], 1, System.monotonic_time(:millisecond))
             )
    end

    test "is true once elapsed exceeds the budget" do
      started = System.monotonic_time(:millisecond) - 5

      assert Optimizer.timed_out?(Optimizer.trial_loop([timeout: 0], 1, started))
    end
  end

  describe "run_trials/5" do
    test "returns the trials in the order they ran" do
      configs = [%{a: 1}, %{a: 2}, %{a: 3}]

      {trials, count} = Optimizer.run_trials(suite(), configs, :score, [], loop())

      # Chronological, not reversed: `Nous.Eval.Optimizer.Strategies.Bayesian`
      # used to return its initial phase backwards because it skipped the
      # `Enum.reverse/1` its two sibling strategies remembered.
      assert Enum.map(trials, & &1.config) == configs
      assert count == 3
    end

    test "produces one trial per configuration even when every evaluation fails" do
      {trials, count} = Optimizer.run_trials(suite(), [%{a: 1}, %{a: 2}], :score, [], loop())

      assert length(trials) == 2
      assert count == 2
    end

    test "a failed evaluation becomes a zero-scored trial carrying the reason" do
      {[trial], 1} = Optimizer.run_trials(suite(), [%{a: 1}], :score, [], loop([], 1))

      assert trial.config == %{a: 1}
      assert trial.score == 0.0
      assert trial.duration_ms == 0
      assert {:validation_error, _} = trial.metrics.error
    end

    test "an exhausted budget halts before any configuration is evaluated" do
      spent =
        Optimizer.trial_loop(
          [verbose: false, timeout: 0],
          3,
          System.monotonic_time(:millisecond) - 5
        )

      assert {[], 0} = Optimizer.run_trials(suite(), [%{a: 1}, %{a: 2}], :score, [], spent)
    end

    test "an empty configuration list runs nothing" do
      assert {[], 0} = Optimizer.run_trials(suite(), [], :score, [], loop([], 0))
    end

    test "stays silent when the strategy asked for quiet" do
      assert capture_io(fn ->
               Optimizer.run_trials(suite(), [%{a: 1}], :score, [], loop([verbose: false], 1))
             end) == ""
    end

    test "reports progress against the budget, not the configuration count" do
      # Bayesian's initial phase hands over fewer configs than the total
      # budget; the progress line must still count against the budget.
      loop = Optimizer.trial_loop([verbose: true], 7, System.monotonic_time(:millisecond))

      output =
        capture_io(fn ->
          Optimizer.run_trials(suite(), [%{a: 1}, %{a: 2}], :score, [], loop)
        end)

      assert output =~ "Trial 1/7"
      assert output =~ "Trial 2/7"
      assert output =~ "Trial 1 failed:"
      assert output =~ "Trial 2 failed:"
    end
  end

  describe "attempt_trial/5" do
    test "reports the trial at the loop's own index" do
      loop = %{
        Optimizer.trial_loop([verbose: true], 9, System.monotonic_time(:millisecond))
        | index: 4
      }

      output = capture_io(fn -> Optimizer.attempt_trial(suite(), %{a: 1}, :score, [], loop) end)

      assert output =~ "Trial 5/9"
    end

    test "keeps going after a failed evaluation rather than ending the search" do
      assert {:cont, trial} = Optimizer.attempt_trial(suite(), %{a: 1}, :score, [], loop([], 1))
      assert trial.score == 0.0
    end

    test "never early-stops on a failed evaluation, whatever the threshold" do
      # A failed trial scores 0.0. Treating that as "reached the target" would
      # abandon the search on the first broken configuration.
      loop = loop([early_stop: 0.0], 1)

      assert {:cont, _trial} = Optimizer.attempt_trial(suite(), %{a: 1}, :score, [], loop)
    end
  end
end
