defmodule Nous.Agent.ContextSerializationTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.{Message, Usage}

  describe "serialize/1" do
    test "includes version field" do
      ctx = Context.new()
      data = Context.serialize(ctx)

      assert data.version == 2
    end

    test "persists the event log alongside the projected messages" do
      ctx =
        Context.new()
        |> Context.add_message(Message.user("Hello"))
        |> Context.add_message(Message.assistant("Hi there!"))

      data = Context.serialize(ctx)

      assert Enum.map(data.events, & &1.seq) == [0, 1]
      assert Enum.map(data.events, & &1.type) == ["user_message", "assistant_message"]
      # JSON-encodable throughout: no atoms for the type, no tuples in the data.
      assert Enum.all?(data.events, &match?({:ok, _, _}, DateTime.from_iso8601(&1.time)))
      assert length(data.messages) == 2
    end

    test "writes a replace surface_op as a list, not a tuple" do
      ctx =
        Context.new(messages: [Message.user("one"), Message.user("two")])
        |> Context.replace_message_range(0, 1, Message.system("[summary]"))

      data = Context.serialize(ctx)

      assert %{surface_op: ["replace", 0, 1]} = List.last(data.events).data
    end

    test "serializes basic fields" do
      ctx =
        Context.new(
          system_prompt: "Be helpful",
          max_iterations: 15,
          agent_name: "test_agent"
        )

      data = Context.serialize(ctx)

      assert data.system_prompt == "Be helpful"
      assert data.max_iterations == 15
      assert data.agent_name == "test_agent"
      assert data.iteration == 0
      assert data.needs_response == true
    end

    test "redacts credential-shaped deps keys" do
      # Persistence auto-saves the context (and the ETS backend is shared), so
      # secret-shaped deps must not be written.
      ctx =
        Context.new(
          deps: %{
            :database => SomeRepo,
            :api_key => "sk-secret",
            "AUTH_TOKEN" => "t0ken",
            :user_password => "hunter2",
            :region => "us-east-1"
          }
        )

      data = Context.serialize(ctx)

      refute Map.has_key?(data.deps, :api_key)
      refute Map.has_key?(data.deps, "AUTH_TOKEN")
      refute Map.has_key?(data.deps, :user_password)
      # Non-sensitive deps are preserved.
      assert data.deps[:database] == SomeRepo
      assert data.deps[:region] == "us-east-1"
    end

    test "serializes messages" do
      ctx =
        Context.new()
        |> Context.add_message(Message.user("Hello"))
        |> Context.add_message(Message.assistant("Hi there!"))

      data = Context.serialize(ctx)

      assert length(data.messages) == 2
      [user_msg, assistant_msg] = data.messages
      assert user_msg.role == :user
      assert user_msg.content == "Hello"
      assert assistant_msg.role == :assistant
      assert assistant_msg.content == "Hi there!"
    end

    test "serializes tool messages" do
      ctx =
        Context.new()
        |> Context.add_message(Message.tool("call_123", "result data", name: "search"))

      data = Context.serialize(ctx)

      [tool_msg] = data.messages
      assert tool_msg.role == :tool
      assert tool_msg.tool_call_id == "call_123"
      assert tool_msg.content == "result data"
      assert tool_msg.name == "search"
    end

    test "serializes usage" do
      usage = %Usage{
        requests: 3,
        tool_calls: 2,
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150
      }

      ctx = Context.new(usage: usage)

      data = Context.serialize(ctx)

      assert data.usage.requests == 3
      assert data.usage.tool_calls == 2
      assert data.usage.input_tokens == 100
      assert data.usage.output_tokens == 50
      assert data.usage.total_tokens == 150
    end

    test "serializes started_at as ISO8601" do
      ctx = Context.new()
      data = Context.serialize(ctx)

      assert is_binary(data.started_at)
      assert {:ok, _, _} = DateTime.from_iso8601(data.started_at)
    end

    test "handles nil started_at" do
      ctx = %Context{Context.new() | started_at: nil}
      data = Context.serialize(ctx)

      assert data.started_at == nil
    end

    test "filters functions from deps" do
      ctx =
        Context.new(
          deps: %{
            user_id: 123,
            callback: fn -> :ok end,
            name: "Alice"
          }
        )

      data = Context.serialize(ctx)

      assert data.deps[:user_id] == 123
      assert data.deps[:name] == "Alice"
      refute Map.has_key?(data.deps, :callback)
    end

    test "filters PIDs from deps" do
      ctx =
        Context.new(
          deps: %{
            user_id: 123,
            some_pid: self()
          }
        )

      data = Context.serialize(ctx)

      assert data.deps[:user_id] == 123
      refute Map.has_key?(data.deps, :some_pid)
    end

    test "never includes callbacks, notify_pid, or cancellation_check" do
      ctx =
        Context.new(
          callbacks: %{on_delta: fn _event, _delta -> :ok end},
          notify_pid: self(),
          cancellation_check: fn -> :ok end
        )

      data = Context.serialize(ctx)

      refute Map.has_key?(data, :callbacks)
      refute Map.has_key?(data, :notify_pid)
      refute Map.has_key?(data, :cancellation_check)
    end

    test "serializes tool_calls" do
      ctx =
        Context.new()
        |> Context.add_tool_call(%{id: "call_1", name: "search", arguments: %{"q" => "test"}})

      data = Context.serialize(ctx)

      assert length(data.tool_calls) == 1
      [call] = data.tool_calls
      assert call.id == "call_1"
    end
  end

  describe "deserialize/1" do
    test "round-trips a basic context" do
      ctx =
        Context.new(
          system_prompt: "Be helpful",
          max_iterations: 15,
          agent_name: "test_agent"
        )

      data = Context.serialize(ctx)
      {:ok, restored} = Context.deserialize(data)

      assert restored.system_prompt == "Be helpful"
      assert restored.max_iterations == 15
      assert restored.agent_name == "test_agent"
    end

    test "round-trips messages" do
      ctx =
        Context.new()
        |> Context.add_message(Message.user("Hello"))
        |> Context.add_message(Message.assistant("Hi!"))

      data = Context.serialize(ctx)
      {:ok, restored} = Context.deserialize(data)

      assert length(restored.messages) == 2
      [user_msg, assistant_msg] = restored.messages
      assert user_msg.role == :user
      assert user_msg.content == "Hello"
      assert assistant_msg.role == :assistant
      assert assistant_msg.content == "Hi!"
    end

    test "round-trips tool messages" do
      ctx =
        Context.new()
        |> Context.add_message(Message.tool("call_1", "result"))

      data = Context.serialize(ctx)
      {:ok, restored} = Context.deserialize(data)

      [tool_msg] = restored.messages
      assert tool_msg.role == :tool
      assert tool_msg.tool_call_id == "call_1"
      assert tool_msg.content == "result"
    end

    test "round-trips usage" do
      usage = %Usage{
        requests: 5,
        tool_calls: 3,
        input_tokens: 200,
        output_tokens: 100,
        total_tokens: 300
      }

      ctx = Context.new(usage: usage)

      data = Context.serialize(ctx)
      {:ok, restored} = Context.deserialize(data)

      assert restored.usage.requests == 5
      assert restored.usage.tool_calls == 3
      assert restored.usage.input_tokens == 200
      assert restored.usage.output_tokens == 100
      assert restored.usage.total_tokens == 300
    end

    test "round-trips started_at" do
      ctx = Context.new()
      data = Context.serialize(ctx)
      {:ok, restored} = Context.deserialize(data)

      # Should be within a second of the original
      diff = DateTime.diff(ctx.started_at, restored.started_at, :second)
      assert abs(diff) <= 1
    end

    test "restores deps without functions" do
      ctx = Context.new(deps: %{user_id: 123, name: "Alice", callback: fn -> :ok end})
      data = Context.serialize(ctx)
      {:ok, restored} = Context.deserialize(data)

      assert restored.deps[:user_id] == 123
      assert restored.deps[:name] == "Alice"
      refute Map.has_key?(restored.deps, :callback)
    end

    test "sets defaults for callbacks, notify_pid, cancellation_check" do
      ctx =
        Context.new(
          callbacks: %{on_delta: fn _e, _d -> :ok end},
          notify_pid: self()
        )

      data = Context.serialize(ctx)
      {:ok, restored} = Context.deserialize(data)

      assert restored.callbacks == %{}
      assert restored.notify_pid == nil
      assert restored.cancellation_check == nil
    end

    test "handles string-keyed maps (as from JSON decode)" do
      data = %{
        "version" => 1,
        "messages" => [
          %{"role" => "user", "content" => "Hello", "tool_calls" => [], "metadata" => %{}}
        ],
        "tool_calls" => [],
        "system_prompt" => "Be helpful",
        "deps" => %{},
        "usage" => %{
          "requests" => 1,
          "tool_calls" => 0,
          "input_tokens" => 50,
          "output_tokens" => 25,
          "total_tokens" => 75
        },
        "needs_response" => false,
        "iteration" => 2,
        "max_iterations" => 10,
        "started_at" => nil,
        "agent_name" => "test"
      }

      {:ok, restored} = Context.deserialize(data)

      assert restored.system_prompt == "Be helpful"
      assert restored.iteration == 2
      assert restored.usage.input_tokens == 50
      assert length(restored.messages) == 1
      [msg] = restored.messages
      assert msg.role == :user
      assert msg.content == "Hello"
    end

    test "returns error for unsupported version" do
      data = %{version: 99}
      assert {:error, "unsupported version: 99"} = Context.deserialize(data)
    end

    test "returns error for string-keyed unsupported version" do
      data = %{"version" => 42}
      assert {:error, "unsupported version: 42"} = Context.deserialize(data)
    end

    test "returns error for missing version" do
      data = %{messages: [], system_prompt: "test"}
      assert {:error, "missing or invalid version field"} = Context.deserialize(data)
    end

    test "returns error for empty map" do
      assert {:error, "missing or invalid version field"} = Context.deserialize(%{})
    end

    test "a v1 blob seeds a log that folds back to its messages" do
      # What a pre-log release wrote: a flat message list, no events.
      v1 = %{
        version: 1,
        messages: [
          %{role: :system, content: "sys", tool_calls: [], metadata: %{}},
          %{role: :user, content: "Q", tool_calls: [], metadata: %{}},
          %{
            role: :assistant,
            content: "",
            tool_calls: [%{"id" => "c1", "name" => "echo"}],
            metadata: %{}
          },
          %{role: :tool, content: "ok", tool_call_id: "c1", name: "echo", metadata: %{}}
        ],
        tool_calls: [],
        system_prompt: "sys",
        deps: %{},
        usage: %{},
        needs_response: true,
        iteration: 1,
        max_iterations: 10,
        started_at: nil,
        agent_name: "legacy"
      }

      {:ok, restored} = Context.deserialize(v1)

      assert Enum.map(restored.messages, & &1.role) == [:system, :user, :assistant, :tool]
      assert Enum.map(restored.messages, & &1.content) == ["sys", "Q", "", "ok"]
      # The messages are a fold of a real log now, not the list that was read.
      assert restored.messages == Nous.Session.Log.derive_messages(restored.log)
      assert Enum.map(Nous.Session.Log.events(restored.log), & &1.seq) == [0, 1, 2, 3]
    end

    test "a v2 blob round-trips events, messages and event times" do
      ctx =
        Context.new(messages: [Message.system("sys"), Message.user("Q")])
        |> Context.add_message(Message.assistant("A"))

      {:ok, restored} = ctx |> Context.serialize() |> Context.deserialize()

      assert restored.messages == ctx.messages

      assert Enum.map(Nous.Session.Log.events(restored.log), &{&1.seq, &1.type, &1.time}) ==
               Enum.map(Nous.Session.Log.events(ctx.log), &{&1.seq, &1.type, &1.time})
    end

    test "a v2 blob keeps shadowed history and the compacted view" do
      ctx =
        Context.new(messages: [Message.user("one"), Message.user("two"), Message.user("three")])
        |> Context.replace_message_range(0, 1, Message.system("[summary of 1-2]"))

      {:ok, restored} = ctx |> Context.serialize() |> Context.deserialize()

      assert Enum.map(restored.messages, & &1.content) == ["[summary of 1-2]", "three"]
      # Nothing was deleted: the shadowed originals survive the round trip.
      assert length(Nous.Session.Log.events(restored.log)) == 4
    end

    test "a v2 blob whose events were written by JSON (string keys) still reads" do
      ctx =
        Context.new(messages: [Message.user("one"), Message.user("two")])
        |> Context.replace_message_range(0, 1, Message.system("[summary]"))

      json_ish =
        ctx
        |> Context.serialize()
        |> Map.update!(:events, fn events ->
          Enum.map(events, fn event ->
            event
            |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
            |> Map.update!("data", fn data ->
              Map.new(data, fn {k, v} -> {Atom.to_string(k), v} end)
            end)
          end)
        end)

      {:ok, restored} = Context.deserialize(json_ish)

      assert Enum.map(restored.messages, & &1.content) == ["[summary]"]
      assert length(Nous.Session.Log.events(restored.log)) == 3
    end
  end
end
