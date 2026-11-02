defmodule Nous.Eval.Online.RedactionTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Score, ScorerError, Trace}
  alias Nous.Eval.Online.{Content, Redaction, Redactor}
  alias Nous.Eval.Trace.Event
  alias Nous.Message
  alias Nous.Message.ContentPart

  @canary "CANARY-0e1d2c3b4a596877"
  @tid "4bf92f3577b34da6a3ce929d0e0e4736"
  @rid "00f067aa0ba902b7"
  @sup Nous.TaskSupervisor

  defp event(seq, name, measurements, metadata),
    do: %Event{
      seq: seq,
      at: 1_000 + seq,
      name: name,
      measurements: measurements,
      metadata: metadata
    }

  # A user message whose provider-visible text is only in
  # `metadata.content_parts` (solution: redaction-keeps-content-parts).
  defp multimodal do
    %Message{
      role: :user,
      content: "hello there",
      metadata: %{
        content_parts: [
          %ContentPart{type: :text, content: "see " <> @canary},
          %ContentPart{type: :image_url, content: "https://img.example/#{@canary}.png"}
        ]
      }
    }
  end

  defp trace do
    ids = %{trace_id: @tid, agent_run_id: @rid, parent_agent_run_id: nil}

    %Trace{
      trace_id: @tid,
      events: [
        event(
          0,
          [:nous, :agent, :run, :start],
          %{system_time: 1},
          Map.merge(ids, %{agent_name: "bot", role: :agent, session_id: "s-" <> @canary})
        ),
        event(
          1,
          [:nous, :agent, :model, :start],
          %{system_time: 2},
          Map.merge(ids, %{
            agent_name: "bot",
            model_provider: :openai,
            model_name: "gpt-4o-mini",
            tool_names: ["lookup"],
            messages: [Message.system("Help."), multimodal()]
          })
        ),
        event(
          2,
          [:nous, :agent, :model, :stop],
          %{input_tokens: 7, output_tokens: 3, label: "not a number"},
          Map.merge(ids, %{
            finish_reason: "tool_calls",
            requested_tool_calls: [
              %{tool_call_id: "c1", tool_name: "lookup", arguments: %{"q" => @canary}}
            ],
            response: Message.assistant("ok " <> @canary)
          })
        ),
        event(
          3,
          [:nous, :agent, :tool_call, :stop],
          %{duration: 5},
          Map.merge(ids, %{
            tool_call_id: "c1",
            tool_name: "lookup",
            outcome: :executed,
            arguments: %{"q" => @canary},
            result: "found " <> @canary,
            verdict: %{"nested" => @canary},
            a_future_key: @canary
          })
        ),
        event(
          4,
          [:nous, :agent, :run, :exception],
          %{duration: 9},
          Map.merge(ids, %{kind: :error, reason: RuntimeError.exception(@canary), stacktrace: []})
        )
      ]
    }
  end

  defp scrub(content), do: Redactor.map_text(content, &String.replace(&1, @canary, "[R]"))

  describe "split/1" do
    test "the skeleton is an allowlist; everything else, future keys included, is content" do
      {content, _keys} = Redaction.split(trace())

      assert %Content{trace_id: @tid, skeleton: skeleton, fields: fields} = content
      refute inspect(skeleton, limit: :infinity, printable_limit: :infinity) =~ @canary

      assert Map.keys(fields) |> Enum.sort() ==
               Enum.sort([
                 {0, "session_id"},
                 {1, "messages"},
                 {2, "response"},
                 {3, "arguments"},
                 {3, "result"},
                 {3, "verdict"},
                 {3, "a_future_key"},
                 {4, "reason"},
                 {4, "stacktrace"}
               ])

      [start, model_start, model_stop, tool_stop, exception] = skeleton
      assert start.metadata.agent_name == "bot"
      assert model_start.metadata.tool_names == ["lookup"]
      # Only the id and tool name of a requested call; non-numeric measurements dropped.
      assert model_stop.metadata.requested_tool_calls == [
               %{tool_call_id: "c1", tool_name: "lookup"}
             ]

      assert model_stop.measurements == %{input_tokens: 7, output_tokens: 3}
      assert tool_stop.metadata.outcome == :executed
      # The kind of the failure, never its message.
      assert exception.metadata.error_kind == "RuntimeError"
    end

    test "message content parts are content: map_text reaches them and the message still decodes" do
      {content, keys} = Redaction.split(trace())
      assert {:ok, redacted, :redacted} = Redaction.redact(&scrub/1, content, 1_000, @sup)
      assert {:ok, rebuilt} = Redaction.rebuild(trace(), redacted, keys)

      refute inspect(rebuilt, limit: :infinity, printable_limit: :infinity) =~ @canary

      %Event{metadata: %{messages: [_system, %Message{} = user]}} = Enum.at(rebuilt.events, 1)
      assert user.content == "hello there"

      assert [%ContentPart{type: :text, content: "see [R]"}, %ContentPart{content: image}] =
               user.metadata.content_parts

      assert image == "https://img.example/[R].png"
      assert user.role == :user
    end

    test "a tool name the run did not offer is content, not skeleton" do
      chosen = "exfil " <> @canary
      other_run = %{trace_id: @tid, agent_run_id: "11f067aa0ba902b7", parent_agent_run_id: @rid}

      # Another run in the same trace offers the name; it does not count for @rid.
      offered_elsewhere =
        event(
          5,
          [:nous, :agent, :model, :start],
          %{system_time: 3},
          Map.merge(other_run, %{tool_names: [chosen]})
        )

      unoffered =
        event(
          6,
          [:nous, :agent, :model, :stop],
          %{input_tokens: 1},
          %{
            trace_id: @tid,
            agent_run_id: @rid,
            requested_tool_calls: [
              %{tool_call_id: "c1", tool_name: "lookup"},
              %{tool_call_id: "c2", tool_name: chosen}
            ]
          }
        )

      tool_stop =
        event(
          7,
          [:nous, :agent, :tool_call, :stop],
          %{duration: 1},
          %{trace_id: @tid, agent_run_id: @rid, tool_call_id: "c2", tool_name: chosen}
        )

      trace = %{trace() | events: trace().events ++ [offered_elsewhere, unoffered, tool_stop]}
      {content, keys} = Redaction.split(trace)

      skeleton = Enum.drop(content.skeleton, 6)
      refute inspect(skeleton, limit: :infinity, printable_limit: :infinity) =~ @canary

      [stop_entry, tool_entry] = skeleton

      assert stop_entry.metadata.requested_tool_calls == [
               %{tool_call_id: "c1", tool_name: "lookup"},
               %{tool_call_id: "c2"}
             ]

      refute Map.has_key?(tool_entry.metadata, :tool_name)
      assert Map.has_key?(content.fields, {6, "requested_tool_calls"})
      assert Map.has_key?(content.fields, {7, "tool_name"})

      # The redactor decides what survives; dropping content keeps only the ids.
      assert {:ok, redacted, :redacted} = Redaction.redact(&scrub/1, content, 1_000, @sup)
      assert {:ok, rebuilt} = Redaction.rebuild(trace, redacted, keys)
      [rebuilt_stop, rebuilt_tool] = Enum.drop(rebuilt.events, 6)
      assert rebuilt_tool.metadata.tool_name == "exfil [R]"

      assert rebuilt_stop.metadata.requested_tool_calls == [
               %{tool_call_id: "c1", tool_name: "lookup"},
               %{tool_call_id: "c2", tool_name: "exfil [R]"}
             ]

      [dropped_stop, dropped_tool] = Enum.drop(Redaction.skeleton_trace(trace, content).events, 6)
      ids_only = stop_entry.metadata.requested_tool_calls
      assert dropped_stop.metadata.requested_tool_calls == ids_only
      refute Map.has_key?(dropped_tool.metadata, :tool_name)
    end
  end

  describe "redact/4 contract (F2, F3, F4)" do
    @failing [
      {:raised, &__MODULE__.raise_quoting/1},
      {:thrown, &__MODULE__.throw_it/1},
      {:exited, &__MODULE__.exit_it/1},
      {:keys_changed, &__MODULE__.drop_key/1},
      {:keys_changed, &__MODULE__.add_key/1},
      {:trace_id_changed, &__MODULE__.other_trace/1},
      {:skeleton_changed, &__MODULE__.edit_skeleton/1},
      {:not_json, &__MODULE__.pid_value/1},
      {:not_json, &__MODULE__.tuple_value/1},
      {:not_json, &__MODULE__.invalid_utf8/1},
      {:invalid_return, &__MODULE__.not_content/1}
    ]

    def raise_quoting(content), do: raise(KeyError, key: :x, term: content)
    def throw_it(content), do: throw(content)
    def exit_it(content), do: exit({:bad, content})
    def drop_key(c), do: %{c | fields: Map.delete(c.fields, {1, "messages"})}
    def add_key(c), do: %{c | fields: Map.put(c.fields, {9, "extra"}, "x")}
    def other_trace(c), do: %{c | trace_id: String.duplicate("0", 32)}
    def edit_skeleton(c), do: %{c | skeleton: Enum.drop(c.skeleton, 1)}
    def pid_value(c), do: %{c | fields: Map.put(c.fields, {3, "result"}, self())}
    def tuple_value(c), do: %{c | fields: Map.put(c.fields, {3, "result"}, {:ok, "x"})}
    def invalid_utf8(c), do: %{c | fields: Map.put(c.fields, {3, "result"}, <<0xFF, 0xFE>>)}
    def not_content(c), do: c.fields

    for {kind, fun} <- @failing do
      test "#{inspect(fun)} fails as #{kind}, with nothing but the kind" do
        {content, _keys} = Redaction.split(trace())
        assert {:error, unquote(kind)} = Redaction.redact(unquote(fun), content, 1_000, @sup)
      end
    end

    test "a value that is JSON but not Codec JSON fails rebuilding as undecodable" do
      {content, keys} = Redaction.split(trace())
      broken = fn c -> %{c | fields: Map.put(c.fields, {2, "response"}, %{"$msg" => "nope"})} end
      assert {:ok, redacted, :redacted} = Redaction.redact(broken, content, 1_000, @sup)
      assert {:error, :undecodable} = Redaction.rebuild(trace(), redacted, keys)
    end

    test "a hanging redactor is killed at the time limit" do
      {content, _keys} = Redaction.split(trace())
      test = self()

      hang = fn _c ->
        send(test, {:redactor, self()})
        Process.sleep(:infinity)
      end

      {micros, result} = :timer.tc(fn -> Redaction.redact(hang, content, 100, @sup) end)
      assert result == {:error, :timeout}
      assert micros < 1_000_000
      assert_received {:redactor, pid}
      refute Process.alive?(pid)
    end

    test ":redacted may replace any value; :drop_content keeps no field" do
      {content, keys} = Redaction.split(trace())
      all = fn c -> %{c | fields: Map.new(c.fields, fn {k, _} -> {k, :redacted} end)} end

      assert {:ok, redacted, :redacted} = Redaction.redact(all, content, 1_000, @sup)
      assert {:ok, rebuilt} = Redaction.rebuild(trace(), redacted, keys)
      assert Enum.at(rebuilt.events, 3).metadata.result == :redacted

      assert {:ok, %Content{fields: fields}, :dropped} =
               Redaction.redact(:drop_content, content, 1_000, @sup)

      assert fields == %{}
      skeleton = Redaction.skeleton_trace(trace(), content)
      refute inspect(skeleton, limit: :infinity, printable_limit: :infinity) =~ @canary
    end

    test "the redactor runs outside the calling process" do
      {content, _keys} = Redaction.split(trace())
      test = self()
      spy = fn c -> send(test, {:ran_in, self()}) && c end

      assert {:ok, _content, :redacted} = Redaction.redact(spy, content, 1_000, @sup)
      assert_received {:ran_in, pid}
      refute pid == self()
    end
  end

  describe "score explanations" do
    defp scores do
      [
        %Score{
          name: "judge",
          value: 0.5,
          passed?: false,
          reason: "quotes " <> @canary,
          details: %{critique: @canary},
          metadata: %{label: "fail", model: "openai:gpt-4o-mini", echo: @canary}
        }
      ]
    end

    defp errors, do: [%ScorerError{scorer: "x", kind: :raised, reason: "boom " <> @canary}]

    test "are redacted with the redactor, metadata kept only for the instrument keys" do
      assert {[score], [error], :redacted} =
               Redaction.redact_scores(scores(), errors(), @tid, &scrub/1, 1_000, @sup)

      assert score.reason == "quotes [R]"
      assert score.details == %{"critique" => "[R]"} or score.details == %{critique: "[R]"}
      assert score.metadata == %{label: "fail", model: "openai:gpt-4o-mini"}
      assert error.reason == "boom [R]"
    end

    test "are dropped under :drop_content and when the redactor fails" do
      for redactor <- [:drop_content, fn _ -> raise "x" end] do
        {[score], [error], _status} =
          Redaction.redact_scores(scores(), errors(), @tid, redactor, 1_000, @sup)

        assert {score.reason, score.details, error.reason} == {nil, %{}, nil}
        refute inspect([score, error]) =~ @canary
      end
    end
  end

  test "Redactor.check/2 catches a nondeterministic redactor" do
    {content, _keys} = Redaction.split(trace())

    assert {:ok, %Content{}} = Redactor.check(&scrub/1, content)

    random = fn c ->
      Redactor.map_text(c, fn _ -> Integer.to_string(System.unique_integer()) end)
    end

    assert {:error, :nondeterministic} = Redactor.check(random, content)
    assert {:error, :raised} = Redactor.check(fn _ -> raise "x" end, content)
  end
end
