defmodule Nous.Eval.RunnerTest do
  # async: true - the model stub is process-scoped (found through `$callers`
  # from the eval's sample processes), the budget handler is per run, and the
  # collector handler is only detached by the async: false abort test.
  use ExUnit.Case, async: true

  alias Nous.{Message, Usage}
  alias Nous.Eval.{Run, Score, Store, Trace}
  alias Nous.Eval.Scorers.{Contains, NoToolErrors, Trajectory}

  @moduletag :capture_log

  @stub_key :"$nous_runner_test_stub"

  # Answers through the script the test installed in its own process, and
  # reports every request (settings and messages) back to the test.
  defmodule Stub do
    @moduledoc false

    def request(_model, messages, settings) do
      %{pid: pid, script: script} = Nous.CallerLookup.lookup(:"$nous_runner_test_stub")
      send(pid, {:model_request, settings, messages})
      script.(messages, settings)
    end

    def request_stream(_model, _messages, _settings), do: {:error, :not_supported}
    def count_tokens(_messages), do: 10

    # A weather question gets a `get_weather` call, a tool result is turned
    # into the answer, anything else is echoed. Every response costs 10 tokens.
    def default(messages, _settings) do
      last = messages |> Enum.reject(&(&1.role == :system)) |> List.last()
      text = Message.extract_text(last) || ""

      cond do
        last.role == :tool -> reply("Forecast: " <> text)
        text =~ "weather" -> call("get_weather", %{"city" => "Paris"})
        true -> reply("hi there, you said: " <> text)
      end
    end

    def reply(text), do: {:ok, Message.assistant(text, metadata: meta("stop"))}

    def call(name, arguments) do
      call = %{id: "call_#{System.unique_integer([:positive])}", name: name, arguments: arguments}
      {:ok, Message.assistant("", tool_calls: [call], metadata: meta("tool_calls"))}
    end

    defp meta(finish_reason) do
      %{
        usage: %Usage{requests: 1, input_tokens: 7, output_tokens: 3, total_tokens: 10},
        finish_reason: finish_reason
      }
    end
  end

  defmodule Tools do
    @moduledoc false

    def get_weather(_ctx, %{"city" => city}), do: "#{city}: sunny"

    def weather do
      Nous.Tool.from_function(&__MODULE__.get_weather/2,
        name: "get_weather",
        description: "The weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        }
      )
    end

    def cases do
      [
        %{
          id: "weather",
          input: "What is the weather in Paris?",
          tags: ["tools"],
          scorers: [
            {Trajectory, expected: [%{name: "get_weather", args: %{"city" => "Paris"}}]},
            {Contains, values: ["sunny"]}
          ]
        },
        %{id: "greet", input: "say hi", tags: ["chat"], scorers: [{Contains, values: ["hi"]}]},
        %{
          id: "history",
          input: [Message.system("Be brief."), Message.user("say hi")],
          tags: ["chat"],
          scorers: [{Contains, values: ["hi"]}]
        }
      ]
    end

    def agent(model \\ "openai:gpt-4o-mini") do
      Nous.new(model, instructions: "Test agent", tools: [weather()])
    end
  end

  defmodule Basic do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: Tools.cases()

    @impl true
    def scorers, do: [NoToolErrors]

    @impl true
    def setup(_opts) do
      send(self(), :setup_called)
      {:ok, :state}
    end

    @impl true
    def teardown(:state), do: send(self(), :teardown_called)

    @impl true
    def agent(%{state: :state}), do: Tools.agent()
  end

  # Basic's samples, judged differently: "greet" must now mention a forecast.
  defmodule Strict do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset do
      Enum.map(Tools.cases(), fn
        %{id: "greet"} = c -> %{c | scorers: [{Contains, values: ["Forecast"]}]}
        c -> c
      end)
    end

    @impl true
    def scorers, do: [NoToolErrors]

    @impl true
    def agent(_ctx), do: Tools.agent()
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
    def dataset, do: Enum.take(Tools.cases(), 2)

    @impl true
    def scorers, do: [Raises]

    @impl true
    def agent(_ctx), do: Tools.agent()
  end

  defmodule BadOptions do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: [%{id: "a", input: "say hi", scorers: [{Contains, values: []}]}]

    @impl true
    def teardown(_state), do: send(self(), :teardown_called)

    @impl true
    def agent(_ctx), do: Tools.agent()
  end

  defmodule Unpriced do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: [%{id: "a", input: "say hi"}]

    @impl true
    def agent(_ctx), do: Tools.agent("openai:no-such-model-xyz")
  end

  # A model-graded scorer that reports 50 tokens of judge usage, the way the
  # LLM judge does.
  defmodule FakeJudge do
    @moduledoc false
    @behaviour Nous.Eval.Scorer

    @impl true
    def id, do: "fake_judge"
    @impl true
    def kind, do: :model_graded
    @impl true
    def init(opts), do: {:ok, Keyword.get(opts, :model, "openai:gpt-4o-mini")}
    @impl true
    def describe(model), do: %{model: model}

    @impl true
    def score(_input, model) do
      usage = %Usage{requests: 1, input_tokens: 40, output_tokens: 10, total_tokens: 50}

      {:ok,
       %Score{
         name: "fake_judge",
         value: :pass,
         passed?: true,
         metadata: %{usage: usage, model: model}
       }}
    end
  end

  defmodule Judged do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: Tools.cases()

    @impl true
    def scorers, do: [NoToolErrors, FakeJudge]

    @impl true
    def agent(_ctx), do: Tools.agent()
  end

  defmodule UnpricedJudge do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: [%{id: "a", input: "say hi"}]

    @impl true
    def scorers, do: [{FakeJudge, model: "openai:no-such-judge-xyz"}]

    @impl true
    def agent(_ctx), do: Tools.agent()
  end

  defp stub(script \\ &Stub.default/2) do
    Process.put(@stub_key, %{pid: self(), script: script})
    Nous.ModelDispatcher.put_dispatcher(Stub)
  end

  defp requests do
    receive do
      {:model_request, settings, messages} -> [{settings, messages} | requests()]
    after
      0 -> []
    end
  end

  defp sample(run, case_id, index \\ 0),
    do: Enum.find(run.samples, &(&1.case_id == case_id and &1.index == index))

  describe "run/2" do
    test "runs every case k times and records verdicts, traces, summary and fingerprint" do
      stub()

      assert {:ok, %Run{} = run} = Nous.Eval.run(Basic, k: 3, seed: 11, parallelism: 4)
      assert_received :setup_called
      assert_received :teardown_called

      assert run.status == :completed
      assert run.task == "Nous.Eval.RunnerTest.Basic"
      assert run.k == 3 and run.seed == 11
      assert :ok = Store.validate_run_id(run.id)
      assert run.id =~ ~r/\A\d{8}t\d{6}z-[0-9a-f]{8}\z/

      assert Enum.map(run.samples, &{&1.case_id, &1.index}) ==
               for(id <- ["greet", "history", "weather"], i <- 0..2, do: {id, i})

      assert Enum.all?(run.samples, &(&1.outcome == :ok and &1.verdict == :pass))

      weather = sample(run, "weather", 1)
      assert weather.iterations == 2
      assert weather.output == "Forecast: Paris: sunny"

      assert [%{name: "get_weather", arguments: %{"city" => "Paris"}, outcome: :executed}] =
               Trace.tool_calls(weather.trace)

      assert weather.usage.total_tokens == 20
      {:ok, %{total: expected_cost}} = Usage.cost(weather.usage, "openai:gpt-4o-mini")
      assert_in_delta weather.cost, expected_cost, 1.0e-12
      # Task scorers first, then the case's own.
      assert Enum.map(weather.scores, & &1.name) == ["no_tool_errors", "trajectory", "contains"]

      greet = sample(run, "greet")
      assert greet.iterations == 1
      assert greet.trace_id == greet.trace.trace_id

      # The message-list input went in as messages: its own system message
      # leads the request instead of the agent's instructions.
      assert Enum.any?(requests(), fn
               {_settings, [%Message{role: :system} = system, %Message{role: :user} | _]} ->
                 Message.extract_text(system) == "Be brief."

               _ ->
                 false
             end)

      assert run.summary["totals"]["samples"] == 9

      assert run.summary["totals"]["verdicts"] == %{
               "pass" => 9,
               "fail" => 0,
               "error" => 0,
               "none" => 0
             }

      assert run.summary["pass_rate"]["estimate"] == 1.0

      assert run.dataset_hash == run.fingerprint["dataset"]
      assert run.fingerprint["task"] == "Elixir.Nous.Eval.RunnerTest.Basic"
      assert run.fingerprint["k"] == 3
      assert run.fingerprint["seed"] == 11
      assert run.fingerprint["seed_forwarded"] == true
      assert run.fingerprint["model"] == "openai:gpt-4o-mini"
      assert run.fingerprint["tools"]["names"] == ["get_weather"]
      refute Map.has_key?(run.fingerprint["model_settings"], "seed")

      assert run.budget.spent.tokens ==
               run.samples |> Enum.map(& &1.usage.total_tokens) |> Enum.sum()

      assert run.budget.spent.tokens == 3 * 20 + 6 * 10
      assert run.budget.spent.samples == 9
      assert run.budget.exhausted == nil
    end

    test "each sample's seed reaches the model settings and is deterministic" do
      stub()

      {:ok, run} = Nous.Eval.run(Basic, k: 2, seed: 5, parallelism: 1)
      sent = for {settings, _messages} <- requests(), do: settings[:seed]
      seeds = Enum.map(run.samples, & &1.seed)

      assert length(sent) == 8
      assert Enum.all?(seeds, &(is_integer(&1) and &1 >= 0))
      assert seeds |> Enum.uniq() |> length() == 6
      assert MapSet.new(sent) == MapSet.new(seeds)

      # The weather sample's two requests carry that sample's seed.
      weather = sample(run, "weather", 0)
      assert Enum.count(sent, &(&1 == weather.seed)) == 2

      {:ok, again} = Nous.Eval.run(Basic, k: 2, seed: 5, parallelism: 3)
      assert Enum.map(again.samples, & &1.seed) == seeds

      {:ok, other} = Nous.Eval.run(Basic, k: 2, seed: 6)
      assert Enum.map(other.samples, & &1.seed) != seeds
    end

    test "without a seed no seed is sent" do
      stub()

      {:ok, run} = Nous.Eval.run(Basic, k: 1)

      assert Enum.all?(requests(), fn {settings, _} -> not Map.has_key?(settings, :seed) end)
      assert Enum.all?(run.samples, &(&1.seed == nil))
      assert run.fingerprint["seed_forwarded"] == false
    end

    test "a sample past its timeout is killed and keeps its partial trace" do
      stub(fn messages, settings ->
        if Enum.any?(messages, &(Message.extract_text(&1) == "say hi")), do: Process.sleep(10_000)
        Stub.default(messages, settings)
      end)

      {:ok, run} = Nous.Eval.run(Basic, k: 1, tags: ["chat"], timeout: 200)

      greet = sample(run, "greet")
      assert greet.outcome == :killed
      assert greet.error =~ "200 ms"
      assert greet.output == nil
      assert greet.duration_ms >= 200 and greet.duration_ms < 5_000
      # An agent that ran out of time failed; that is not a scorer error.
      assert greet.verdict == :fail

      assert [%{outcome: :incomplete}] = Trace.model_calls(greet.trace)
      assert Enum.any?(greet.trace.events, &(&1.name == [:nous, :agent, :run, :start]))
      assert run.status == :completed
    end

    test "a scorer error makes the sample :error, never a pass" do
      stub()

      {:ok, run} = Nous.Eval.run(Broken, k: 1)

      assert Enum.all?(run.samples, &(&1.verdict == :error and &1.case_score == nil))
      assert [%{scorer: "raises", kind: :raised}] = sample(run, "greet").scorer_errors
      assert run.summary["totals"]["error_rate"] == 1.0
    end

    test "zero selected cases is an error before setup" do
      stub()

      assert Nous.Eval.run(Basic, tags: ["nope"]) == {:error, :no_cases}
      refute_received :setup_called
    end

    test "invalid scorer options fail the run before any model call" do
      stub()

      assert {:error, {:scorer_init_failed, Contains, _reason}} = Nous.Eval.run(BadOptions)
      assert requests() == []
      assert_received :teardown_called
    end

    test "options are validated" do
      assert Nous.Eval.run(Basic, bogus: 1) == {:error, {:unknown_options, [:bogus]}}

      assert Nous.Eval.run(Basic, splits: ["holdout"]) ==
               {:error, {:invalid_option, :splits, ["holdout"]}}

      assert Nous.Eval.run(Basic, k: 0) == {:error, {:invalid_option, :k, 0}}

      assert Nous.Eval.run(Basic, budget: [max_cents: 1]) ==
               {:error, {:invalid_option, :budget, [:max_cents]}}
    end

    @tag :tmp_dir
    test "a run stored with :store reads back from the store", %{tmp_dir: dir} do
      stub()

      {:ok, run} = Nous.Eval.run(Basic, k: 2, seed: 1, store: {Store.File, root: dir})
      {:ok, state} = Store.File.init(root: dir)
      assert {:ok, stored} = Store.File.get_run(state, run.id)

      assert stored.status == run.status
      assert stored.fingerprint == run.fingerprint
      assert stored.budget == run.budget
      assert stored.summary == run.summary

      assert Enum.map(stored.samples, &{&1.case_id, &1.index, &1.verdict, &1.seed}) ==
               Enum.map(run.samples, &{&1.case_id, &1.index, &1.verdict, &1.seed})

      weather = sample(stored, "weather")
      assert [%{name: "get_weather"}] = Trace.tool_calls(weather.trace)
      assert length(weather.trace.events) == length(sample(run, "weather").trace.events)
    end
  end

  describe "budgets" do
    test "max_tokens cancels the running sample at its next step and runs nothing more" do
      stub()

      {:ok, run} = Nous.Eval.run(Basic, k: 1, parallelism: 1, budget: [max_tokens: 5])

      assert run.status == :budget_exhausted
      assert run.budget.exhausted == :max_tokens
      assert run.budget.limits.max_tokens == 5

      # Dataset order: "weather" ran first. Its first request spent 10 tokens;
      # the tool it asked for ran, then the next step was cancelled.
      assert [_one_request] = requests()
      weather = sample(run, "weather")
      assert weather.outcome == :budget_exhausted
      assert weather.verdict == nil and weather.scores == []
      assert [%{name: "get_weather", outcome: :executed}] = Trace.tool_calls(weather.trace)
      assert weather.usage.total_tokens == 10

      for id <- ["greet", "history"] do
        unrun = sample(run, id)
        assert unrun.outcome == :budget_exhausted and unrun.verdict == nil
        assert unrun.trace == nil
        assert unrun.error =~ "max_tokens"
      end

      assert run.budget.spent.tokens == 10
      assert run.summary["budget"]["exhausted"] == true
      assert run.summary["totals"]["verdicts"]["none"] == 3
    end

    test "max_tokens keeps the samples that finished before the limit" do
      stub()

      {:ok, run} = Nous.Eval.run(Basic, k: 1, parallelism: 1, budget: [max_tokens: 25])

      assert run.status == :budget_exhausted
      assert sample(run, "weather").verdict == :pass
      assert run.samples |> Enum.map(& &1.outcome) |> Enum.count(&(&1 == :budget_exhausted)) == 2
      assert run.budget.spent.tokens == 30
    end

    test "max_samples admits exactly that many samples, even in parallel" do
      stub()

      {:ok, run} = Nous.Eval.run(Basic, k: 2, parallelism: 6, budget: [max_samples: 3])

      outcomes = Enum.frequencies_by(run.samples, & &1.outcome)
      assert outcomes == %{ok: 3, budget_exhausted: 3}
      assert run.status == :budget_exhausted
      assert run.budget.exhausted == :max_samples
      assert run.budget.spent.samples == 3
    end

    test "an unknown price refuses a cost budget before any model request" do
      stub()

      assert Nous.Eval.run(Unpriced, budget: [max_cost: 1.0]) ==
               {:error, {:unknown_price, "openai:no-such-model-xyz"}}

      assert Nous.Eval.run(UnpricedJudge, budget: [max_cost: 1.0]) ==
               {:error, {:unknown_price, "openai:no-such-judge-xyz"}}

      assert requests() == []

      # Without a cost budget the run goes ahead; the cost is unknown.
      {:ok, run} = Nous.Eval.run(Unpriced, k: 1)
      assert [%{outcome: :ok, cost: nil}] = run.samples
      assert run.budget.spent.cost == nil
      assert run.budget.spent.unpriced_requests == 1
    end

    test "model-graded scorer usage is charged to the budget" do
      stub()

      {:ok, run} = Nous.Eval.run(Judged, k: 1, budget: [max_tokens: 10_000])

      assert run.status == :completed
      assert run.budget.spent.tokens == 20 + 10 + 10 + 3 * 50
    end
  end

  describe "rescore/3" do
    test "re-scores stored traces with the current scorers without calling the model" do
      stub()
      {:ok, run} = Nous.Eval.run(Basic, k: 2, seed: 3)
      _ = requests()

      assert {:ok, rescored} = Nous.Eval.rescore(run, Strict)
      assert requests() == []

      assert rescored.id != run.id
      assert :ok = Store.validate_run_id(rescored.id)
      assert rescored.metadata.rescored_from == run.id
      assert rescored.task == "Nous.Eval.RunnerTest.Strict"

      # Same agent configuration and traces, different scorers and data.
      assert rescored.fingerprint["model"] == run.fingerprint["model"]
      assert rescored.fingerprint["tools"] == run.fingerprint["tools"]
      assert rescored.fingerprint["seed"] == run.fingerprint["seed"]
      assert rescored.fingerprint["dataset"] == rescored.dataset_hash
      assert rescored.dataset_hash != run.dataset_hash
      assert rescored.fingerprint["id"] != run.fingerprint["id"]

      assert Enum.map(rescored.samples, & &1.output) == Enum.map(run.samples, & &1.output)
      assert Enum.map(rescored.samples, & &1.trace) == Enum.map(run.samples, & &1.trace)

      verdicts = Map.new(rescored.samples, &{{&1.case_id, &1.index}, &1.verdict})
      assert verdicts[{"greet", 0}] == :fail and verdicts[{"greet", 1}] == :fail
      assert verdicts[{"weather", 0}] == :pass and verdicts[{"history", 1}] == :pass
      assert rescored.summary["totals"]["verdicts"]["fail"] == 2
    end

    test "with the same scorers the verdicts and fingerprint scorers are unchanged" do
      stub()
      {:ok, run} = Nous.Eval.run(Basic, k: 1)

      {:ok, rescored} = Nous.Eval.rescore(run, Basic)

      assert Enum.map(rescored.samples, & &1.verdict) == Enum.map(run.samples, & &1.verdict)
      assert rescored.fingerprint == run.fingerprint
      assert rescored.dataset_hash == run.dataset_hash
    end

    test "a token budget starves model-graded scorers once exhausted" do
      stub()
      {:ok, run} = Nous.Eval.run(Basic, k: 1)

      {:ok, rescored} =
        Nous.Eval.rescore(run, Judged, parallelism: 1, budget: [max_tokens: 60])

      # Sorted: greet, history, weather. Two judge calls spend 100 >= 60.
      assert sample(rescored, "greet").verdict == :pass
      assert sample(rescored, "history").verdict == :pass

      weather = sample(rescored, "weather")
      assert weather.verdict == :error and weather.case_score == nil
      assert [%{scorer: "fake_judge", kind: :budget_exhausted}] = weather.scorer_errors
      # The deterministic scorers still ran.
      assert "trajectory" in Enum.map(weather.scores, & &1.name)

      assert rescored.status == :budget_exhausted
      assert rescored.budget.spent.tokens == 100
      assert rescored.budget.exhausted == :max_tokens
    end

    test "a case missing from the task is an error" do
      stub()
      {:ok, run} = Nous.Eval.run(Basic, k: 1)

      assert Nous.Eval.rescore(run, Broken) == {:error, {:missing_cases, ["history"]}}

      assert Nous.Eval.rescore(run, Basic, budget: [max_samples: 1]) ==
               {:error, {:invalid_option, :budget, [max_samples: 1]}}
    end
  end
end
