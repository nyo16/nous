defmodule Nous.AgentServerPluginInitTest do
  # #95: an AgentServer inbox run goes through AgentRunner.run_with_context/3,
  # which never ran plugin init/2. On a fresh server whose first run is an
  # inbox run, HumanInTheLoop never installed its approval handler, so an
  # approval-gated tool was refused even though the operator approved it.
  #
  # async: false — AgentServer runs happen in tasks spawned from the server, so
  # the provider endpoint is configured through application env.
  use ExUnit.Case, async: false

  alias Nous.{AgentServer, Tool}

  @moduletag :capture_log

  setup do
    Nous.ModelDispatcher.put_dispatcher(nil)
    bypass = Bypass.open()

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

  defp text_reply(text), do: completion(%{"role" => "assistant", "content" => text}, "stop")

  test "a fresh server's first inbox run installs the HumanInTheLoop approval handler", %{
    bypass: bypass,
    test_pid: pid
  } do
    chat_endpoint(bypass, pid, fn
      1 -> tool_call_reply("lookup")
      _ -> text_reply("done")
    end)

    lookup =
      Tool.from_function(
        fn _ctx, _args ->
          send(pid, :lookup_ran)
          "looked up"
        end,
        name: "lookup",
        description: "Looks something up"
      )

    session_id = "plugin-init-#{System.unique_integer([:positive])}"

    server =
      start_supervised!(
        Supervisor.child_spec(
          {AgentServer,
           [
             session_id: session_id,
             agent_config: %{
               model: "custom:test-model",
               instructions: "",
               tools: [lookup],
               plugins: [Nous.Plugins.HumanInTheLoop],
               deps: %{
                 hitl_config: %{
                   tools: ["lookup"],
                   handler: fn call ->
                     send(pid, {:approval_asked, call.name})
                     :approve
                   end
                 }
               }
             },
             pubsub: nil,
             inactivity_timeout: :infinity
           ]},
          id: {AgentServer, session_id}
        )
      )

    # A steer on an idle server starts an inbox run (run_with_context/3).
    AgentServer.steer(server, "look it up")

    assert_receive {:approval_asked, "lookup"}, 2_000
    assert_receive :lookup_ran, 2_000
    assert_receive {:chat_request, 2, body}, 2_000

    tool_message = Enum.find(body["messages"], &(&1["role"] == "tool"))
    assert tool_message["content"] =~ "looked up"
  end
end
