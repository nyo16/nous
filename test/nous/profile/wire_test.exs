defmodule Nous.Profile.WireTest do
  # Request-path tests for `Nous.Profile`: every assertion is on what a
  # provider receives over HTTP (Bypass), on telemetry, or on what the caller
  # gets back. A profile that validates but never reaches the request body is
  # exactly the failure these exist to catch.
  #
  # async: false — AgentServer and sub-agent runs reach the provider through
  # the `custom` provider's application env, and telemetry handlers are global.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, AgentServer, Hook, Message, Profile}
  alias Nous.Agent.Context
  alias Nous.Errors.ProfileError
  alias Nous.Hook.Decision
  alias Nous.Plugins.SubAgent
  alias Nous.Test.FakeDecisionBackend
  alias NousTest.ProfileFixtures, as: F

  @moduletag :capture_log

  setup do
    Nous.ModelDispatcher.put_dispatcher(nil)
    bypass = Bypass.open()

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

  # ── wire helpers ──────────────────────────────────────────────────────────

  # An OpenAI-compatible chat endpoint. `responder.(n)` is `:tool_call` (one
  # `search_orders` call) or `{:text, text}`; a streamed request gets SSE.
  defp chat_endpoint(bypass, test_pid, responder, tag \\ :request) do
    counter = :counters.new(1, [])

    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      body = JSON.decode!(raw)
      send(test_pid, {tag, n, body})
      reply = responder.(n)

      if body["stream"] do
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.resp(200, sse_body(reply))
      else
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, JSON.encode!(json_body(reply)))
      end
    end)
  end

  defp text_only(text \\ "done"), do: fn _n -> {:text, text} end

  defp tool_then_text do
    fn
      1 -> :tool_call
      _ -> {:text, "done"}
    end
  end

  defp tool_call_json do
    %{
      "id" => "call_1",
      "type" => "function",
      "function" => %{
        "name" => "search_orders",
        "arguments" => ~s({"email":"a@b.c","status":"open"})
      }
    }
  end

  defp json_body(:tool_call) do
    completion(%{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call_json()]})
    |> put_in(["choices", Access.at(0), "finish_reason"], "tool_calls")
  end

  defp json_body({:text, text}), do: completion(%{"role" => "assistant", "content" => text})

  defp completion(message) do
    %{
      "id" => "chatcmpl-1",
      "object" => "chat.completion",
      "model" => "test-model",
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10}
    }
  end

  defp sse_body(:tool_call) do
    sse([
      %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [Map.put(tool_call_json(), "index", 0)]
            }
          }
        ]
      },
      %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]}
    ])
  end

  defp sse_body({:text, text}) do
    sse([
      %{"choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => text}}]},
      %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}
    ])
  end

  defp sse(chunks),
    do: Enum.map_join(chunks, "", &"data: #{JSON.encode!(&1)}\n\n") <> "data: [DONE]\n\n"

  defp next_request(tag \\ :request) do
    assert_receive {^tag, _n, body}, 2_000
    body
  end

  defp system_contents(body),
    do: for(%{"role" => "system", "content" => content} <- body["messages"], do: content)

  defp tool_by_name(body, name) do
    Enum.find(body["tools"] || [], &(&1["function"]["name"] == name)) ||
      flunk("no tool #{inspect(name)} in #{inspect(body["tools"])}")
  end

  # The search_orders tool as the provider received it: description and the
  # status parameter's description.
  defp search_text(body) do
    function = tool_by_name(body, "search_orders")["function"]
    {function["description"], function["parameters"]["properties"]["status"]["description"]}
  end

  # ── agent helpers ─────────────────────────────────────────────────────────

  defp base_agent(opts \\ []) do
    Agent.new(
      "custom:test-model",
      Keyword.merge([instructions: F.base_instructions(), tools: [F.search_tool()]], opts)
    )
  end

  defp profile(tag, agent \\ base_agent()), do: F.sealed(F.full_components(tag), agent)

  defp profiled_agent(tag, opts \\ []) do
    base_agent(
      Keyword.put(opts, :profile, profile(tag, base_agent(Keyword.delete(opts, :profile))))
    )
  end

  defp attach(events) do
    ref = :telemetry_test.attach_event_handlers(self(), events)
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  # ── entry points ──────────────────────────────────────────────────────────

  describe "run/3" do
    test "sends the profile's instructions, tool and parameter descriptions", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())
      agent = profiled_agent("P1")
      ref = attach([[:nous, :agent, :run, :start], [:nous, :agent, :run, :stop]])

      assert {:ok, %{output: "done"} = result} = AgentRunner.run(agent, "where is my order?")

      body = next_request()
      assert system_contents(body) == ["P1 INSTRUCTIONS"]
      assert search_text(body) == {"P1 TOOL DESCRIPTION", "P1 PARAM DESCRIPTION"}
      # Text only: the call contract is the live tool's.
      assert tool_by_name(body, "search_orders")["function"]["parameters"]["required"] == [
               "email"
             ]

      profile_id = Profile.applied_id(agent)
      assert_received {[:nous, :agent, :run, :start], ^ref, _, %{profile_id: ^profile_id}}
      assert_received {[:nous, :agent, :run, :stop], ^ref, _, %{profile_id: ^profile_id}}
      assert result.context.profile_id == profile_id
    end

    test "a run-level profile replaces the agent's, and nil restores the base text", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())
      agent = profiled_agent("P1")
      ref = attach([[:nous, :agent, :run, :start]])

      p2 = profile("P2")
      assert {:ok, _} = AgentRunner.run(agent, "hi", profile: p2)
      body = next_request()
      assert system_contents(body) == ["P2 INSTRUCTIONS"]
      assert search_text(body) == {"P2 TOOL DESCRIPTION", "P2 PARAM DESCRIPTION"}
      p2_id = p2.id
      assert_received {[:nous, :agent, :run, :start], ^ref, _, %{profile_id: ^p2_id}}

      assert {:ok, result} = AgentRunner.run(agent, "hi", profile: nil)
      body = next_request()
      assert system_contents(body) == [F.base_instructions()]
      assert search_text(body) == {F.base_description(), F.base_param()}
      assert_received {[:nous, :agent, :run, :start], ^ref, _, %{profile_id: nil}}
      assert result.context.profile_id == nil
    end

    test "an invalid run-level profile is an error before the run starts", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())
      ref = attach([[:nous, :agent, :run, :start]])

      # Sealed against other base text: stale for this agent.
      stale = profile("P", base_agent(instructions: "an older base"))

      assert {:error, %ProfileError{reason: :stale, key: "instructions"}} =
               AgentRunner.run(base_agent(), "hi", profile: stale)

      assert {:error, %ProfileError{reason: :not_a_profile}} =
               AgentRunner.run(base_agent(), "hi", profile: %{"instructions" => "x"})

      assert {:error, %ProfileError{reason: :stale}} =
               AgentRunner.run_stream(base_agent(), "hi", profile: stale)

      refute_received {:request, _, _}
      refute_received {[:nous, :agent, :run, :start], ^ref, _, _}
    end

    test "Nous.run(agent, messages: ...) builds the system prompt from the run's profile", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())

      assert {:ok, _} =
               Agent.run(profiled_agent("P1"),
                 messages: [Message.user("hi")],
                 profile: profile("P2")
               )

      body = next_request()
      assert system_contents(body) == ["P2 INSTRUCTIONS"]
      assert search_text(body) == {"P2 TOOL DESCRIPTION", "P2 PARAM DESCRIPTION"}
    end
  end

  describe "run_stream/3" do
    test "streams with the profile's text", %{bypass: bypass, test_pid: pid} do
      chat_endpoint(bypass, pid, text_only("streamed"))

      assert {:ok, stream} = AgentRunner.run_stream(profiled_agent("P1"), "hi")
      events = Enum.to_list(stream)
      assert {:complete, %{output: "streamed"}} = List.keyfind(events, :complete, 0)

      body = next_request()
      assert body["stream"] == true
      assert system_contents(body) == ["P1 INSTRUCTIONS"]
      assert search_text(body) == {"P1 TOOL DESCRIPTION", "P1 PARAM DESCRIPTION"}
    end
  end

  describe "agent shapes" do
    test "a ReAct agent appends the profile's instructions to its own prompt", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())

      react = fn opts ->
        Nous.ReActAgent.new(
          "custom:test-model",
          [instructions: F.base_instructions(), tools: [F.search_tool()]] ++ opts
        )
      end

      agent = react.(profile: F.sealed(F.full_components("P1"), react.([])))

      assert {:ok, _} = AgentRunner.run(agent, "hi")

      body = next_request()
      [system] = system_contents(body)
      assert system =~ "ADDITIONAL CONTEXT:\nP1 INSTRUCTIONS"
      refute system =~ F.base_instructions()
      assert search_text(body) == {"P1 TOOL DESCRIPTION", "P1 PARAM DESCRIPTION"}
      assert tool_by_name(body, "final_answer")
    end

    test "Code Mode renders the patched descriptions into run_code's SDK", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())

      assert {:ok, _} = AgentRunner.run(profiled_agent("P1", code_mode: :code), "hi")

      body = next_request()
      assert Enum.map(body["tools"], & &1["function"]["name"]) == ["run_code"]
      sdk = tool_by_name(body, "run_code")["function"]["description"]
      assert sdk =~ "P1 TOOL DESCRIPTION"
      assert sdk =~ "P1 PARAM DESCRIPTION"
      refute sdk =~ F.base_description()
    end

    test "an AgentServer session sends the profile's instructions and tools", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only("served"))
      pubsub = :"ProfileWireTest.PubSub#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      session_id = "profile-#{System.unique_integer([:positive])}"
      :ok = Nous.PubSub.subscribe(pubsub, Nous.PubSub.agent_topic(session_id))

      profile = profile("P1")

      server =
        start_supervised!(
          {AgentServer,
           session_id: session_id,
           pubsub: pubsub,
           inactivity_timeout: :infinity,
           agent_config: %{
             model: "custom:test-model",
             instructions: F.base_instructions(),
             tools: [F.search_tool()],
             profile: profile
           }}
        )

      for turn <- 1..2 do
        AgentServer.send_message(server, "question #{turn}")
        assert_receive {:agent_response, "served"}, 2_000

        body = next_request()
        assert system_contents(body) == ["P1 INSTRUCTIONS"]
        assert search_text(body) == {"P1 TOOL DESCRIPTION", "P1 PARAM DESCRIPTION"}
      end

      assert AgentServer.get_context(server).profile_id == profile.id
    end

    test "a sub-agent template runs with its own profile", %{bypass: bypass, test_pid: pid} do
      chat_endpoint(bypass, pid, text_only("child done"))

      template_base = fn ->
        Agent.new("custom:test-model", instructions: "TEMPLATE BASE", tools: [])
      end

      template_profile = F.sealed(%{"instructions" => "TEMPLATE PROFILE"}, template_base.())

      stale =
        F.sealed(
          %{"instructions" => "STALE"},
          Agent.new("custom:test-model", instructions: "older")
        )

      ctx =
        Context.new(
          deps: %{
            sub_agent_templates: %{
              "helper" => %{
                model: "custom:test-model",
                instructions: "TEMPLATE BASE",
                profile: template_profile
              },
              "broken" => %{
                model: "custom:test-model",
                instructions: "TEMPLATE BASE",
                profile: stale
              }
            }
          }
        )

      ctx = SubAgent.init(profiled_agent("PARENT"), ctx)

      result = SubAgent.delegate_task(ctx, %{"task" => "do it", "template" => "helper"})
      assert result.success == true
      assert system_contents(next_request()) == ["TEMPLATE PROFILE"]

      result = SubAgent.delegate_task(ctx, %{"task" => "do it", "template" => "broken"})
      assert result.success == false
      assert result.error =~ "Template profile rejected"
      assert result.error =~ "stale"
      refute_received {:request, _, _}
    end
  end

  describe "guards" do
    test "DecisionGuard sees the developer's description while the model sees the profile's", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, tool_then_text())

      guard =
        Hook.new(:pre_tool_use,
          name: "guard",
          handler:
            Decision.new(
              model: FakeDecisionBackend.model(fn _state -> 0.1 end, test_pid: pid),
              questions: [risky: [type: :noul, instructions: "Is untrusted_content risky?"]],
              bands: %{risky: {0.3, 0.7}}
            )
        )

      agent = profiled_agent("P1", hooks: [guard])

      assert {:ok, %{output: "done"}} =
               AgentRunner.run(agent, "find my order", deps: %{profile_test_pid: pid})

      assert search_text(next_request()) == {"P1 TOOL DESCRIPTION", "P1 PARAM DESCRIPTION"}
      assert_receive {:decision_state, state}
      assert state["tool"]["description"] == F.base_description()
      assert_receive {:tool_ran, %{"email" => "a@b.c"}}
    end
  end

  describe "sticky fallback" do
    setup %{test_pid: pid} do
      anth = Bypass.open()
      oai = Bypass.open()

      Bypass.stub(anth, "POST", "/v1/messages", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(pid, {:anthropic_hit, JSON.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(500, ~s({"type":"error","error":{"type":"api_error","message":"boom"}}))
      end)

      %{anth: anth, oai: oai}
    end

    defp fallback_agent(anth, oai, profile \\ nil) do
      Agent.new("anthropic:claude-sonnet-4-20250514",
        base_url: "http://localhost:#{anth.port}",
        api_key: "sk-ant-test",
        instructions: F.base_instructions(),
        tools: [F.search_tool()],
        fallback: [
          Nous.Model.parse("lmstudio:fake-model",
            base_url: "http://localhost:#{oai.port}/v1",
            api_key: "not-needed"
          )
        ],
        profile: profile
      )
    end

    for stream? <- [false, true] do
      test "the fallback provider gets the profile's text on every iteration (stream: #{stream?})",
           %{anth: anth, oai: oai, test_pid: pid} do
        chat_endpoint(oai, pid, tool_then_text(), :fallback)
        profile = F.sealed(F.full_components("P1"), fallback_agent(anth, oai))
        agent = fallback_agent(anth, oai, profile)

        assert {:ok, %{output: "done"}} =
                 AgentRunner.run(agent, "find my order",
                   stream: unquote(stream?),
                   deps: %{profile_test_pid: pid}
                 )

        assert_received {:anthropic_hit, primary}
        assert primary["system"] == "P1 INSTRUCTIONS"

        for _iteration <- 1..2 do
          body = next_request(:fallback)
          assert system_contents(body) == ["P1 INSTRUCTIONS"]
          assert search_text(body) == {"P1 TOOL DESCRIPTION", "P1 PARAM DESCRIPTION"}
        end
      end
    end
  end

  # ── continued conversations ───────────────────────────────────────────────

  describe "a continued context under another profile" do
    test "replaces the system message the runner wrote, logged, and emits :switched", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())
      agent = profiled_agent("P1")
      p1_id = Profile.applied_id(agent)

      assert {:ok, first} = AgentRunner.run(agent, "first")
      assert system_contents(next_request()) == ["P1 INSTRUCTIONS"]

      ref = attach([[:nous, :profile, :switched]])
      p2 = profile("P2")

      assert {:ok, second} = AgentRunner.run(agent, "second", context: first.context, profile: p2)

      body = next_request()
      assert system_contents(body) == ["P2 INSTRUCTIONS"]
      # The schema memo is per run: the tools switched with the prompt.
      assert search_text(body) == {"P2 TOOL DESCRIPTION", "P2 PARAM DESCRIPTION"}
      assert Enum.map(body["messages"], & &1["role"]) == ~w(system user assistant user)

      p2_id = p2.id

      assert_received {[:nous, :profile, :switched], ^ref, _,
                       %{profile_id: ^p2_id, previous_profile_id: ^p1_id, action: :replaced}}

      assert second.context.profile_id == p2_id
      assert second.context.system_prompt == "P2 INSTRUCTIONS"

      # The old prompt is shadowed, not destroyed: the log still holds it.
      assert inspect(Nous.Session.Log.events(second.context.log)) =~ "P1 INSTRUCTIONS"

      # Same profile again: nothing to switch.
      assert {:ok, _} = AgentRunner.run(agent, "third", context: second.context, profile: p2)
      next_request()
      refute_received {[:nous, :profile, :switched], ^ref, _, _}

      # Back to the base text through run_with_context/3.
      ctx = Context.add_message(second.context, Message.user("fourth"))
      assert {:ok, _} = AgentRunner.run_with_context(agent, ctx, profile: nil)
      body = next_request()
      assert system_contents(body) == [F.base_instructions()]
      assert search_text(body) == {F.base_description(), F.base_param()}
    end

    test "converts the tools its own run has, even under the same name and profile", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())

      assert {:ok, first} = AgentRunner.run(base_agent(), "first")
      assert search_text(next_request()) == {F.base_description(), F.base_param()}

      # Same tool name, same (absent) profile, new description: a schema memo
      # carried over from the previous run would resend the old one.
      edited = base_agent(tools: [F.search_tool(description: "EDITED DESCRIPTION")])
      assert {:ok, _} = AgentRunner.run(edited, "second", context: first.context)
      assert search_text(next_request()) == {"EDITED DESCRIPTION", F.base_param()}
    end

    test "a leading system message the caller kept is never replaced", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())
      agent = base_agent()

      assert {:ok, first} =
               Agent.run(agent,
                 messages: [Message.system("CALLER SYSTEM"), Message.user("hi")],
                 system_message: :caller
               )

      next_request()

      assert {:error, %ProfileError{reason: :system_message_diverged}} =
               AgentRunner.run(agent, "again", context: first.context, profile: profile("P1"))

      refute_received {:request, _, _}
    end

    test "a v3 session restored under a profile switches on its next run", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, text_only())

      assert {:ok, first} = AgentRunner.run(base_agent(), "first")
      next_request()

      # What an older release persisted: no profile_id.
      v3 = first.context |> Context.serialize() |> Map.delete(:profile_id) |> Map.put(:version, 3)
      assert {:ok, restored} = Context.deserialize(v3)
      assert restored.profile_id == nil

      agent = profiled_agent("P1")
      assert {:ok, second} = AgentRunner.run(agent, "second", context: restored)
      assert system_contents(next_request()) == ["P1 INSTRUCTIONS"]

      assert {:ok, round_trip} = second.context |> Context.serialize() |> Context.deserialize()
      assert round_trip.profile_id == Profile.applied_id(agent)
    end
  end
end
