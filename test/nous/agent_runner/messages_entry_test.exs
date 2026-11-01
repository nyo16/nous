defmodule Nous.AgentRunner.MessagesEntryTest do
  # R5: `Nous.run(agent, messages: [...])` built a bare context and sent no
  # system message at all: instructions, `system_prompt` and the
  # structured-output instructions never reached the model. Every assertion is
  # on the request body the provider receives.
  use ExUnit.Case, async: false

  alias Nous.{Agent, Message}

  @moduletag :capture_log

  setup do
    Nous.ModelDispatcher.put_dispatcher(nil)
    previous = Application.get_env(:nous, :custom)
    Application.put_env(:nous, :custom, allow_private_hosts: true)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nous, :custom, previous),
        else: Application.delete_env(:nous, :custom)
    end)

    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, JSON.decode!(raw)})

      reply = %{
        "id" => "chatcmpl-1",
        "object" => "chat.completion",
        "model" => "test-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "yes"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6}
      }

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, JSON.encode!(reply))
    end)

    %{base_url: "http://localhost:#{bypass.port}/v1"}
  end

  defp agent(base_url, opts) do
    Agent.new("custom:test-model", [base_url: base_url, api_key: "k"] ++ opts)
  end

  defp next_request do
    assert_receive {:request, body}, 2_000
    body
  end

  defp system_contents(body) do
    for %{"role" => "system", "content" => content} <- body["messages"], do: content
  end

  test "sends the same system prompt as a string prompt, structured-output suffix included",
       %{base_url: base_url} do
    agent =
      agent(base_url, instructions: "INSTR: be terse", output_type: {:choice, ["yes", "no"]})

    {:ok, _} = Nous.run(agent, "is water wet?")
    [prompt_path_system] = system_contents(next_request())
    assert prompt_path_system =~ "INSTR: be terse"
    assert prompt_path_system =~ "yes, no"

    {:ok, result} = Nous.run(agent, messages: [Message.user("is water wet?")])
    body = next_request()

    assert system_contents(body) == [prompt_path_system]
    assert Enum.map(body["messages"], & &1["role"]) == ["system", "user"]
    assert result.output == "yes"
  end

  test "an agent with only a system_prompt sends it", %{base_url: base_url} do
    agent = agent(base_url, system_prompt: "SYSPROMPT-ONLY")

    {:ok, _} = Nous.run(agent, messages: [Message.user("hi")])

    assert system_contents(next_request()) == ["SYSPROMPT-ONLY"]
  end

  test "a caller-supplied leading system message wins and is not duplicated",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")

    {:ok, result} =
      Nous.run(agent, messages: [Message.system("CALLER SYSTEM"), Message.user("hi")])

    assert system_contents(next_request()) == ["CALLER SYSTEM"]
    assert result.context.system_prompt == nil
  end

  test "a run-level output_type override shapes the suffix", %{base_url: base_url} do
    agent = agent(base_url, instructions: "BASE")

    {:ok, _} =
      Nous.run(agent, [messages: [Message.user("ok?")]], output_type: {:choice, ["yes", "no"]})

    [system] = system_contents(next_request())
    assert system =~ "BASE"
    assert system =~ "yes, no"
  end
end
