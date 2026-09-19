defmodule Nous.Plugins.SubAgentTest do
  use ExUnit.Case, async: true

  alias Nous.{Agent, Message, Usage}
  alias Nous.Agent.Context
  alias Nous.Plugins.SubAgent

  # ---------------------------------------------------------------------------
  # Mock dispatchers
  # ---------------------------------------------------------------------------

  defmodule MockDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      user_content =
        messages
        |> Enum.find_value(fn
          %Message{role: :user, content: content} when is_binary(content) -> content
          _ -> nil
        end)

      text = "Mock response for: #{user_content || "unknown"}"

      legacy = %{
        parts: [{:text, text}],
        usage: %Usage{
          input_tokens: 10,
          output_tokens: 5,
          total_tokens: 15,
          tool_calls: 0,
          requests: 1
        },
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      }

      {:ok, Message.from_legacy(legacy)}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  defmodule FailingDispatcher do
    @moduledoc false

    def request(_model, _messages, _settings) do
      {:error, %Nous.Errors.ModelError{message: "LLM unavailable", provider: :test}}
    end

    def request_stream(_model, _messages, _settings), do: {:error, "unavailable"}
    def count_tokens(_messages), do: 50
  end

  defmodule SlowDispatcher do
    @moduledoc false

    def request(_model, _messages, _settings) do
      Process.sleep(:infinity)
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  defmodule PolicyProbeDispatcher do
    @moduledoc false
    # First model turn: call the probe tool; once a tool result exists: finish.
    # Stateless (keyed on the transcript), so `async: true` holds.
    def request(_model, messages, _settings) do
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, message([{:text, "done"}])}
      else
        {:ok, message([{:tool_call, %{id: "p1", name: "probe_policy", arguments: %{}}}])}
      end
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 10

    defp message(parts) do
      Message.from_legacy(%{
        parts: parts,
        usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      })
    end
  end

  setup do
    # Process-scoped: `spawn_agents` fans out through
    # `Task.Supervisor.async_stream_nolink`, which propagates `$callers`, so
    # the sub-agent tasks resolve the same stub without any global state.
    Nous.ModelDispatcher.put_dispatcher(MockDispatcher)

    templates = %{
      "researcher" =>
        Agent.new("openai:test-model",
          instructions: "You are a research specialist."
        ),
      "writer" =>
        Agent.new("openai:test-model",
          instructions: "You are a writer."
        )
    }

    agent = Agent.new("openai:test-model", instructions: "Coordinator")
    ctx = Context.new(deps: %{sub_agent_templates: templates})

    %{agent: agent, ctx: ctx, templates: templates}
  end

  # ===========================================================================
  # Plugin callback tests
  # ===========================================================================

  describe "init/2" do
    test "preserves existing templates in deps", %{agent: agent, ctx: ctx} do
      result = SubAgent.init(agent, ctx)

      assert result.deps[:sub_agent_templates] == ctx.deps[:sub_agent_templates]
    end

    test "sets default empty templates when none provided", %{agent: agent} do
      ctx = Context.new(deps: %{})
      result = SubAgent.init(agent, ctx)

      assert result.deps[:sub_agent_templates] == %{}
    end

    test "stores pubsub config from context", %{agent: agent} do
      ctx = Context.new(deps: %{}, pubsub: MyPubSub, pubsub_topic: "test:topic")
      result = SubAgent.init(agent, ctx)

      assert result.deps[:__sub_agent_pubsub__] == MyPubSub
      assert result.deps[:__sub_agent_pubsub_topic__] == "test:topic"
    end
  end

  describe "tools/2" do
    test "returns both delegate_task and spawn_agents tools", %{agent: agent, ctx: ctx} do
      tools = SubAgent.tools(agent, ctx)

      assert length(tools) == 2
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["delegate_task", "spawn_agents"]
    end

    test "both tools take context", %{agent: agent, ctx: ctx} do
      tools = SubAgent.tools(agent, ctx)

      for tool <- tools do
        assert tool.takes_ctx == true
      end
    end

    test "delegate_task has required 'task' parameter", %{agent: agent, ctx: ctx} do
      tools = SubAgent.tools(agent, ctx)
      tool = Enum.find(tools, &(&1.name == "delegate_task"))

      assert tool.parameters["required"] == ["task"]
    end

    test "spawn_agents has required 'tasks' parameter", %{agent: agent, ctx: ctx} do
      tools = SubAgent.tools(agent, ctx)
      tool = Enum.find(tools, &(&1.name == "spawn_agents"))

      assert tool.parameters["required"] == ["tasks"]
      assert tool.parameters["properties"]["tasks"]["type"] == "array"
    end
  end

  describe "system_prompt/2" do
    test "includes available template names", %{agent: agent, ctx: ctx} do
      ctx = SubAgent.init(agent, ctx)
      prompt = SubAgent.system_prompt(agent, ctx)

      assert prompt =~ "researcher"
      assert prompt =~ "writer"
    end

    test "mentions no templates when none configured", %{agent: agent} do
      ctx = Context.new(deps: %{})
      ctx = SubAgent.init(agent, ctx)
      prompt = SubAgent.system_prompt(agent, ctx)

      assert prompt =~ "No templates configured"
    end

    test "includes guidance on both tools", %{agent: agent, ctx: ctx} do
      ctx = SubAgent.init(agent, ctx)
      prompt = SubAgent.system_prompt(agent, ctx)

      assert prompt =~ "delegate_task"
      assert prompt =~ "spawn_agents"
      assert prompt =~ "Writing good sub-agent prompts"
    end
  end

  # ===========================================================================
  # delegate_task — single sub-agent
  # ===========================================================================

  describe "delegate_task/2 success" do
    test "runs a single sub-agent from template", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.delegate_task(ctx, %{
          "task" => "Research topic A",
          "template" => "researcher"
        })

      assert result.success == true
      assert is_binary(result.result)
      assert result.result =~ "Mock response for:"
      assert is_integer(result.tokens_used)
      assert result.tokens_used > 0
    end

    test "runs a single sub-agent with inline model", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.delegate_task(ctx, %{
          "task" => "Do something",
          "model" => "openai:test-model",
          "instructions" => "Be helpful"
        })

      assert result.success == true
      assert result.result =~ "Mock response for:"
    end
  end

  describe "delegate_task/2 errors" do
    test "returns error when template not found", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.delegate_task(ctx, %{
          "task" => "Do stuff",
          "template" => "nonexistent"
        })

      assert result.success == false
      assert result.error =~ "Template 'nonexistent' not found"
    end

    test "returns error when neither template nor model provided", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result = SubAgent.delegate_task(ctx, %{"task" => "Do stuff"})

      assert result.success == false
      assert result.error =~ "Either 'template' or 'model' must be provided"
    end

    test "handles LLM errors gracefully", %{ctx: ctx} do
      Nous.ModelDispatcher.put_dispatcher(FailingDispatcher)
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.delegate_task(ctx, %{
          "task" => "Will fail",
          "template" => "researcher"
        })

      assert result.success == false
      assert is_binary(result.error)
    end
  end

  # ===========================================================================
  # spawn_agents — parallel sub-agents
  # ===========================================================================

  describe "spawn_agents/2 success" do
    test "runs multiple tasks in parallel and returns results", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [
            %{"task" => "Research topic A", "template" => "researcher"},
            %{"task" => "Research topic B", "template" => "researcher"}
          ]
        })

      assert result.total == 2
      assert result.succeeded == 2
      assert result.failed == 0
      assert length(result.results) == 2

      for r <- result.results do
        assert r.success == true
        assert is_binary(r.output)
        assert r.output =~ "Mock response for:"
        assert is_integer(r.tokens_used)
        assert r.tokens_used > 0
      end
    end

    test "each result includes the original task prompt", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [
            %{"task" => "First task", "template" => "researcher"},
            %{"task" => "Second task", "template" => "writer"}
          ]
        })

      tasks = Enum.map(result.results, & &1.task)
      assert "First task" in tasks
      assert "Second task" in tasks
    end

    test "works with inline model config (no template)", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [
            %{
              "task" => "Do something",
              "model" => "openai:test-model",
              "instructions" => "Be helpful"
            }
          ]
        })

      assert result.total == 1
      assert result.succeeded == 1
      assert hd(result.results).success == true
    end

    test "handles single task", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [%{"task" => "Solo task", "template" => "researcher"}]
        })

      assert result.total == 1
      assert result.succeeded == 1
    end

    test "handles empty task list", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{"tasks" => []})

      assert result.total == 0
      assert result.succeeded == 0
      assert result.failed == 0
      assert result.results == []
    end
  end

  describe "spawn_agents/2 errors" do
    test "returns error when template not found", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [
            %{"task" => "Do stuff", "template" => "nonexistent"}
          ]
        })

      assert result.total == 1
      assert result.failed == 1

      [r] = result.results
      assert r.success == false
      assert r.error =~ "Template 'nonexistent' not found"
    end

    test "returns error when neither template nor model provided", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [%{"task" => "Do stuff"}]
        })

      assert result.total == 1
      assert result.failed == 1

      [r] = result.results
      assert r.success == false
      assert r.error =~ "Either 'template' or 'model' must be provided"
    end

    test "returns error for missing tasks key" do
      ctx = Context.new()

      result = SubAgent.spawn_agents(ctx, %{"not_tasks" => []})

      assert result == %{success: false, error: "Missing required 'tasks' array"}
    end

    test "handles LLM errors gracefully without crashing other tasks", %{ctx: ctx} do
      Nous.ModelDispatcher.put_dispatcher(FailingDispatcher)

      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [
            %{"task" => "Will fail", "template" => "researcher"},
            %{"task" => "Also will fail", "template" => "researcher"}
          ]
        })

      assert result.total == 2
      assert result.failed == 2

      for r <- result.results do
        assert r.success == false
        assert is_binary(r.error)
      end
    end

    test "partial failure: some tasks succeed, some fail", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [
            %{"task" => "Good task", "template" => "researcher"},
            %{"task" => "Bad task", "template" => "nonexistent"}
          ]
        })

      assert result.total == 2
      assert result.succeeded == 1
      assert result.failed == 1

      success = Enum.find(result.results, & &1.success)
      failure = Enum.find(result.results, &(!&1.success))

      assert success.task == "Good task"
      assert failure.task == "Bad task"
    end
  end

  # ===========================================================================
  # spawn_agents — concurrency and timeout
  # ===========================================================================

  describe "spawn_agents/2 concurrency" do
    test "respects parallel_max_concurrency config" do
      counter = :atomics.new(1, signed: true)
      max_seen = :atomics.new(1, signed: true)

      defmodule ConcurrencyTracker do
        @moduledoc false

        def request(_model, _messages, _settings) do
          {counter, max_seen} = :persistent_term.get({__MODULE__, :counters})

          current = :atomics.add_get(counter, 1, 1)
          loop_max(max_seen, current)

          Process.sleep(50)

          :atomics.sub(counter, 1, 1)

          legacy = %{
            parts: [{:text, "done"}],
            usage: %Usage{
              input_tokens: 1,
              output_tokens: 1,
              total_tokens: 2,
              tool_calls: 0,
              requests: 1
            },
            model_name: "test",
            timestamp: DateTime.utc_now()
          }

          {:ok, Message.from_legacy(legacy)}
        end

        # Compare-exchange retry loop: a plain get/put would let two tasks read
        # the same stale max and have the loser clobber the winner's higher
        # value, which is precisely the observation the `== 2` assertion below
        # depends on.
        defp loop_max(atomic, value) do
          current_max = :atomics.get(atomic, 1)

          if value > current_max do
            case :atomics.compare_exchange(atomic, 1, current_max, value) do
              :ok -> :ok
              _raced -> loop_max(atomic, value)
            end
          end
        end

        def request_stream(_model, _messages, _settings), do: {:ok, []}
        def count_tokens(_messages), do: 50
      end

      :persistent_term.put({ConcurrencyTracker, :counters}, {counter, max_seen})
      Nous.ModelDispatcher.put_dispatcher(ConcurrencyTracker)

      ctx =
        Context.new(
          deps: %{
            sub_agent_templates: %{
              "worker" => Agent.new("openai:test", instructions: "Work")
            },
            parallel_max_concurrency: 2
          }
        )

      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" =>
            Enum.map(1..6, fn i ->
              %{"task" => "Task #{i}", "template" => "worker"}
            end)
        })

      assert result.total == 6
      assert result.succeeded == 6

      # Exactly 2, not `<= 2`: the one-sided bound also passes when the
      # implementation regresses to fully sequential execution, which is the
      # only regression this test exists to catch. Six tasks at a limit of two,
      # each holding the counter for 50ms, deterministically reach the ceiling.
      observed_max = :atomics.get(max_seen, 1)
      assert observed_max == 2

      :persistent_term.erase({ConcurrencyTracker, :counters})
    end

    test "handles task timeout gracefully" do
      Nous.ModelDispatcher.put_dispatcher(SlowDispatcher)

      ctx =
        Context.new(
          deps: %{
            sub_agent_templates: %{
              "slow" => Agent.new("openai:test", instructions: "Be slow")
            },
            parallel_timeout: 200
          }
        )

      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [%{"task" => "This will timeout", "template" => "slow"}]
        })

      assert result.total == 1
      assert result.failed == 1

      [r] = result.results
      assert r.success == false
      assert r.error =~ "crashed"
    end
  end

  # ===========================================================================
  # Template resolution — Agent structs and config maps
  # ===========================================================================

  describe "template resolution" do
    test "works with Agent struct templates", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [%{"task" => "Test", "template" => "researcher"}]
        })

      assert result.succeeded == 1
    end

    test "works with legacy config map templates" do
      ctx =
        Context.new(
          deps: %{
            sub_agent_templates: %{
              "legacy" => %{
                model: "openai:test-model",
                instructions: "Legacy config map"
              }
            }
          }
        )

      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [%{"task" => "Test legacy", "template" => "legacy"}]
        })

      assert result.succeeded == 1
    end

    test "inline config uses default instructions when not provided", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [%{"task" => "Test", "model" => "openai:test-model"}]
        })

      assert result.succeeded == 1
    end

    test "lists available templates in error message", %{ctx: ctx} do
      ctx = SubAgent.init(%Agent{model: nil}, ctx)

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [%{"task" => "Test", "template" => "nope"}]
        })

      [r] = result.results
      assert r.error =~ "researcher"
      assert r.error =~ "writer"
    end
  end

  # ===========================================================================
  # Deps propagation
  # ===========================================================================

  describe "compute_sub_deps/1" do
    test "default: forwards NOTHING - secrets in parent deps stay with parent" do
      # Sub-agent prompts are LLM-controlled and tools see ctx.deps; the safe
      # default is to forward nothing. Callers must opt in explicitly.
      parent_deps = %{
        workspace_id: 42,
        database: :fake_db,
        api_key: "secret",
        sub_agent_templates: %{"t" => %{}},
        sub_agent_shared_deps: nil
      }

      assert SubAgent.compute_sub_deps(parent_deps) == %{}
    end

    test "explicit allowlist restricts to specified keys" do
      parent_deps = %{
        workspace_id: 42,
        database: :fake_db,
        api_key: "secret",
        sub_agent_shared_deps: [:workspace_id]
      }

      result = SubAgent.compute_sub_deps(parent_deps)

      assert result == %{workspace_id: 42}
    end

    test "empty allowlist returns empty map" do
      parent_deps = %{
        workspace_id: 42,
        database: :fake_db,
        sub_agent_shared_deps: []
      }

      result = SubAgent.compute_sub_deps(parent_deps)

      assert result == %{}
    end

    test ":all opts in to the prior behaviour - everything except plugin internals" do
      parent_deps = %{
        workspace_id: 42,
        database: :fake_db,
        sub_agent_templates: %{"t" => %{}},
        sub_agent_shared_deps: :all,
        parallel_max_concurrency: 3,
        parallel_timeout: 60_000,
        __sub_agent_pubsub__: SomePubSub,
        __sub_agent_pubsub_topic__: "topic:1"
      }

      assert SubAgent.compute_sub_deps(parent_deps) == %{
               workspace_id: 42,
               database: :fake_db
             }
    end

    test "raises on invalid value" do
      assert_raise ArgumentError, ~r/sub_agent_shared_deps/, fn ->
        SubAgent.compute_sub_deps(%{sub_agent_shared_deps: "not a list"})
      end
    end
  end

  # ===========================================================================
  # Confinement & execution-policy inheritance
  # ===========================================================================

  describe "confinement inheritance" do
    test "default forwards confinement keys but no data deps" do
      parent_deps = %{
        workspace_root: "/srv/ws/t1",
        session_id: "sess-1",
        api_key: "secret",
        database: :fake_db
      }

      assert SubAgent.compute_sub_deps(parent_deps) == %{
               workspace_root: "/srv/ws/t1",
               session_id: "sess-1"
             }
    end

    test "explicit share list still carries confinement keys" do
      parent_deps = %{
        workspace_root: "/srv/ws/t1",
        api_key: "secret",
        workspace_id: 42,
        sub_agent_shared_deps: [:workspace_id]
      }

      assert SubAgent.compute_sub_deps(parent_deps) == %{
               workspace_root: "/srv/ws/t1",
               workspace_id: 42
             }
    end

    test "sub-agent file tools stay rooted at the parent workspace, not File.cwd!()" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "sub_agent_confine_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      sub_deps = SubAgent.compute_sub_deps(%{workspace_root: tmp_dir, api_key: "secret"})
      assert sub_deps == %{workspace_root: tmp_dir}

      # PathGuard roots at the forwarded workspace: a file that IS readable
      # from cwd is rejected for the sub-agent.
      sub_ctx = Nous.RunContext.new(sub_deps)
      outside = Path.expand("mix.exs")
      assert File.exists?(outside)
      assert {:error, reason} = Nous.Tools.FileRead.execute(sub_ctx, %{"file_path" => outside})
      assert reason =~ "workspace"

      # ...while a file inside the forwarded workspace is readable.
      inside = Path.join(tmp_dir, "note.txt")
      File.write!(inside, "hello")
      assert {:ok, content} = Nous.Tools.FileRead.execute(sub_ctx, %{"file_path" => inside})
      assert content =~ "hello"
    end
  end

  defp probe_tool(test_pid, opts) do
    %Nous.Tool{
      name: "probe_policy",
      description: "Report the effective policy this tool runs under",
      parameters: %{"type" => "object", "properties" => %{}, "required" => []},
      takes_ctx: true,
      requires_approval: Keyword.get(opts, :requires_approval, false),
      function: fn ctx, _args ->
        send(
          test_pid,
          {:probe, Nous.Sandbox.Policy.resolve(ctx), Map.get(ctx, :permissions), ctx.deps}
        )

        %{ok: true}
      end
    }
  end

  defp parent_ctx(template, tmp_dir, opts) do
    deps = %{
      sub_agent_templates: %{"probe" => template},
      workspace_root: tmp_dir,
      api_key: "secret"
    }

    Nous.RunContext.new(deps, opts)
  end

  describe "execution policy inheritance" do
    setup do
      Nous.ModelDispatcher.put_dispatcher(PolicyProbeDispatcher)

      tmp_dir =
        Path.join(System.tmp_dir!(), "sub_agent_policy_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir}
    end

    test "sub-agent resolves the parent's sandbox, not the app default", %{tmp_dir: tmp_dir} do
      template = Agent.new("openai:test-model", tools: [probe_tool(self(), [])])
      parent_policy = Nous.Sandbox.Policy.new(mode: :read_only, workspace_root: tmp_dir)
      ctx = parent_ctx(template, tmp_dir, sandbox: parent_policy)

      result = SubAgent.delegate_task(ctx, %{"task" => "go", "template" => "probe"})

      assert result.success
      assert_receive {:probe, %Nous.Sandbox.Policy{mode: :read_only}, _perms, sub_deps}
      # Secrets in parent deps still do not travel with default shared deps.
      refute Map.has_key?(sub_deps, :api_key)
      assert sub_deps.workspace_root == tmp_dir
    end

    test "a template cannot widen the parent's sandbox", %{tmp_dir: tmp_dir} do
      template =
        Agent.new("openai:test-model",
          tools: [probe_tool(self(), [])],
          sandbox: :danger_full_access
        )

      parent_policy = Nous.Sandbox.Policy.new(mode: :read_only, workspace_root: tmp_dir)
      ctx = parent_ctx(template, tmp_dir, sandbox: parent_policy)

      result = SubAgent.delegate_task(ctx, %{"task" => "go", "template" => "probe"})

      assert result.success
      assert_receive {:probe, %Nous.Sandbox.Policy{} = policy, _perms, _sub_deps}
      assert policy.mode == :read_only

      assert policy.workspace_root ==
               Nous.Sandbox.Policy.new(workspace_root: tmp_dir).workspace_root
    end

    test "a stricter template sandbox wins over the parent's", %{tmp_dir: tmp_dir} do
      template =
        Agent.new("openai:test-model",
          tools: [probe_tool(self(), [])],
          sandbox: :read_only
        )

      parent_policy = Nous.Sandbox.Policy.new(mode: :workspace_write, workspace_root: tmp_dir)
      ctx = parent_ctx(template, tmp_dir, sandbox: parent_policy)

      result = SubAgent.delegate_task(ctx, %{"task" => "go", "template" => "probe"})

      assert result.success
      assert_receive {:probe, %Nous.Sandbox.Policy{mode: :read_only}, _perms, _sub_deps}
    end

    test "a template cannot re-root confinement when the parent has no session policy",
         %{tmp_dir: tmp_dir} do
      # Parent sets NO session sandbox (ctx.sandbox = nil — the default): its
      # effective policy resolves from deps[:workspace_root] + app config. A
      # template with its own sandbox (workspace_root defaulting to cwd) must
      # not become the sub-agent's session policy wholesale — that would
      # out-rank the forwarded :workspace_root dep and WIDEN confinement.
      template =
        Agent.new("openai:test-model",
          tools: [probe_tool(self(), [])],
          sandbox: :danger_full_access
        )

      ctx = parent_ctx(template, tmp_dir, [])

      result = SubAgent.delegate_task(ctx, %{"task" => "go", "template" => "probe"})

      assert result.success
      assert_receive {:probe, %Nous.Sandbox.Policy{} = policy, _perms, _sub_deps}

      # Root pinned to the parent's workspace, not the template's cwd default.
      assert policy.workspace_root ==
               Nous.Sandbox.Policy.new(workspace_root: tmp_dir).workspace_root

      refute policy.workspace_root ==
               Nous.Sandbox.Policy.new(workspace_root: File.cwd!()).workspace_root
    end

    test "the parent's permission policy threads into sub-agent tool contexts",
         %{tmp_dir: tmp_dir} do
      template = Agent.new("openai:test-model", tools: [probe_tool(self(), [])])

      parent_permissions =
        Nous.Permissions.build_policy(deny: ["bash"], approval_required: ["file_write"])

      ctx = parent_ctx(template, tmp_dir, permissions: parent_permissions)

      result = SubAgent.delegate_task(ctx, %{"task" => "go", "template" => "probe"})

      assert result.success
      # The sub-agent's tool ctx carries the parent's policy: if either the
      # strictest/2 inheritance or the runner's :permissions attachment were
      # dropped, this would be nil (the template declares no policy).
      assert_receive {:probe, _policy, %Nous.Permissions.Policy{} = perms, _sub_deps}
      assert Nous.Permissions.blocked?(perms, "bash")
      assert Nous.Permissions.requires_approval?(perms, "file_write")
    end

    test "approval-gated tools in a sub-agent still fail closed without a handler",
         %{tmp_dir: tmp_dir} do
      template =
        Agent.new("openai:test-model",
          tools: [probe_tool(self(), requires_approval: true)]
        )

      ctx = parent_ctx(template, tmp_dir, [])

      result = SubAgent.delegate_task(ctx, %{"task" => "go", "template" => "probe"})

      # The run completes (the model gets a rejection tool-result and finishes)
      # but the gated tool must never have executed.
      assert result.success
      refute_received {:probe, _, _, _}
    end

    test "the parent's approval handler threads into sub-agent runs", %{tmp_dir: tmp_dir} do
      test_pid = self()

      handler = fn %{name: name} ->
        send(test_pid, {:approval_requested, name})
        :approve
      end

      template =
        Agent.new("openai:test-model",
          tools: [probe_tool(self(), requires_approval: true)]
        )

      ctx = parent_ctx(template, tmp_dir, approval_handler: handler)

      result = SubAgent.delegate_task(ctx, %{"task" => "go", "template" => "probe"})

      assert result.success
      assert_receive {:approval_requested, "probe_policy"}
      assert_receive {:probe, _policy, _perms, _sub_deps}
    end
  end

  # ===========================================================================
  # Integration with Plugin system
  # ===========================================================================

  describe "Plugin behaviour integration" do
    test "works with Plugin.run_init/3", %{agent: agent, ctx: ctx} do
      result = Nous.Plugin.run_init([SubAgent], agent, ctx)

      assert result.deps[:sub_agent_templates] == ctx.deps[:sub_agent_templates]
    end

    test "works with Plugin.collect_tools/3", %{agent: agent, ctx: ctx} do
      tools = Nous.Plugin.collect_tools([SubAgent], agent, ctx)

      assert length(tools) == 2
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["delegate_task", "spawn_agents"]
    end

    test "works with Plugin.collect_system_prompts/3", %{agent: agent, ctx: ctx} do
      prompt = Nous.Plugin.collect_system_prompts([SubAgent], agent, ctx)

      assert is_binary(prompt)
      assert prompt =~ "Sub-Agents"
    end
  end
end
