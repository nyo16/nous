defmodule Nous.Eval.Store.CodecTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Codec, Run, Sample, Score, Trace}
  alias Nous.Eval.Store.{Conformance, RunSummary}
  alias Nous.Eval.Trace.Event
  alias Nous.Message
  alias Nous.Message.ContentPart

  defp roundtrip(run) do
    assert {:ok, json} = Codec.encode_run_json(run)
    assert {:ok, decoded} = Codec.decode_run_json(json)
    decoded
  end

  defp run_with_metadata(metadata) do
    event = %Event{name: [:nous, :agent, :tool_call, :stop], metadata: metadata, at: 1, seq: 0}

    sample = %Sample{
      case_id: "c1",
      index: 0,
      outcome: :ok,
      trace: %Trace{trace_id: "t1", events: [event]}
    }

    %Run{id: "run-1", samples: [sample]}
  end

  defp decoded_metadata(run) do
    [%Sample{trace: %Trace{events: [event]}}] = roundtrip(run).samples
    event.metadata
  end

  describe "runs" do
    test "a realistic run survives JSON text unchanged" do
      run = Conformance.run_fixture("run-real")
      assert roundtrip(run) == run
    end

    test "the stored text tags atoms and spells event names as strings" do
      {:ok, json} = Codec.encode_run_json(Conformance.run_fixture("run-real"))
      data = JSON.decode!(json)

      assert data["schema_version"] == Run.schema_version()
      assert data["status"] == "completed"

      [sample | _] = data["samples"]

      stop =
        Enum.find(
          sample["trace"]["events"],
          &(&1["name"] == ["nous", "agent", "tool_call", "stop"])
        )

      assert %{
               "$amap" => %{
                 "outcome" => %{"$atom" => "executed"},
                 "approval" => %{"$atom" => "not_required"}
               }
             } =
               stop["metadata"]

      assert Enum.map(sample["scores"], & &1["value"]) == ["pass", 0.75, %{"label" => "neutral"}]
      assert sample["skipped"] == [["similarity", "no expected output"]]
    end

    test "Messages in model start/stop metadata round-trip with every field" do
      at = ~U[2026-01-02 03:04:05.678901Z]

      user = %{
        Message.user([ContentPart.text("hi"), ContentPart.image("b64", media_type: "image/png")])
        | created_at: at
      }

      response = %{
        Message.assistant("",
          tool_calls: [%{id: "call_1", name: "search", arguments: %{"q" => "x"}}],
          reasoning_content: "thinking"
        )
        | created_at: at
      }

      tool = %{Message.tool("call_1", "result text") | created_at: at}

      metadata =
        decoded_metadata(run_with_metadata(%{messages: [user, tool], response: response}))

      assert metadata.messages == [user, tool]
      assert metadata.response == response

      assert [
               %ContentPart{type: :text},
               %ContentPart{type: :image, options: %{media_type: "image/png"}}
             ] =
               hd(metadata.messages).metadata.content_parts
    end

    test "a stored message with an unknown role is an error, not a guess" do
      {:ok, map} = Codec.encode_run(run_with_metadata(%{response: Message.user("x")}))
      json = map |> JSON.encode!() |> String.replace(~s("role":"user"), ~s("role":"admin"))

      assert {:error, {:invalid_message_field, :role, "admin"}} = Codec.decode_run_json(json)
    end

    test "tuples, dates, non-UTF-8 binaries and $-keyed maps round-trip" do
      metadata = %{
        reason: {:http_error, 503, %{"retry" => true}},
        day: ~D[2026-01-02],
        naive: ~N[2026-01-02 03:04:05],
        time: ~T[03:04:05],
        bytes: <<0xFF, 0x00, 0xC3>>,
        user_map: %{"$atom" => 1},
        dollar: %{"$looks_like_a_tag" => "but is data"},
        mixed: %{1 => "one", "two" => 2, three: 3},
        usage: %Nous.Usage{input_tokens: 5, total_tokens: 5},
        empty: %{}
      }

      assert decoded_metadata(run_with_metadata(metadata)) == metadata
    end

    test "pids, references, functions and unknown structs degrade to data, never terms" do
      pid = self()
      ref = make_ref()
      fun = fn -> :ok end

      metadata =
        decoded_metadata(
          run_with_metadata(%{
            pid: pid,
            ref: ref,
            fun: fun,
            error: %RuntimeError{message: "boom"},
            improper: [1 | 2]
          })
        )

      assert metadata.pid == inspect(pid)
      assert metadata.ref == inspect(ref)
      assert metadata.fun == inspect(fun)
      assert metadata.improper == "[1 | 2]"
      assert metadata.error == %{message: "boom", __exception__: true}
      refute is_struct(metadata.error)
    end

    test "a field that breaks its struct's type is refused at encode time" do
      run = %Run{id: "run-1", status: :running}
      assert {:error, {:invalid_field, {Run, :status}, :running}} = Codec.encode_run(run)

      sample = %Sample{case_id: "c", index: 0, outcome: :ok, error: {:exit, :kill}}

      assert {:error, {:invalid_field, {Sample, :error}, {:exit, :kill}}} =
               Codec.encode_run(%Run{id: "run-1", samples: [sample]})

      score = %Score{name: "s", value: 2, passed?: :yes}

      assert {:error, {:invalid_field, {Score, :passed?}, :yes}} =
               Codec.encode_run(%Run{
                 id: "run-1",
                 samples: [%Sample{case_id: "c", index: 0, outcome: :ok, scores: [score]}]
               })
    end

    test "an unknown enumerated value in a stored record is an error" do
      {:ok, map} = Codec.encode_run(Conformance.run_fixture("run-1"))

      assert {:error, {:invalid_field, {Run, :status}, "paused"}} =
               Codec.decode_run(%{map | "status" => "paused"})
    end
  end

  describe "schema versions" do
    test "a newer record is refused, a missing or bogus version is invalid" do
      {:ok, map} = Codec.encode_run(Conformance.run_fixture("run-1"))
      newer = Run.schema_version() + 1

      assert {:error, {:unsupported_schema_version, ^newer}} =
               Codec.decode_run(%{map | "schema_version" => newer})

      assert {:error, :missing_schema_version} =
               Codec.decode_run(Map.delete(map, "schema_version"))

      assert {:error, {:invalid_schema_version, "1"}} =
               Codec.decode_run(%{map | "schema_version" => "1"})

      assert {:error, {:invalid_schema_version, 0}} =
               Codec.decode_run(%{map | "schema_version" => 0})
    end

    test "summaries are versioned the same way" do
      summary = RunSummary.from_run(Conformance.run_fixture("run-1"))
      {:ok, map} = Codec.encode_summary(summary)

      assert {:ok, ^summary} = Codec.decode_summary(map)

      assert {:error, {:unsupported_schema_version, 99}} =
               Codec.decode_summary(%{map | "schema_version" => 99})
    end

    test "malformed JSON text is an error" do
      assert {:error, {:invalid_json, _}} = Codec.decode_run_json("{not json")
      assert {:error, {:invalid_json, {:not_an_object, [1]}}} = Codec.decode_run_json("[1]")
    end
  end

  describe "untrusted names" do
    test "an unknown event name is dropped and counted in the trace" do
      {:ok, map} = Codec.encode_run(Conformance.run_fixture("run-1"))
      [sample | rest] = map["samples"]
      [first | events] = sample["trace"]["events"]
      bogus = %{first | "name" => ["nous", "made_up", "event"]}
      tampered = put_in(sample, ["trace", "events"], [bogus | events])

      assert {:ok, decoded} = Codec.decode_run(%{map | "samples" => [tampered | rest]})
      [%Sample{trace: trace} | _] = decoded.samples

      assert trace.dropped == 1 + 1
      assert length(trace.events) == length(events)
      refute Enum.any?(trace.events, &(&1.seq == first["seq"]))
    end

    test "an atom that does not exist stays a flagged string and re-encodes to the same tag" do
      {:ok, map} = Codec.encode_run(run_with_metadata(%{outcome: :executed}))

      json =
        map
        |> JSON.encode!()
        |> String.replace(~s("executed"), ~s("nous_codec_test_no_such_atom_q7"))

      assert {:ok, decoded} = Codec.decode_run_json(json)
      [%Sample{trace: %Trace{events: [event]}}] = decoded.samples
      assert event.metadata.outcome == %{"$atom" => "nous_codec_test_no_such_atom_q7"}

      assert {:ok, reencoded} = Codec.encode_run_json(decoded)
      assert reencoded == json
    end
  end
