defmodule Nous.Eval.TaskTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Case, Dataset, Task}
  alias Nous.Eval.Scorer.Spec

  defmodule StubScorer do
    @behaviour Nous.Eval.Scorer

    @impl true
    def id, do: "stub"
    @impl true
    def init(opts), do: {:ok, opts}
    @impl true
    def score(_input, _config), do: {:skip, "stub"}
  end

  defmodule MinimalTask do
    use Nous.Eval

    @impl true
    def dataset, do: [[id: "a", input: "hello"]]

    @impl true
    def agent(%{deps: deps}), do: Nous.new("openai:gpt-4o-mini", instructions: inspect(deps))
  end

  defmodule FullTask do
    use Nous.Eval

    @impl true
    def dataset, do: "test/fixtures/eval/datasets/plain.jsonl"

    @impl true
    def scorers, do: [StubScorer, {StubScorer, threshold: 3, required: false, weight: 2}]

    @impl true
    def setup(opts), do: {:ok, %{token: Keyword.fetch!(opts, :token)}}

    @impl true
    def deps(%{token: token}), do: %{token: token}

    @impl true
    def teardown(%{token: token}) do
      send(self(), {:teardown, token})
      :ok
    end

    @impl true
    def agent(%{case: %Case{id: id}, deps: %{token: token}, state: state, sample: sample}) do
      Nous.new("openai:gpt-4o-mini", instructions: "#{id}/#{token}/#{state.token}/#{sample}")
    end
  end

  defmodule NotATask do
    def agent(_), do: nil
    def dataset, do: []
  end

  defmodule RaisingDataset do
    use Nous.Eval

    @impl true
    def dataset, do: raise("no data today")

    @impl true
    def agent(_), do: Nous.new("openai:gpt-4o-mini")
  end

  defmodule InvalidCases do
    use Nous.Eval

    @impl true
    def dataset, do: [%{id: "a", input: "x"}, %{id: "a", input: "y"}]

    @impl true
    def agent(_), do: Nous.new("openai:gpt-4o-mini")
  end

  defmodule BadScorers do
    use Nous.Eval

    @impl true
    def dataset, do: [[id: "a", input: "x"]]

    @impl true
    def scorers, do: [String]

    @impl true
    def agent(_), do: Nous.new("openai:gpt-4o-mini")
  end

  defmodule BadReturns do
    use Nous.Eval

    @impl true
    def dataset, do: [[id: "a", input: "x"]]

    @impl true
    def setup(_opts), do: :ok

    @impl true
    def deps(_state), do: [:not, :a, :map]

    @impl true
    def agent(_), do: %{model: "openai:gpt-4o-mini"}
  end

  defp context(task, state, deps) do
    %{case: hd(task.dataset.cases), sample: 0, seed: 7, deps: deps, state: state}
  end

  test "a task with only agent/1 and dataset/0 runs end to end on the defaults" do
    assert {:ok, %Task{module: MinimalTask, scorers: []} = task} = Task.load(MinimalTask)

    assert %Dataset{name: "Nous.Eval.TaskTest.MinimalTask", cases: [%Case{id: "a"}]} =
             task.dataset

    assert {:ok, nil} = Task.setup(task, [])
    assert {:ok, %{}} = Task.deps(task, nil)
    assert {:ok, agent} = Task.agent(task, context(task, nil, %{}))
    assert agent.instructions == "%{}"
    assert :ok = Task.teardown(task, nil)
  end

  test "setup state and deps reach agent/1; teardown gets the state" do
    assert {:ok, task} = Task.load(FullTask)
    assert Enum.map(task.dataset.cases, & &1.id) == ["a", "b"]
    assert task.dataset.source == "test/fixtures/eval/datasets/plain.jsonl"

    assert task.scorers == [
             %Spec{module: StubScorer},
             %Spec{module: StubScorer, opts: [threshold: 3], required: false, weight: 2}
           ]

    assert {:ok, state} = Task.setup(task, token: "t1")
    assert {:ok, deps} = Task.deps(task, state)
    assert {:ok, agent} = Task.agent(task, %{context(task, state, deps) | sample: 2})
    assert agent.instructions == "a/t1/t1/2"

    assert :ok = Task.teardown(task, state)
    assert_received {:teardown, "t1"}
  end

  test "load/2 passes dataset options through" do
    assert {:ok, task} = Task.load(FullTask, split_ratios: [test: 1.0])
    assert Enum.all?(task.dataset.cases, &(&1.split == "test"))
  end

  test "load/2 rejects modules that are not tasks" do
    assert {:error, message} = Task.load(NotATask)
    assert message =~ "is not a Nous.Eval task"

    assert {:error, message} = Task.load(Nous.Eval.TaskTest.DoesNotExist)
    assert message =~ "is not a loaded module"

    assert {:error, message} = Task.load("MinimalTask")
    assert message =~ "a task is a module"
  end

  test "load/2 fails closed on a broken dataset or scorer list" do
    assert {:error, message} = Task.load(RaisingDataset)
    assert message =~ "dataset/0 raised: no data today"

    assert {:error, message} = Task.load(InvalidCases)
    assert message =~ "duplicate case ids"

    assert {:error, message} = Task.load(BadScorers)
    assert message =~ "BadScorers.scorers/0: String is not a Nous.Eval.Scorer"
  end

  test "callbacks with wrong-shaped returns are errors" do
    {:ok, task} = Task.load(BadReturns)

    assert {:error, message} = Task.setup(task, [])
    assert message =~ "setup/1 must return {:ok, state} | {:error, reason}, got :ok"

    assert {:error, message} = Task.deps(task, nil)
    assert message =~ "deps/1 must return a map"

    assert {:error, message} = Task.agent(task, context(task, nil, %{}))
    assert message =~ "agent/1 must return a %Nous.Agent{}"

    assert {:error, message} = Task.agent(task, %{case: hd(task.dataset.cases)})
    assert message =~ "agent context is missing :sample, :seed, :deps, :state"
  end
end
