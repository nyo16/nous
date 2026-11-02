defmodule NousTest.ThresholdWarningTools do
  @moduledoc false
  # Outside the `Nous` namespace: a profile refuses to address tools whose
  # function is defined under `Nous` (built-in tools).
  def lookup(_ctx, _args), do: "order 42 shipped"
end

defmodule Nous.Eval.OptimizerThresholdWarningTest do
  # async: true - the model stub is process-scoped (found through `$callers`).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nous.{Message, Usage}
  alias Nous.Eval.Optimizer
  alias Nous.Eval.Scorer.Spec

  @moduletag :capture_log

  # The agent always answers; the reflector proposes one fixed description.
  defmodule Model do
    @moduledoc false

    def request(_model, messages, _settings) do
      system =
        messages
        |> Enum.filter(&(&1.role == :system))
        |> Enum.map_join("\n", &Message.extract_text/1)

      cond do
        system =~ "You improve the text" ->
          {:ok,
           text(
             JSON.encode!(%{
               "updates" => [%{"component" => "tool:lookup", "text" => "Look orders up."}],
               "rationale" => "Clearer."
             })
           )}

        system =~ "You write the text" ->
          {:ok, text(JSON.encode!(%{"candidates" => [%{"tool:lookup" => "Look orders up."}]}))}

        true ->
          {:ok, text("Order found.")}
      end
    end

    def request_stream(_model, _messages, _settings), do: {:error, :not_supported}
    def count_tokens(_messages), do: 0

    defp text(content) do
      usage = %Usage{requests: 1, input_tokens: 10, output_tokens: 5, total_tokens: 15}
      Message.assistant(content, metadata: %{usage: usage, finish_reason: "stop"})
    end
  end

  # Soft-scored cases without a threshold: every evaluation's run would warn.
  defmodule SoftTask do
    @moduledoc false
    use Nous.Eval

    @impl true
    def agent(_context) do
      Nous.new("openai:test-model",
        instructions: "Answer order questions.",
        tools: [
          Nous.Tool.from_function(&NousTest.ThresholdWarningTools.lookup/2,
            name: "lookup",
            description: "Looks things up.",
            parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
          )
        ]
      )
    end

    @impl true
    def dataset do
      for {split, n} <- [{"train", 3}, {"val", 3}, {"test", 3}], i <- 1..n do
        %{id: "thrwarn-#{split}-#{i}", input: "Where is order #{i}?", split: split}
      end
    end

    @impl true
    def scorers,
      do: [%Spec{module: Nous.Eval.Scorers.Contains, opts: [values: ["found"]], required: false}]
  end

  test "an optimization logs the implicit-threshold warning once, not per evaluation" do
    Nous.ModelDispatcher.put_dispatcher(Model)

    log =
      capture_log(fn ->
        assert {:ok, _result} =
                 Optimizer.run(SoftTask,
                   reflector: "openai:reflector-model",
                   components: ["tool:lookup"],
                   budget: [max_metric_calls: 200],
                   k: 1,
                   max_steps: 2,
                   minibatch_size: 2,
                   seed: 7
                 )
      end)

    # One warning naming this task's cases, from the optimization itself, not
    # one per evaluation run (other async tests may log their own).
    assert length(String.split(log, "thrwarn-train-1,")) == 2
    assert log =~ "default weighted mean of 0.5"
  end
end