end

defmodule Nous.Eval.Store.CodecAtomTableTest do
  # async: false - asserts on the VM-global atom count, so nothing else may
  # be creating atoms while it runs.
  use ExUnit.Case, async: false

  alias Nous.Eval.Codec
  alias Nous.Eval.Store.Conformance

  # The fixture's first event gets an unknown name; its second keeps a known
  # name but carries an unknown metadata key and unknown atom values.
  defp hostile_payload(suffix) do
    {:ok, map} = Codec.encode_run(Conformance.run_fixture("run-hostile"))
    [sample | rest] = map["samples"]
    [first, second | events] = sample["trace"]["events"]

    renamed = %{first | "name" => ["nous", "evil_event_" <> suffix]}

    tampered = %{
      second
      | "metadata" => %{
          "$amap" => %{
            ("evil_key_" <> suffix) => %{"$atom" => "evil_value_" <> suffix},
            "outcome" => %{"$atom" => "evil_outcome_" <> suffix}
          }
        }
    }

    sample = put_in(sample, ["trace", "events"], [renamed, tampered | events])
    JSON.encode!(%{map | "samples" => [sample | rest]})
  end

  test "decoding stored data never creates atoms" do
    # Warm up: load every module the decode path touches.
    {:ok, _} = Codec.decode_run_json(hostile_payload("warmup"))

    payload = hostile_payload("x9k2")
    before = :erlang.system_info(:atom_count)
    assert {:ok, run} = Codec.decode_run_json(payload)
    assert :erlang.system_info(:atom_count) == before

    for name <- ~w(evil_event_x9k2 evil_key_x9k2 evil_value_x9k2 evil_outcome_x9k2) do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    [%{trace: trace} | _] = run.samples
    # The fixture's own dropped event plus the renamed one.
    assert trace.dropped == 2
    [tampered | _] = trace.events

    assert tampered.metadata == %{
             "evil_key_x9k2" => %{"$atom" => "evil_value_x9k2"},
             outcome: %{"$atom" => "evil_outcome_x9k2"}
           }
  end
end
