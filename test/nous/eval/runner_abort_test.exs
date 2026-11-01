defmodule Nous.Eval.RunnerAbortTest do
  # async: false - detaches the trace collector's global telemetry handler.
  use ExUnit.Case, async: false

  alias Nous.{Message, Usage}
  alias Nous.Eval.Trace.Collector

  @moduletag :capture_log

  defmodule Stub do
    @moduledoc false

    def request(_model, _messages, _settings) do
      usage = %Usage{requests: 1, input_tokens: 7, output_tokens: 3, total_tokens: 10}
      {:ok, Message.assistant("hi", metadata: %{usage: usage, finish_reason: "stop"})}
    end

    def request_stream(_model, _messages, _settings), do: {:error, :not_supported}
    def count_tokens(_messages), do: 10
  end

  # Loses the collector's handler while building the agent of sample 1, as a
  # raising handler elsewhere in the app would.
  defmodule Detaching do
    @moduledoc false
    use Nous.Eval

    @impl true
    def dataset, do: [%{id: "a", input: "say hi"}]

    @impl true
    def agent(%{sample: index}) do
      if index == 1, do: :telemetry.detach(Collector.handler_id())
      Nous.new("openai:gpt-4o-mini")
    end
  end

  setup do
    Nous.ModelDispatcher.put_dispatcher(Stub)
    on_exit(fn -> Collector.attach() end)
  end

  test "a detached trace handler aborts the run instead of recording empty traces" do
    assert {:ok, run} = Nous.Eval.run(Detaching, k: 3, parallelism: 1)

    assert run.status == :aborted
    assert run.metadata.abort_reason == ":trace_handler_detached"
    # Sample 0 finished before the detach; nothing ran after it.
    assert [%{case_id: "a", index: 0, outcome: :ok, verdict: :pass}] = run.samples
    assert run.summary["status"] == "aborted"
  end
end
