defmodule Mix.Tasks.Nous.EvalTest do
  # async: false - swaps the global Mix shell to capture task output.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Nous.Eval, as: EvalTask
  alias Nous.{Message, Usage}
  alias Nous.Eval.Scorers.Contains
  alias Nous.Eval.Store

  @moduletag :capture_log
  @moduletag :tmp_dir

  @mode_key :"$nous_eval_task_test_mode"

  # Answers "good answer" or "bad answer" depending on the mode the test set
  # in its process, and reports each request to the test.
  defmodule Stub do
    @moduledoc false

    def request(_model, _messages, _settings) do
      %{pid: pid, mode: mode} = Nous.CallerLookup.lookup(:"$nous_eval_task_test_mode")
      send(pid, :model_request)
      text = if mode == :good, do: "good answer", else: "bad answer"
      usage = %Usage{requests: 1, input_tokens: 7, output_tokens: 3, total_tokens: 10}
      {:ok, Message.assistant(text, metadata: %{usage: usage, finish_reason: "stop"})}
    end

    def request_stream(_model, _messages, _settings), do: {:error, :not_supported}
    def count_tokens(_messages), do: 10
  end

  defmodule Good do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset do
      for id <- ~w(a b c d e) do
        %{id: id, input: "question #{id}", tags: ["t-#{id}"], split: "test"}
      end
    end

    @impl true
    def scorers, do: [{Contains, values: ["good"]}]

    @impl true
    def agent(_ctx), do: Nous.new("openai:gpt-4o-mini")
  end

  # Good's cases, also requiring the word "answer" (rescore target).
  defmodule Wordy do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: Good.dataset()

    @impl true
    def scorers, do: [{Contains, values: ["good"]}, {Contains, values: ["answer"]}]

    @impl true
    def agent(_ctx), do: Nous.new("openai:gpt-4o-mini")
  end

  defmodule Raises do
    @moduledoc false
    @behaviour Nous.Eval.Scorer

    @impl true
    def id, do: "raises"
    @impl true
    def init(_opts), do: {:ok, nil}
    @impl true
    def score(_input, _config), do: raise("scorer bug")
  end

  defmodule Broken do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: Good.dataset()

    @impl true
    def scorers, do: [Raises]

    @impl true
    def agent(_ctx), do: Nous.new("openai:gpt-4o-mini")
  end

  defmodule Unpriced do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: Good.dataset()

    @impl true
    def agent(_ctx), do: Nous.new("openai:no-such-model-xyz")
  end

  setup %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Nous.ModelDispatcher.put_dispatcher(Stub)
    mode(:good)
    %{store: "file:" <> dir, dir: dir}
  end

  defp mode(mode), do: Process.put(@mode_key, %{pid: self(), mode: mode})

  # Runs a task; returns its exit status and everything it printed.
  defp run_task(module, args) do
    code =
      try do
        module.run(args)
        0
      catch
        :exit, {:shutdown, code} -> code
      end

    {code, output()}
  end

  defp output do
    receive do
      {:mix_shell, _kind, [text]} -> text <> "\n" <> output()
    after
      0 -> ""
    end
  end

  defp run_id(output) do
    [_, id] = Regex.run(~r/Stored run (\S+) in/, output)
    id
  end

  defp model_requests do
    receive do
      :model_request -> 1 + model_requests()
    after
      0 -> 0
    end
  end

  defp task_args(module, store, extra),
    do: ["--task", inspect(module), "--k", "2", "--seed", "1", "--store", store | extra]

  describe "mix nous.eval" do
    test "baseline flow: pass, regression, pass", %{store: store} do
      {code, out} = run_task(EvalTask, task_args(Good, store, ["--set-baseline", "main"]))
      assert code == 0
      assert out =~ "Eval run"
      assert out =~ "Exit status 0 (pass)"
      baseline_id = run_id(out)
      assert out =~ "Baseline main -> #{baseline_id}"

      mode(:degraded)
      {code, out} = run_task(EvalTask, task_args(Good, store, ["--baseline", "main"]))
      assert code == 1
      assert out =~ "Exit status 1 (regression)"
      # The per-case diff names the broken cases.
      assert out =~ ~r/broken/i
      assert out =~ "a, b, c, d, e"

      # A failing run never moves the baseline.
      {code, out} =
        run_task(
          EvalTask,
          task_args(Good, store, ["--baseline", "main", "--set-baseline", "main"])
        )

      assert code == 1
      assert out =~ "Baseline main not updated"

      mode(:good)
      {code, out} = run_task(EvalTask, task_args(Good, store, ["--baseline", "main"]))
      assert code == 0
      assert out =~ "Exit status 0 (pass)"

      {:ok, state} = Store.File.init(root: String.trim_leading(store, "file:"))
      assert {:ok, %{run_id: ^baseline_id}} = Store.File.get_baseline(state, "main")
    end

    test "scorer errors are an operational error", %{store: store} do
      {code, out} = run_task(EvalTask, task_args(Broken, store, []))

      assert code == 2
      assert out =~ "scorer error rate 100.0% exceeds --max-error-rate 0.0%"
      # 100% errors exceed even a 99% tolerance.
      {code, _out} = run_task(EvalTask, task_args(Broken, store, ["--max-error-rate", "0.99"]))
      assert code == 2
    end

    test "zero selected cases exit 2", %{store: store} do
      {code, out} = run_task(EvalTask, task_args(Good, store, ["--tag", "nope"]))

      assert code == 2
      assert out =~ "no cases to run"
      assert model_requests() == 0
    end

    test "a budget refusal exits 2 before any model call", %{store: store} do
      {code, out} = run_task(EvalTask, task_args(Unpriced, store, ["--budget-cost", "1"]))

      assert code == 2
      assert out =~ "no known price for openai:no-such-model-xyz"
      assert model_requests() == 0
    end

    test "an exhausted budget exits 2", %{store: store} do
      {code, out} =
        run_task(
          EvalTask,
          task_args(Good, store, ["--budget-samples", "3", "--parallelism", "1"])
        )

      assert code == 2
      assert out =~ "the run budget was exhausted (max_samples); 7 samples did not run"
      assert model_requests() == 3
    end

    test "--split and --tag select cases", %{store: store} do
      {code, out} =
        run_task(
          EvalTask,
          task_args(Good, store, ["--split", "test", "--tag", "t-a,t-b", "--tag", "t-c"])
        )

      assert code == 0
      assert out =~ "Cases 3, samples 6"
    end

    test "--format and --output write the report", %{store: store, dir: dir} do
      path = Path.join(dir, "report.json")

      {code, out} =
        run_task(EvalTask, task_args(Good, store, ["--format", "json", "--output", path]))

      assert code == 0
      assert out =~ "Wrote the report to #{path}"

      assert {:ok, %{"schema" => "nous.eval.summary/1", "run_id" => id}} =
               JSON.decode(File.read!(path))

      assert id == run_id(out)
    end

    test "command-line strings never become atoms", %{store: store} do
      suffix = Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
      split = "split" <> suffix
      tag = "tag" <> suffix
      format = "format" <> suffix
      switch = "switch" <> suffix
      module = "Mod" <> suffix
      metric = "metric" <> suffix

      for args <- [
            task_args(Good, store, ["--split", split]),
            task_args(Good, store, ["--tag", tag]),
            task_args(Good, store, ["--format", format]),
            task_args(Good, store, ["--gate", metric]),
            task_args(Good, store, ["--" <> switch, "1"]),
            ["--task", module, "--store", store]
          ] do
        assert {2, _out} = run_task(EvalTask, args)
      end

      for name <- [split, tag, format, switch, metric, module, "Elixir." <> module] do
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end

    test "bad flags exit 2", %{store: store} do
      assert {2, out} = run_task(EvalTask, ["--store", store])
      assert out =~ "missing --task"

      assert {2, out} = run_task(EvalTask, task_args(Good, store, ["--margin", "1.5"]))
      assert out =~ "--margin must be in [0, 1)"

      assert {2, out} = run_task(EvalTask, task_args(Good, store, ["--baseline", "never-set"]))
      assert out =~ "baseline \"never-set\" is not set"
      assert model_requests() == 0

      assert {2, out} = run_task(EvalTask, task_args(Good, "redis:localhost", []))
      assert out =~ "unknown store kind \"redis\""
    end
  end

  describe "mix nous.eval.compare" do
    test "compares two stored runs", %{store: store} do
      {0, out} = run_task(EvalTask, task_args(Good, store, ["--set-baseline", "main"]))
      good = run_id(out)
      mode(:degraded)
      {0, out} = run_task(EvalTask, task_args(Good, store, []))
      bad = run_id(out)

      assert {1, out} =
               run_task(Mix.Tasks.Nous.Eval.Compare, ["baseline:main", bad, "--store", store])

      assert out =~ "Exit status 1 (regression)"

      assert {0, _out} = run_task(Mix.Tasks.Nous.Eval.Compare, [good, good, "--store", store])

      assert {2, out} = run_task(Mix.Tasks.Nous.Eval.Compare, [good, "--store", store])
      assert out =~ "expected two runs"

      assert {2, out} =
               run_task(Mix.Tasks.Nous.Eval.Compare, [good, "nosuchrun", "--store", store])

      assert out =~ "no run nosuchrun"
    end
  end

  describe "mix nous.eval.rescore" do
    test "stores a re-scored run without calling the model", %{store: store} do
      mode(:degraded)
      {0, out} = run_task(EvalTask, task_args(Good, store, []))
      source = run_id(out)
      assert model_requests() == 10

      {code, out} =
        run_task(Mix.Tasks.Nous.Eval.Rescore, [source, "--task", inspect(Wordy), "--store", store])

      assert code == 0
      assert model_requests() == 0
      [_, new_id] = Regex.run(~r/Re-scored #{source} as (\S+)/, out)

      {:ok, state} = Store.File.init(root: String.trim_leading(store, "file:"))
      {:ok, rescored} = Store.File.get_run(state, new_id)
      assert rescored.metadata.rescored_from == source
      assert rescored.task == inspect(Wordy)
      assert Enum.all?(rescored.samples, &(length(&1.scores) == 2))
    end

    test "defaults to the run's own task", %{store: store} do
      {0, out} = run_task(EvalTask, task_args(Good, store, ["--set-baseline", "main"]))
      source = run_id(out)

      assert {0, out} = run_task(Mix.Tasks.Nous.Eval.Rescore, ["baseline:main", "--store", store])
      assert out =~ "Re-scored #{source} as "
    end
  end

  describe "mix nous.eval.baseline" do
    test "set, show and history", %{store: store} do
      {0, out} = run_task(EvalTask, task_args(Good, store, []))
      first = run_id(out)
      {0, out} = run_task(EvalTask, task_args(Good, store, []))
      second = run_id(out)

      task = Mix.Tasks.Nous.Eval.Baseline
      assert {0, _} = run_task(task, ["set", first, "main", "--store", store])
      assert {0, out} = run_task(task, ["set", second, "main", "--store", store])
      assert out =~ "Baseline main -> #{second}"

      assert {0, out} = run_task(task, ["show", "main", "--store", store])
      assert out =~ "main -> #{second}"
      assert out =~ "pass rate: 100.0%"

      assert {0, out} = run_task(task, ["history", "main", "--store", store])
      assert [line_second, line_first] = out |> String.split("\n", trim: true)
      assert line_second =~ second and line_first =~ first

      assert {2, out} = run_task(task, ["set", "nosuchrun", "main", "--store", store])
      assert out =~ "no run nosuchrun"
      assert {2, out} = run_task(task, ["show", "Bad Label", "--store", store])
      assert out =~ "invalid LABEL"
      assert {2, out} = run_task(task, ["drop", "main", "--store", store])
      assert out =~ "expected: set RUN LABEL"
    end
  end
end
