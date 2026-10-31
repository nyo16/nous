defmodule Nous.AgentRunner.HookRegistryAndFailClosedTest do
  # Request-path tests for two hook fixes:
  #
  #   * `run_with_context/3` builds the hook registry, so an AgentServer inbox
  #     run after a session restore (the registry is runtime-only and does not
  #     survive serialization) still fires `:pre_request` hooks.
  #   * a `fail_closed` `:post_tool_use` hook that errors withholds the tool
  #     result from the next model request.
  #
  # async: false — AgentServer runs happen in tasks spawned from the server, so
  # the provider endpoint is configured through application env.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, AgentServer, Hook, Message, Tool}
  alias Nous.Agent.Context
  alias Nous.Persistence.ETS, as: PersistenceETS

  @moduletag :capture_log

  setup do
    Nous.ModelDispatcher.put_dispatcher(nil)
    bypass = Bypass.open()
    %{bypass: bypass, test_pid: self()}
  end

  defp chat_endpoint(bypass, test_pid, responder) do
    counter = :counters.new(1, [])

    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:chat_request, n, JSON.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, JSON.encode!(responder.(n)))
    end)
  end

  defp completion(message, finish_reason) do
    %{
      "id" => "chatcmpl-1",
      "object" => "chat.completion",
      "model" => "test-model",
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10}
    }
  end

  defp text_reply(text), do: completion(%{"role" => "assistant", "content" => text}, "stop")

  defp tool_call_reply(name) do
    completion(
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => name, "arguments" => "{}"}
          }
        ]
      },
      "tool_calls"
    )
  end

  describe "AgentServer inbox run after a session restore" do
    setup %{bypass: bypass} do
      # `agent_config` takes a bare model string, so the endpoint comes from the
      # environment: `custom:` reads CUSTOM_BASE_URL when the model is parsed.
      previous_url = System.get_env("CUSTOM_BASE_URL")
      previous_config = Application.get_env(:nous, :custom)
      System.put_env("CUSTOM_BASE_URL", "http://localhost:#{bypass.port}/v1")
      Application.put_env(:nous, :custom, allow_private_hosts: true)

      on_exit(fn ->
        if previous_url,
          do: System.put_env("CUSTOM_BASE_URL", previous_url),
          else: System.delete_env("CUSTOM_BASE_URL")

        if previous_config,
          do: Application.put_env(:nous, :custom, previous_config),
          else: Application.delete_env(:nous, :custom)
      end)

      PersistenceETS.clear()
      :ok
    end

    defp start_restored_server(hook) do
      session_id = "hook-restore-#{System.unique_integer([:positive])}"

      saved =
        Context.new(system_prompt: "Restored", agent_name: "restored")
        |> Context.add_message(Message.user("earlier question"))
        |> Context.add_message(Message.assistant("earlier answer"))

      :ok = PersistenceETS.save(session_id, Context.serialize(saved))

      start_supervised!(
        Supervisor.child_spec(
          {AgentServer,
           [
             session_id: session_id,
             agent_config: %{model: "custom:test-model", instructions: "", hooks: [hook]},
             persistence: PersistenceETS,
             pubsub: nil,
             inactivity_timeout: :infinity
           ]},
          id: {AgentServer, session_id}
        )
      )
    end

    defp pre_request_hook(test_pid, verdict) do
      Hook.new(:pre_request,
        name: "gate",
        handler: fn :pre_request, payload ->
          send(test_pid, {:pre_request, payload.claimed_content})
          verdict
        end
      )
    end

    test "a denying :pre_request hook blocks the model request", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, fn _ -> text_reply("should never be asked") end)
      server = start_restored_server(pre_request_hook(pid, {:deny, "blocked"}))

      # A steer on an idle server starts an inbox run (run_with_context/3).
      AgentServer.steer(server, "new question")

      assert_receive {:pre_request, ["new question"]}, 2_000
      refute_receive {:chat_request, _, _}, 300
    end

    test "control: an allowing :pre_request hook lets the request through", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, fn _ -> text_reply("answered") end)
      server = start_restored_server(pre_request_hook(pid, :allow))

      AgentServer.steer(server, "new question")

      assert_receive {:pre_request, ["new question"]}, 2_000
      assert_receive {:chat_request, 1, body}, 2_000
      assert Enum.any?(body["messages"], &(&1["content"] == "earlier question"))
    end
  end

  describe "fail_closed :post_tool_use" do
    defp lookup_tool do
      Tool.from_function(fn _ctx, _args -> "SECRET-VALUE" end,
        name: "lookup",
        description: "Looks something up"
      )
    end

    defp agent(bypass, hook) do
      Agent.new("lmstudio:test-model",
        base_url: "http://localhost:#{bypass.port}/v1",
        tools: [lookup_tool()],
        hooks: [hook]
      )
    end

    defp tool_message_sent(body) do
      Enum.find(body["messages"], &(&1["role"] == "tool"))
    end

    test "an erroring fail_closed hook withholds the tool result from the model", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, fn
        1 -> tool_call_reply("lookup")
        _ -> text_reply("done")
      end)

      ref = :telemetry_test.attach_event_handlers(self(), [[:nous, :hook, :failed_closed]])

      hook =
        Hook.new(:post_tool_use,
          name: "redactor",
          handler: fn _event, _payload -> raise "redactor down" end,
          fail_closed: true
        )

      assert {:ok, _result} = AgentRunner.run(agent(bypass, hook), "look it up")

      assert_receive {:chat_request, 2, body}
      tool_msg = tool_message_sent(body)
      assert tool_msg["content"] == "[tool result withheld: hook error]"
      refute JSON.encode!(body) =~ "SECRET-VALUE"

      assert_received {[:nous, :hook, :failed_closed], ^ref, _,
                       %{event: :post_tool_use, hook_name: "redactor"}}
    end

    test "control: without fail_closed the error fails open and the result is sent", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, fn
        1 -> tool_call_reply("lookup")
        _ -> text_reply("done")
      end)

      hook =
        Hook.new(:post_tool_use, handler: fn _event, _payload -> raise "redactor down" end)

      assert {:ok, _result} = AgentRunner.run(agent(bypass, hook), "look it up")

      assert_receive {:chat_request, 2, body}
      assert tool_message_sent(body)["content"] =~ "SECRET-VALUE"
    end
  end
end
