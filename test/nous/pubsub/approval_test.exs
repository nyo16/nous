defmodule Nous.PubSub.ApprovalTest do
  use ExUnit.Case, async: true

  alias Nous.PubSub
  alias Nous.PubSub.Approval

  setup do
    pubsub_name = :"approval_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    session_id = "session_#{System.unique_integer([:positive])}"
    %{pubsub: pubsub_name, session_id: session_id}
  end

  describe "handler/1 and respond/4" do
    test "approve flow works end-to-end", %{pubsub: pubsub, session_id: session_id} do
      handler = Approval.handler(pubsub: pubsub, session_id: session_id, timeout: 5_000)

      tool_call = %{id: "call_1", name: "send_email", arguments: %{"to" => "bob"}}

      # Subscribe to agent topic to see the approval_required broadcast
      agent_topic = PubSub.agent_topic(session_id)
      PubSub.subscribe(pubsub, agent_topic)

      # Spawn handler in a separate process (it blocks)
      task =
        Task.async(fn ->
          handler.(tool_call)
        end)

      # Wait for the approval_required broadcast
      assert_receive {:approval_required, info}, 2_000
      assert info.tool_call_id == "call_1"
      assert info.name == "send_email"
      assert info.arguments == %{"to" => "bob"}
      assert info.session_id == session_id

      # Respond with approval
      :ok = Approval.respond(pubsub, session_id, "call_1", :approve)

      # Handler should return :approve
      assert Task.await(task, 2_000) == :approve
    end

    test "reject flow works", %{pubsub: pubsub, session_id: session_id} do
      handler = Approval.handler(pubsub: pubsub, session_id: session_id, timeout: 5_000)

      tool_call = %{id: "call_2", name: "delete_file", arguments: %{"path" => "/tmp/x"}}

      task =
        Task.async(fn ->
          handler.(tool_call)
        end)

      # Small delay to let handler subscribe
      Process.sleep(50)

      :ok = Approval.respond(pubsub, session_id, "call_2", :reject)

      assert Task.await(task, 2_000) == :reject
    end

    test "edit flow works", %{pubsub: pubsub, session_id: session_id} do
      handler = Approval.handler(pubsub: pubsub, session_id: session_id, timeout: 5_000)

      tool_call = %{id: "call_3", name: "send_email", arguments: %{"to" => "bob"}}

      task =
        Task.async(fn ->
          handler.(tool_call)
        end)

      Process.sleep(50)

      new_args = %{"to" => "alice"}
      :ok = Approval.respond(pubsub, session_id, "call_3", {:edit, new_args})

      assert Task.await(task, 2_000) == {:edit, new_args}
    end

    test "timeout results in reject", %{pubsub: pubsub, session_id: session_id} do
      handler = Approval.handler(pubsub: pubsub, session_id: session_id, timeout: 100)

      tool_call = %{id: "call_4", name: "slow_tool", arguments: %{}}

      # Don't respond - let it timeout
      result = handler.(tool_call)

      assert result == :reject
    end
  end

  describe "respond/4" do
    test "broadcasts on approval topic", %{pubsub: pubsub, session_id: session_id} do
      approval_topic = PubSub.approval_topic(session_id)
      PubSub.subscribe(pubsub, approval_topic)

      :ok = Approval.respond(pubsub, session_id, "call_5", :approve)

      assert_receive {:approval_response, "call_5", :approve}
    end
  end
end
