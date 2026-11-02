defmodule Nous.Eval.Online.OTelTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Sample, Score, ScorerError, Trace}
  alias Nous.Eval.Online.OTel
  alias Nous.Eval.Trace.Event
  alias Nous.Message

  @tid "4bf92f3577b34da6a3ce929d0e0e4736"
  @root "00f067aa0ba902b7"
  @child "11f067aa0ba902b7"

  defp event(seq, name, meta, measurements \\ %{}),
    do: %Event{seq: seq, at: 100 + seq, name: name, metadata: meta, measurements: measurements}

  defp sample(content?) do
    messages = if content?, do: %{messages: [Message.user("hi")]}, else: %{}
    response = if content?, do: %{response: Message.assistant("hello")}, else: %{}
    args = if content?, do: %{arguments: %{"task" => "x"}}, else: %{}

    events = [
      event(0, [:nous, :agent, :run, :start], %{
        agent_run_id: @root,
        agent_name: "bot",
        model_provider: :openai,
        model_name: "gpt-4o-mini",
        role: :agent
      }),
      event(
        1,
        [:nous, :agent, :model, :start],
        Map.merge(%{agent_run_id: @root, model_name: "gpt-4o-mini"}, messages)
      ),
      event(
        2,
        [:nous, :agent, :model, :stop],
        Map.merge(%{agent_run_id: @root, finish_reason: "tool_calls"}, response),
        %{input_tokens: 7, output_tokens: 3}
      ),
      event(
        3,
        [:nous, :agent, :tool_call, :start],
        Map.merge(%{agent_run_id: @root, tool_call_id: "c1", tool_name: "delegate"}, args)
      ),
      event(4, [:nous, :agent, :run, :start], %{
        agent_run_id: @child,
        parent_agent_run_id: @root,
        parent_tool_call_id: "c1",
        agent_name: "sub"
      }),
      event(5, [:nous, :agent, :run, :stop], %{agent_run_id: @child}),
      event(6, [:nous, :agent, :tool_call, :stop], %{
        agent_run_id: @root,
        tool_call_id: "c1",
        tool_name: "delegate",
        outcome: :executed,
        approval: :not_required
      }),
      event(7, [:nous, :input_guard, :verdict], %{
        agent_run_id: @root,
        severity: :safe,
        action: :allow
      }),
      event(8, [:nous, :agent, :run, :exception], %{
        agent_run_id: @root,
        error_kind: "RuntimeError"
      })
    ]

    %Sample{
      case_id: @tid,
      index: 0,
      outcome: :error,
      trace_id: @tid,
      trace: %Trace{trace_id: @tid, events: events},
      scores: [%Score{name: "q/judge", value: 0.75, passed?: true, reason: "fine"}],
      scorer_errors: [%ScorerError{scorer: "q/other", kind: :timeout}]
    }
  end

  test "runs, model calls and tool calls map to GenAI spans, parents first" do
    spans = OTel.spans(sample(true))
    by_name = Map.new(spans, &{&1.name, &1})

    root = by_name["invoke_agent bot"]
    assert root.span_id == @root and root.parent_span_id == nil
    assert root.status == :error
    assert root.attributes["error.type"] == "RuntimeError"

    tool = by_name["execute_tool delegate"]
    assert tool.parent_span_id == @root
    assert tool.attributes["gen_ai.transfer.target.name"] == "sub"

    # A sub-agent run hangs under the tool call that started it.
    assert by_name["invoke_agent sub"].parent_span_id == tool.span_id

    chat = by_name["chat gpt-4o-mini"]
    assert chat.attributes["gen_ai.usage.input_tokens"] == 7
    assert chat.attributes["gen_ai.response.finish_reasons"] == ["tool_calls"]

    assert Enum.all?(spans, &(&1.trace_id == @tid))
    seen = MapSet.new([nil])

    Enum.reduce(spans, seen, fn span, seen ->
      assert MapSet.member?(seen, span.parent_span_id)
      MapSet.put(seen, span.span_id)
    end)

    evals = for %{name: "gen_ai.evaluation.result", attributes: a} <- root.events, do: a

    assert %{"gen_ai.evaluation.name" => "q/judge", "gen_ai.evaluation.score.value" => 0.75} in evals

    assert %{"gen_ai.evaluation.name" => "q/other", "error.type" => "timeout"} in evals
    assert Enum.any?(root.events, &(&1.name == "nous.input_guard.verdict"))
  end

  test "content attributes and explanations only with export_content: true" do
    hidden = sample(true) |> OTel.spans() |> Enum.flat_map(&Map.keys(&1.attributes))
    refute Enum.any?(hidden, &(&1 in ["gen_ai.input.messages", "gen_ai.tool.call.arguments"]))

    shown = OTel.spans(sample(true), export_content: true)
    attrs = Enum.flat_map(shown, &Map.keys(&1.attributes))
    assert "gen_ai.input.messages" in attrs
    assert "gen_ai.tool.call.arguments" in attrs

    # A sample stored under :drop_content has no content keys to export.
    dropped =
      sample(false) |> OTel.spans(export_content: true) |> Enum.flat_map(&Map.keys(&1.attributes))

    refute Enum.any?(dropped, &String.ends_with?(&1, [".messages", ".arguments", ".result"]))
  end

  test "export/2 needs the OpenTelemetry API; malformed samples yield no spans" do
    unless Code.ensure_loaded?(:otel_tracer) do
      assert {:error, :opentelemetry_not_loaded} = OTel.export(sample(true))
    end

    assert OTel.spans(%Sample{case_id: "x", index: 0, outcome: :ok, trace_id: "nope"}) == []
  end
end
