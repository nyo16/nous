defmodule Nous.AgentRunner.MessagesEntryTest do
  # R5: `Nous.run(agent, messages: [...])` built a bare context and sent no
  # system message at all: instructions, `system_prompt` and the
  # structured-output instructions never reached the model. Every assertion is
  # on the request body the provider receives.
  use ExUnit.Case, async: false

  alias Nous.{Agent, Message}

  import ExUnit.CaptureLog

  @moduletag :capture_log

  defmodule OverlayPlugin do
    @moduledoc false
    @behaviour Nous.Plugin

    @impl true
    def system_prompt(_agent, _ctx), do: "OVERLAY-TEXT"
  end

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

  defp occurrences(text, pattern), do: length(String.split(text, pattern)) - 1

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

  test "an agent without instructions sends the caller's system message once",
       %{base_url: base_url} do
    agent = agent(base_url, [])

    log =
      capture_log(fn ->
        {:ok, _} =
          Nous.run(agent, messages: [Message.system("CALLER SYSTEM"), Message.user("hi")])
      end)

    body = next_request()
    assert system_contents(body) == ["CALLER SYSTEM"]
    assert Enum.map(body["messages"], & &1["role"]) == ["system", "user"]
    refute log =~ "system_message: :caller"
  end

  test "a compacted history keeps its summary after the agent prompt",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")

    history = [
      Message.system("AGENT INSTRUCTIONS"),
      Message.system("[Conversation Summary]\nThe user likes blue."),
      Message.user("hello"),
      Message.assistant("hi")
    ]

    log = capture_log(fn -> {:ok, _} = Nous.run(agent, "again", message_history: history) end)

    body = next_request()

    assert system_contents(body) == [
             "AGENT INSTRUCTIONS",
             "[Conversation Summary]\nThe user likes blue."
           ]

    assert Enum.map(body["messages"], & &1["role"]) ==
             ["system", "system", "user", "assistant", "user"]

    refute log =~ "system_message: :caller"
  end

  test "a system message in the middle of the conversation is left alone",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")

    {:ok, _} =
      Nous.run(agent,
        messages: [
          Message.user("a"),
          Message.assistant("b"),
          Message.system("MID NOTE"),
          Message.user("c")
        ]
      )

    body = next_request()
    assert system_contents(body) == ["AGENT INSTRUCTIONS", "MID NOTE"]

    assert Enum.map(body["messages"], & &1["role"]) ==
             ["system", "user", "assistant", "system", "user"]
  end

  test "system_message: :caller with the agent's own prompt records it",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")

    {:ok, result} =
      Nous.run(agent, [messages: [Message.system("AGENT INSTRUCTIONS"), Message.user("hi")]],
        system_message: :caller
      )

    assert system_contents(next_request()) == ["AGENT INSTRUCTIONS"]
    assert result.context.system_prompt == "AGENT INSTRUCTIONS"
  end

  test "function instructions are called once per run", %{base_url: base_url} do
    test_pid = self()

    instructions = fn _ctx ->
      send(test_pid, :instructions_called)
      "FN INSTRUCTIONS"
    end

    agent = agent(base_url, instructions: instructions)
    history = [Message.system("STALE PROMPT"), Message.user("hello"), Message.assistant("hi")]

    {:ok, _} = Nous.run(agent, "again", message_history: history)
    assert system_contents(next_request()) == ["FN INSTRUCTIONS"]
    assert_received :instructions_called
    refute_received :instructions_called

    {:ok, _} = Nous.run(agent, messages: history ++ [Message.user("again")])
    assert system_contents(next_request()) == ["FN INSTRUCTIONS"]
    assert_received :instructions_called
    refute_received :instructions_called
  end

  # The agent's prompt is authoritative. A caller's own leading system
  # message is replaced unless the run opts in with `system_message: :caller`.
  test "messages: a caller's leading system message is replaced by the agent prompt",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")

    log =
      capture_log(fn ->
        {:ok, result} =
          Nous.run(agent, messages: [Message.system("CALLER SYSTEM"), Message.user("hi")])

        send(self(), {:result, result})
      end)

    body = next_request()
    assert system_contents(body) == ["AGENT INSTRUCTIONS"]
    assert Enum.map(body["messages"], & &1["role"]) == ["system", "user"]
    assert_received {:result, result}
    assert result.context.system_prompt == "AGENT INSTRUCTIONS"
    assert occurrences(log, "system_message: :caller") == 1
  end

  test "messages: system_message: :caller keeps the caller's system message",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")

    {:ok, result} =
      Nous.run(agent, [messages: [Message.system("CALLER SYSTEM"), Message.user("hi")]],
        system_message: :caller
      )

    assert system_contents(next_request()) == ["CALLER SYSTEM"]
    assert result.context.system_prompt == nil
  end

  test "message_history: a diverged leading system message is replaced, with one warning",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "NEW PROFILE INSTRUCTIONS")

    history = [
      Message.system("OLD PROFILE INSTRUCTIONS"),
      Message.user("hello"),
      Message.assistant("hi")
    ]

    log =
      capture_log(fn ->
        {:ok, _} = Nous.run(agent, "again", message_history: history)
      end)

    body = next_request()
    assert system_contents(body) == ["NEW PROFILE INSTRUCTIONS"]
    refute JSON.encode!(body) =~ "OLD PROFILE INSTRUCTIONS"
    assert Enum.map(body["messages"], & &1["role"]) == ["system", "user", "assistant", "user"]
    assert occurrences(log, "system_message: :caller") == 1
  end

  test "message_history: system_message: :caller sends the caller's text",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")
    history = [Message.system("CALLER SYSTEM"), Message.user("hello"), Message.assistant("hi")]

    {:ok, result} =
      Nous.run(agent, "again", message_history: history, system_message: :caller)

    assert system_contents(next_request()) == ["CALLER SYSTEM"]
    assert result.context.system_prompt == nil
  end

  test "a legacy history with repeated system messages is sent with one",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")

    history = [
      Message.system("AGENT INSTRUCTIONS"),
      Message.system("AGENT INSTRUCTIONS"),
      Message.user("hello"),
      Message.assistant("hi")
    ]

    log = capture_log(fn -> {:ok, _} = Nous.run(agent, "again", message_history: history) end)

    body = next_request()
    assert system_contents(body) == ["AGENT INSTRUCTIONS"]
    assert Enum.map(body["messages"], & &1["role"]) == ["system", "user", "assistant", "user"]
    refute log =~ "system_message: :caller"

    {:ok, _} = Nous.run(agent, messages: history ++ [Message.user("again")])
    assert system_contents(next_request()) == ["AGENT INSTRUCTIONS"]
  end

  test "continuing with all_messages sends a plugin overlay exactly once",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS", plugins: [OverlayPlugin])

    log =
      capture_log(fn ->
        {:ok, first} = Nous.run(agent, "one")
        {:ok, second} = Nous.run(agent, "two", message_history: first.all_messages)
        {:ok, _} = Nous.run(agent, "three", message_history: second.all_messages)
      end)

    _ = next_request()
    _ = next_request()
    body = next_request()

    assert [system] = system_contents(body)
    assert String.starts_with?(system, "AGENT INSTRUCTIONS")
    assert occurrences(system, "OVERLAY-TEXT") == 1

    assert Enum.map(body["messages"], & &1["role"]) ==
             ["system", "user", "assistant", "user", "assistant", "user"]

    refute log =~ "system_message: :caller"
  end

  test "an invalid system_message raises ArgumentError", %{base_url: base_url} do
    agent = agent(base_url, instructions: "AGENT INSTRUCTIONS")

    assert_raise ArgumentError, ~r/:system_message/, fn ->
      Nous.run(agent, "hi", system_message: :bogus)
    end

    assert_raise ArgumentError, ~r/:system_message/, fn ->
      Nous.run(agent, messages: [Message.user("hi")], system_message: "caller")
    end

    refute_received {:request, _}
  end

  test "a run-level output_type override shapes the suffix", %{base_url: base_url} do
    agent = agent(base_url, instructions: "BASE")

    {:ok, _} =
      Nous.run(agent, [messages: [Message.user("ok?")]], output_type: {:choice, ["yes", "no"]})

    [system] = system_contents(next_request())
    assert system =~ "BASE"
    assert system =~ "yes, no"
  end

  # Strict chat templates (Qwen) reject a system message that is not first;
  # `message_history: result.all_messages` used to send the agent's prompt
  # twice. Found with LM Studio.
  test "continuing with message_history: all_messages sends one system message",
       %{base_url: base_url} do
    agent = agent(base_url, instructions: "Remember what the user tells you.")

    {:ok, first} = Nous.run(agent, "My favorite color is blue.")
    _ = next_request()

    {:ok, second} =
      Nous.run(agent, "What is my favorite color?", message_history: first.all_messages)

    body = next_request()

    assert system_contents(body) == ["Remember what the user tells you."]
    assert Enum.map(body["messages"], & &1["role"]) == ["system", "user", "assistant", "user"]
    assert second.context.system_prompt == "Remember what the user tells you."
  end
end
