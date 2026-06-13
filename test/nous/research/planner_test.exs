defmodule Nous.Research.PlannerTest do
  # async: false — swaps the global :model_dispatcher.
  use ExUnit.Case, async: false

  alias Nous.Research.Planner
  alias Nous.Usage

  # Scripted dispatcher: returns whatever text is stashed in :persistent_term
  # for this test, so we can drive Planner's LLM-output parsing deterministically.
  defmodule ScriptedDispatcher do
    @key {__MODULE__, :output}

    def set_output(text), do: :persistent_term.put(@key, text)
    def set_error(reason), do: :persistent_term.put(@key, {:error, reason})

    def request(_model, _messages, _settings) do
      case :persistent_term.get(@key, "") do
        {:error, reason} ->
          {:error, reason}

        text ->
          {:ok,
           Nous.Message.from_legacy(%{
             parts: [{:text, text}],
             usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
             model_name: "test-model",
             timestamp: DateTime.utc_now()
           })}
      end
    end

    def request_stream(_m, _ms, _s), do: {:ok, []}
    def count_tokens(_), do: 0
  end

  setup do
    Application.put_env(:nous, :model_dispatcher, ScriptedDispatcher)
    on_exit(fn -> Application.delete_env(:nous, :model_dispatcher) end)
    :ok
  end

  describe "plan/2 parsing" do
    test "parses a numbered list into parallel steps with no dependencies" do
      ScriptedDispatcher.set_output("""
      1. What is the population of France?
      2. What is the GDP of France?
      3. What languages are spoken in France?
      """)

      assert {:ok, plan} = Planner.plan("Tell me about France", strategy: :parallel)
      assert plan.query == "Tell me about France"
      assert plan.strategy == :parallel
      assert plan.estimated_searches == 3
      assert length(plan.steps) == 3
      assert Enum.all?(plan.steps, &(&1.depends_on == []))
      assert hd(plan.steps).query == "What is the population of France?"
    end

    test "sequential strategy chains each step onto the previous one" do
      ScriptedDispatcher.set_output("""
      1. First question
      2. Second question
      3. Third question
      """)

      assert {:ok, plan} = Planner.plan("q", strategy: :sequential)
      assert Enum.map(plan.steps, & &1.depends_on) == [[], [0], [1]]
    end

    test "accepts both '1.' and '1)' numbering" do
      ScriptedDispatcher.set_output("1) alpha\n2) beta")
      assert {:ok, plan} = Planner.plan("q")
      assert Enum.map(plan.steps, & &1.query) == ["alpha", "beta"]
    end

    test "falls back to a single step when the output has no numbered list" do
      ScriptedDispatcher.set_output("I cannot break this down.")
      assert {:ok, plan} = Planner.plan("q")
      assert [%{query: "I cannot break this down.", depends_on: []}] = plan.steps
    end
  end

  describe "plan/2 LLM-failure fallback" do
    test "returns a single-step plan using the original query when the LLM errors" do
      ScriptedDispatcher.set_error(:provider_down)

      assert {:ok, plan} = Planner.plan("my original query")
      assert plan.estimated_searches == 1
      assert [%{query: "my original query", strategy: :parallel, depends_on: []}] = plan.steps
    end
  end
end
