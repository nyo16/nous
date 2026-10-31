defmodule Nous.Persistence.DepCredentialScrubTest do
  # Issue #87: AgentServer auto-saves the context after every response into
  # the :public ETS persistence table. Credentials nested in deps (the
  # documented memory_config / kb_config shapes, `%Nous.Model{}` in
  # sub_agent_templates, `%Nous.DecisionModel{}` opts) must not be written.
  #
  # async: false — AgentServer runs happen in tasks spawned from the server, so
  # the provider endpoint is configured through the environment.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentServer, DecisionModel, Model, Tool}
  alias Nous.Agent.Context
  alias Nous.Persistence.ETS, as: PersistenceETS

  @moduletag :capture_log

  @embed_key "sk-embed-SECRET-87a"
  @kb_key "sk-kb-SECRET-87b"
  @template_key "sk-template-SECRET-87c"
  @gateway_key "gw-SECRET-87d"
  @decision_key "sk-decision-SECRET-87e"
  @secrets [@embed_key, @kb_key, @template_key, @gateway_key, @decision_key]

  # Token *counts*, not credentials: they must survive the scrub.
  @token_settings %{max_tokens: 256, input_tokens: 10, token_count: 3, tokenizer: "cl100k"}

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

    PersistenceETS.clear()
    %{bypass: bypass, test_pid: self()}
  end

  # The exact shapes documented in the Memory and KnowledgeBase moduledocs,
  # plus a sub-agent template and a decision model carrying credentials.
  defp secret_deps do
    %{
      memory_config: %{
        store: Nous.Memory.Store.ETS,
        embedding: Nous.Memory.Embedding.OpenAI,
        embedding_opts: %{api_key: @embed_key}
      },
      kb_config: %{
        store: Nous.KnowledgeBase.Store.ETS,
        kb_id: "my_kb",
        embedding: Nous.Memory.Embedding.OpenAI,
        embedding_opts: %{api_key: @kb_key}
      },
      sub_agent_templates: %{
        "researcher" =>
          Agent.new("openai:gpt-4o-mini",
            api_key: @template_key,
            headers: [{"cf-aig-gateway-id", "gw-1"}, {"helicone-auth", @gateway_key}],
            instructions: "You are a research specialist.",
            model_settings: @token_settings
          )
      },
      guard_model: %DecisionModel{
        backend: Nous.DecisionModel.Backend.OpenAIDecisions,
        model: "gpt-6-luna",
        opts: [base_url: "https://decisions.example.com", api_key: @decision_key, timeout: 5_000]
      },
      user_id: "u-87"
    }
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
      "id" => "chatcmpl-87",
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
            "id" => "call_87",
            "type" => "function",
            "function" => %{"name" => name, "arguments" => "{}"}
          }
        ]
      },
      "tool_calls"
    )
  end

  # Reports the embedding key the tool sees in its run-time deps.
  defp deps_probe_tool(test_pid) do
    Tool.from_function(
      fn ctx, _args ->
        send(
          test_pid,
          {:tool_saw_key, get_in(ctx.deps, [:memory_config, :embedding_opts, :api_key])}
        )

        "checked"
      end,
      name: "check_deps",
      description: "Checks the configured deps"
    )
  end

  defp start_server(session_id, deps, tools) do
    start_supervised!(
      Supervisor.child_spec(
        {AgentServer,
         [
           session_id: session_id,
           agent_config: %{model: "custom:test-model", instructions: "", tools: tools, deps: deps},
           persistence: PersistenceETS,
           pubsub: nil,
           inactivity_timeout: :infinity
         ]},
        id: {AgentServer, make_ref()},
        restart: :temporary
      )
    )
  end

  # The raw persisted term, read back through the backend.
  defp wait_for_persisted(session_id, expected_reply) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      with {:ok, data} <- PersistenceETS.load(session_id),
           {:ok, ctx} <- Context.deserialize(data),
           true <- Enum.any?(ctx.messages, &(&1.content == expected_reply)) do
        {:halt, data}
      else
        _ ->
          Process.sleep(20)
          {:cont, nil}
      end
    end) || flunk("context with #{inspect(expected_reply)} was never persisted")
  end

  # Searches the external term format, so it sees through `Inspect` impls
  # (`%Nous.Model{}` hides `api_key`/`headers`) and any nesting.
  defp leaked_secrets(term) do
    blob = :erlang.term_to_binary(term)
    Enum.filter(@secrets, &(:binary.match(blob, &1) != :nomatch))
  end

  describe "AgentServer auto-save after a response" do
    test "persists no nested credential, and a restored run still works", %{
      bypass: bypass,
      test_pid: pid
    } do
      chat_endpoint(bypass, pid, fn
        1 -> text_reply("first answer")
        2 -> tool_call_reply("check_deps")
        _ -> text_reply("second answer")
      end)

      session_id = "cred-scrub-#{System.unique_integer([:positive])}"
      server = start_server(session_id, secret_deps(), [deps_probe_tool(pid)])

      # Control: the live context does hold every secret, so the search below
      # is capable of finding them.
      assert leaked_secrets(AgentServer.get_context(server).deps) == @secrets

      AgentServer.send_message(server, "first question")
      assert_receive {:chat_request, 1, _}, 2_000

      data = wait_for_persisted(session_id, "first answer")
      assert leaked_secrets(data) == []

      # Non-secret config survives the scrub.
      assert data.deps.user_id == "u-87"
      assert data.deps.memory_config.store == Nous.Memory.Store.ETS
      assert data.deps.kb_config.kb_id == "my_kb"

      template = data.deps.sub_agent_templates["researcher"]

      assert %Model{provider: :openai, model: "gpt-4o-mini", api_key: nil, headers: []} =
               template.model

      assert template.model_settings == @token_settings

      assert data.deps.guard_model.opts == [
               base_url: "https://decisions.example.com",
               timeout: 5_000
             ]

      GenServer.stop(server)

      # Restore: the app re-supplies deps at run time and the run sees them.
      restored = start_server(session_id, secret_deps(), [deps_probe_tool(pid)])
      AgentServer.send_message(restored, "second question")

      assert_receive {:chat_request, 2, body}, 2_000
      assert Enum.any?(body["messages"], &(&1["content"] == "first question"))
      assert_receive {:tool_saw_key, @embed_key}, 2_000
      assert_receive {:chat_request, 3, _}, 2_000

      # The post-restore save is scrubbed too.
      assert session_id |> wait_for_persisted("second answer") |> leaked_secrets() == []
    end

    test "a restore without re-supplied deps still runs", %{bypass: bypass, test_pid: pid} do
      chat_endpoint(bypass, pid, fn
        1 -> text_reply("first answer")
        2 -> tool_call_reply("check_deps")
        _ -> text_reply("second answer")
      end)

      session_id = "cred-scrub-bare-#{System.unique_integer([:positive])}"
      server = start_server(session_id, secret_deps(), [deps_probe_tool(pid)])
      AgentServer.send_message(server, "first question")
      wait_for_persisted(session_id, "first answer")
      GenServer.stop(server)

      # Only the scrubbed persisted deps are available: the nested key is gone
      # and nothing crashes on its absence.
      restored = start_server(session_id, %{}, [deps_probe_tool(pid)])
      assert AgentServer.get_context(restored).deps.memory_config.embedding_opts == %{}

      AgentServer.send_message(restored, "second question")
      assert_receive {:tool_saw_key, nil}, 2_000
      assert wait_for_persisted(session_id, "second answer")
    end
  end

  describe "Context.serialize/1 deps scrub" do
    test "keeps top-level behaviour: credential keys, funs and pids dropped" do
      ctx =
        Context.new(
          deps: %{
            :database => SomeRepo,
            :api_key => "sk-top",
            "AUTH_TOKEN" => "t0ken",
            :callback => fn -> :ok end,
            :owner => self(),
            :region => "us-east-1"
          }
        )

      assert Context.serialize(ctx).deps == %{database: SomeRepo, region: "us-east-1"}
    end

    test "drops credential-shaped keys at any depth and keeps everything else" do
      ctx =
        Context.new(
          deps: %{
            http: [
              headers: [{"X-Api-Key", "k1"}, {"accept", "json"}],
              client_secret: "k2",
              retries: 3
            ],
            nested: %{"Password" => "k3", "level" => %{token: "k4", ok: {:tag, "keep"}}},
            tags: MapSet.new(["alpha", "beta"])
          }
        )

      deps = Context.serialize(ctx).deps

      assert deps.http == [headers: [{"accept", "json"}], retries: 3]
      assert deps.nested == %{"level" => %{ok: {:tag, "keep"}}}
      assert deps.tags == MapSet.new(["alpha", "beta"])
    end

    test "matches key segments: credentials go, token counts stay" do
      ctx =
        Context.new(
          deps: %{
            max_tokens: 1024,
            model_settings: @token_settings,
            llm: [token_limit: 9, token_budget: 8, refresh_token: "k1"],
            gateway: %{
              "x-api-key" => "k2",
              "Authorization" => "k3",
              "accessToken" => "k4",
              :client_secret => "k5",
              :secrets => %{db: "k6"},
              "tokens" => 7
            }
          }
        )

      assert {:ok, restored} = ctx |> Context.serialize() |> Context.deserialize()

      assert restored.deps == %{
               max_tokens: 1024,
               model_settings: @token_settings,
               llm: [token_limit: 9, token_budget: 8],
               gateway: %{"tokens" => 7}
             }
    end

    test "Req auth options, gateway auth headers, cookies and *_key secrets go" do
      client = Req.new(base_url: "https://api.example", auth: {:bearer, "k7"})

      ctx =
        Context.new(
          deps: %{
            http: [auth: {:bearer, "k8"}, base_url: "https://api.example"],
            client: client,
            headers: [{"helicone-auth", "Bearer k9"}, {"cookie", "s=k10"}, {"accept", "*/*"}],
            crypto: %{signing_key: "k11", pwd: "k12", passphrase: "k13", key_count: 2},
            author: "Ada",
            oauth_scopes: ["read"]
          }
        )

      assert {:ok, restored} = ctx |> Context.serialize() |> Context.deserialize()

      refute inspect(restored.deps) =~ ~r/k(7|8|9|10|11|12|13)\b/
      assert restored.deps.http == [base_url: "https://api.example"]
      assert restored.deps.headers == [{"accept", "*/*"}]
      assert restored.deps.crypto == %{key_count: 2}
      assert restored.deps.author == "Ada"
      assert restored.deps.oauth_scopes == ["read"]
    end

    test "a scrubbed context round-trips through deserialize/1" do
      ctx = Context.new(deps: secret_deps())

      assert {:ok, restored} = ctx |> Context.serialize() |> Context.deserialize()
      assert leaked_secrets(restored) == []
      assert restored.deps.memory_config.embedding_opts == %{}
    end
  end
end
