defmodule Nous.Teams.RoleEnforcementTest do
  # Request-path tests for #85: a `Nous.Teams.Role` passed to
  # `Coordinator.spawn_agent/4` must be enforced on the spawned AgentServer.
  # Every assertion is on what reached the wire (the chat request on Bypass),
  # whether a tool function actually ran, or how many requests a run made —
  # never on a helper's return value.
  #
  # async: false — the AgentServer runs in its own process tree, so the
  # provider endpoint (and Code Mode runtime) are configured through the
  # application/OS environment rather than the process-scoped dispatcher seam.
  use ExUnit.Case, async: false

  alias Nous.Teams.{Coordinator, Role}
  alias Nous.Tool

  @moduletag :capture_log

  # Code Mode provider stand-in: the "program" calls each named binding and
  # reports every outcome back to the test.
  defmodule BindingProbeRuntime do
    @moduledoc false
    @behaviour Nous.CodeRuntime

    alias Nous.CodeRuntime.Result

    @impl true
    def language(_config), do: "javascript"

    @impl true
    def isolation(_config), do: "none — test double"

    @impl true
    def start_run(request, config) do
      [binding] = request.bindings

      outcomes =
        Map.new(Keyword.fetch!(config, :call), fn name ->
          {name, binding.functions[name].(%{})}
        end)

      send(Keyword.fetch!(config, :test_pid), {:sub_calls, outcomes})

      ref = make_ref()
      send(request.owner, {:code_run, ref, Result.ok(inspect(outcomes))})
      {:ok, ref}
    end

    @impl true
    def cancel(_ref, _reason), do: :ok
  end

  setup do
    Nous.ModelDispatcher.put_dispatcher(nil)
    bypass = Bypass.open()

    previous_url = System.get_env("CUSTOM_BASE_URL")
    previous_config = Application.get_env(:nous, :custom)
    System.put_env("CUSTOM_BASE_URL", "http://localhost:#{bypass.port}/v1")
    Application.put_env(:nous, :custom, allow_private_hosts: true)

    on_exit(fn ->
      Application.delete_env(:nous, :code_mode)
      Application.delete_env(:nous, :code_runtime)

      if previous_url,
        do: System.put_env("CUSTOM_BASE_URL", previous_url),
        else: System.delete_env("CUSTOM_BASE_URL")

      if previous_config,
        do: Application.put_env(:nous, :custom, previous_config),
        else: Application.delete_env(:nous, :custom)
    end)

    team_id = "role_enf_#{System.unique_integer([:positive])}"
    agent_sup = :"role_enf_agents_#{team_id}"
    shared_state = :"role_enf_state_#{team_id}"
    pubsub = :"role_enf_pubsub_#{team_id}"

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: agent_sup})

    start_supervised!({Nous.Teams.SharedState, team_id: team_id, name: shared_state},
      id: :shared_state
    )

    start_supervised!({Phoenix.PubSub, name: pubsub}, id: :pubsub)

    coordinator =
      start_supervised!(
        {Coordinator,
         team_id: team_id,
         team_name: "Role Team",
         pubsub: pubsub,
         agent_supervisor: agent_sup,
         shared_state: shared_state},
        id: :coordinator
      )

    %{bypass: bypass, coordinator: coordinator, pubsub: pubsub, team_id: team_id}
  end

  # ── wire helpers ──────────────────────────────────────────────────────────

  defp chat_endpoint(bypass, responder) do
    test_pid = self()
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

  defp tool_calls_reply(calls) do
    completion(
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" =>
          calls
          |> Enum.with_index(1)
          |> Enum.map(fn {{name, args}, i} ->
            %{
              "id" => "call_#{i}",
              "type" => "function",
              "function" => %{"name" => name, "arguments" => JSON.encode!(args)}
            }
          end)
      },
      "tool_calls"
    )
  end

  defp calls_then_text(calls) do
    fn
      1 -> tool_calls_reply(Enum.map(calls, &{&1, %{}}))
      _ -> text_reply("done")
    end
  end

  defp request_tool_names(body) do
    body |> Map.get("tools", []) |> Enum.map(& &1["function"]["name"]) |> Enum.sort()
  end

  defp system_text(body) do
    body["messages"]
    |> Enum.filter(&(&1["role"] == "system"))
    |> Enum.map_join("\n", & &1["content"])
  end

  defp tool_results(body) do
    body["messages"]
    |> Enum.filter(&(&1["role"] == "tool"))
    |> Map.new(&{&1["tool_call_id"], &1["content"]})
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:chat_request, n, body} -> drain_requests([{n, body} | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  # ── agent helpers ─────────────────────────────────────────────────────────

  defp probe_tool(name) do
    test_pid = self()

    Tool.from_function(
      fn _ctx, _args ->
        send(test_pid, {:tool_ran, name})
        "#{name} RAN"
      end,
      name: name,
      description: "The #{name} tool"
    )
  end

  defp spawn_and_ask(ctx, name, config, opts) do
    session_id = "team:#{ctx.team_id}:#{name}"
    :ok = Nous.PubSub.subscribe(ctx.pubsub, Nous.PubSub.agent_topic(session_id))

    config = Map.merge(%{model: "custom:test-model", instructions: "AGENT INSTRUCTIONS"}, config)
    {:ok, pid} = Coordinator.spawn_agent(ctx.coordinator, name, config, opts)

    Nous.AgentServer.send_message(pid, "go")
    pid
  end

  # ── tests ─────────────────────────────────────────────────────────────────

  describe "Role.researcher/0 (allowlist)" do
    test "a non-allowlisted tool is absent from the request and a call to it never runs",
         ctx do
      chat_endpoint(ctx.bypass, calls_then_text(["delete_file", "file_read"]))

      spawn_and_ask(
        ctx,
        "rita",
        %{tools: [probe_tool("delete_file"), probe_tool("file_read")]},
        role: Role.researcher()
      )

      assert_receive {:agent_complete, _}, 5_000
      [{1, first}, {2, second}] = drain_requests()

      assert request_tool_names(first) == ["file_read"]

      # Control: the allowlisted tool in the same response really runs.
      assert_received {:tool_ran, "file_read"}
      refute_received {:tool_ran, "delete_file"}

      results = tool_results(second)
      assert results["call_2"] =~ "file_read RAN"
      refute results["call_1"] =~ "delete_file RAN"
    end
  end

  describe "Role.coder/0 (denylist)" do
    test "denied tools are absent from the request and refused when called", ctx do
      chat_endpoint(ctx.bypass, calls_then_text(["delete_file", "drop_table", "read_file"]))

      spawn_and_ask(
        ctx,
        "cody",
        %{tools: [probe_tool("delete_file"), probe_tool("drop_table"), probe_tool("read_file")]},
        role: Role.coder()
      )

      assert_receive {:agent_complete, _}, 5_000
      [{1, first}, {2, _second}] = drain_requests()

      assert request_tool_names(first) == ["read_file"]
      assert_received {:tool_ran, "read_file"}
      refute_received {:tool_ran, "delete_file"}
      refute_received {:tool_ran, "drop_table"}
    end

    test "the role narrows, never widens, a policy already on the agent config", ctx do
      chat_endpoint(ctx.bypass, calls_then_text(["web_fetch"]))

      spawn_and_ask(
        ctx,
        "cody2",
        %{
          tools: [probe_tool("web_fetch"), probe_tool("delete_file"), probe_tool("read_file")],
          permissions: Nous.Permissions.build_policy(deny: ["web_fetch"])
        },
        role: Role.coder()
      )

      assert_receive {:agent_complete, _}, 5_000
      [{1, first} | _] = drain_requests()

      assert request_tool_names(first) == ["read_file"]
      refute_received {:tool_ran, "web_fetch"}
    end
  end

  describe "Code Mode bindings" do
    test "a program's call to a tool the role denies is refused without running it", ctx do
      Application.put_env(:nous, :code_mode, :code)

      Application.put_env(
        :nous,
        :code_runtime,
        {BindingProbeRuntime, test_pid: self(), call: ["delete_file", "file_read"]}
      )

      chat_endpoint(ctx.bypass, fn
        1 ->
          tool_calls_reply([
            {"run_code", %{"code" => "tools.delete_file({})", "description" => "probe"}}
          ])

        _ ->
          text_reply("done")
      end)

      spawn_and_ask(
        ctx,
        "rowan",
        %{tools: [probe_tool("delete_file"), probe_tool("file_read")]},
        role: Role.researcher()
      )

      assert_receive {:agent_complete, _}, 5_000
      assert_received {:sub_calls, outcomes}

      # Control: the allowlisted tool runs from inside the program.
      assert {:ok, "file_read RAN"} = outcomes["file_read"]
      assert_received {:tool_ran, "file_read"}

      assert {:error, _} = outcomes["delete_file"]
      refute_received {:tool_ran, "delete_file"}
    end
  end

  describe "system_prompt" do
    test "is prepended to the agent's instructions in the request", ctx do
      chat_endpoint(ctx.bypass, fn _ -> text_reply("ok") end)

      role = Role.new(name: :auditor, system_prompt: "ROLE PROMPT: audit everything.")
      spawn_and_ask(ctx, "aud", %{}, role: role)

      assert_receive {:agent_complete, _}, 5_000
      [{1, body}] = drain_requests()

      system = system_text(body)
      assert system =~ "ROLE PROMPT: audit everything."
      assert system =~ "AGENT INSTRUCTIONS"

      {role_at, _} = :binary.match(system, "ROLE PROMPT")
      {agent_at, _} = :binary.match(system, "AGENT INSTRUCTIONS")
      assert role_at < agent_at
    end
  end

  describe "max_iterations" do
    test "caps the run", ctx do
      # The model never stops calling a tool; only the iteration cap ends it.
      chat_endpoint(ctx.bypass, fn _ -> tool_calls_reply([{"read_file", %{}}]) end)

      role = Role.new(name: :brief, max_iterations: 2)
      spawn_and_ask(ctx, "brie", %{tools: [probe_tool("read_file")]}, role: role)

      assert_receive {:agent_error, _}, 5_000
      assert length(drain_requests()) == 2
    end
  end

  describe "no role" do
    test "behaviour is unchanged: every tool is offered and callable", ctx do
      chat_endpoint(ctx.bypass, calls_then_text(["delete_file"]))

      spawn_and_ask(
        ctx,
        "free",
        %{tools: [probe_tool("delete_file"), probe_tool("read_file")]},
        []
      )

      assert_receive {:agent_complete, _}, 5_000
      [{1, first}, {2, second}] = drain_requests()

      assert request_tool_names(first) == ["delete_file", "read_file"]
      assert system_text(first) =~ "AGENT INSTRUCTIONS"
      assert_received {:tool_ran, "delete_file"}
      assert tool_results(second)["call_1"] =~ "delete_file RAN"
    end
  end

  test "an invalid role fails closed instead of spawning an unrestricted agent", ctx do
    assert {:error, {:invalid_role, :researcher}} =
             Coordinator.spawn_agent(
               ctx.coordinator,
               "bad",
               %{model: "custom:test-model", tools: [probe_tool("delete_file")]},
               role: :researcher
             )

    assert Coordinator.list_agents(ctx.coordinator) == []
  end

  test "a malformed role struct is refused and the coordinator survives", ctx do
    bad = Role.new(name: :bad, allowed_tools: "file_read")

    assert {:error, {:invalid_role, ^bad}} =
             Coordinator.spawn_agent(ctx.coordinator, "bad", %{model: "custom:test-model"},
               role: bad
             )

    assert {:error, {:invalid_role, _}} =
             Coordinator.spawn_agent(ctx.coordinator, "bad", %{model: "custom:test-model"},
               role: Role.new(name: :bad, max_iterations: 0)
             )

    assert {:error, {:invalid_permissions, :strict}} =
             Coordinator.spawn_agent(
               ctx.coordinator,
               "bad",
               %{model: "custom:test-model", permissions: :strict},
               role: Role.coder()
             )

    assert Process.alive?(ctx.coordinator)
    assert Coordinator.list_agents(ctx.coordinator) == []
  end
end
