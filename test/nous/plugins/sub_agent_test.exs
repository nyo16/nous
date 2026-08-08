defmodule Nous.Plugins.SubAgentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

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

  # Calls file_read once for the path named in the task prompt, then answers
  # with the tool's own output — so a sub-agent's view of the workspace jail
  # comes back through delegate_task/spawn_agents rather than being inspected
  # from outside.
  defmodule FileReadingDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      case Enum.find(messages, &(&1.role == :tool)) do
        nil ->
          {:ok,
           response([
             {:tool_call,
              %{id: "c1", name: "file_read", arguments: %{"file_path" => asked_path(messages)}}}
           ])}

        tool_message ->
          {:ok, response([{:text, to_string(tool_message.content)}])}
      end
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 10

    defp asked_path(messages) do
      Enum.find_value(messages, fn
        %Message{role: :user, content: "read " <> path} -> path
        _ -> nil
      end)
    end

    defp response(parts) do
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

  # ===========================================================================
  # Workspace confinement
  # ===========================================================================

  # Every assertion below reads the sub-agent's REAL file_read output, taken
  # from the running child through delegate_task/spawn_agents. Asserting the
  # deps map instead would certify nothing: the jail is only worth what the
  # callsite enforces.
  defp delegate_read(deps, path, templates) do
    ctx = Context.new(deps: Map.put(deps, :sub_agent_templates, templates))

    SubAgent.delegate_task(ctx, %{"task" => "read #{path}", "template" => "reader"})
  end

  describe "workspace confinement" do
    setup do
      Nous.ModelDispatcher.put_dispatcher(FileReadingDispatcher)

      base = Path.join(System.tmp_dir!(), "sub_agent_ws_#{System.unique_integer([:positive])}")
      parent_root = Path.join(base, "parent")
      inner = Path.join(parent_root, "inner")
      File.mkdir_p!(inner)
      File.write!(Path.join(base, "outside.txt"), "OUTSIDE")
      File.write!(Path.join(parent_root, "parent.txt"), "PARENT")
      File.write!(Path.join(inner, "inner.txt"), "INNER")
      on_exit(fn -> File.rm_rf!(base) end)

      templates = %{
        "reader" =>
          Agent.new("openai:test-model",
            instructions: "Read the file you are asked for.",
            tools: [Nous.Tools.FileRead]
          )
      }

      %{base: base, parent_root: parent_root, inner: inner, templates: templates}
    end

    test "a sub-agent cannot read outside its parent's root, nor fall back to the cwd",
         %{parent_root: parent_root, templates: templates} do
      # The cwd is where an uninherited jail lands, so a cwd file is the probe
      # that separates "confined to the parent" from "confined to nothing".
      cwd_file = Path.join(File.cwd!(), "mix.exs")

      result = delegate_read(%{workspace_root: parent_root}, cwd_file, templates)

      assert result.success
      assert result.result =~ "escapes the workspace root"
      assert result.result =~ parent_root
      refute result.result =~ "defmodule Nous.MixProject"
    end

    test "control: the same read succeeds when the parent has no root of its own",
         %{templates: templates} do
      # Exactly the state a child used to inherit. If this ever stops reading
      # mix.exs the probe above has gone blind and proves nothing.
      cwd_file = Path.join(File.cwd!(), "mix.exs")

      result = delegate_read(%{}, cwd_file, templates)

      assert result.result =~ "defmodule Nous.MixProject"
    end

    test "a sub-agent still reads inside the inherited root", %{
      parent_root: parent_root,
      templates: templates
    } do
      result =
        delegate_read(
          %{workspace_root: parent_root},
          Path.join(parent_root, "parent.txt"),
          templates
        )

      assert result.result =~ "PARENT"
    end

    test "an explicitly narrower :sub_agent_workspace_root is kept, not overwritten", %{
      parent_root: parent_root,
      inner: inner,
      templates: templates
    } do
      deps = %{workspace_root: parent_root, sub_agent_workspace_root: inner}

      # Clamped, not overwritten: the child keeps the narrower root, so a file
      # its parent may read is out of reach.
      refused = delegate_read(deps, Path.join(parent_root, "parent.txt"), templates)
      assert refused.result =~ "escapes the workspace root"
      assert refused.result =~ inner

      allowed = delegate_read(deps, Path.join(inner, "inner.txt"), templates)
      assert allowed.result =~ "INNER"
    end

    test "a :sub_agent_workspace_root wider than the parent's is clamped to the parent's", %{
      base: base,
      parent_root: parent_root,
      templates: templates
    } do
      deps = %{workspace_root: parent_root, sub_agent_workspace_root: base}

      {result, log} =
        with_log(fn -> delegate_read(deps, Path.join(base, "outside.txt"), templates) end)

      assert result.result =~ "escapes the workspace root"
      assert result.result =~ parent_root
      refute result.result =~ "OUTSIDE"
      assert log =~ "clamping to the parent's root"
    end

    test "an unusable parent root denies the child rather than dropping it into the cwd", %{
      templates: templates
    } do
      cwd_file = Path.join(File.cwd!(), "mix.exs")

      result = delegate_read(%{workspace_root: nil}, cwd_file, templates)

      assert result.result =~ "is not a non-empty string"
      refute result.result =~ "defmodule Nous.MixProject"
    end

    test "the parallel path confines children the same way", %{
      parent_root: parent_root,
      templates: templates
    } do
      cwd_file = Path.join(File.cwd!(), "mix.exs")

      ctx =
        Context.new(deps: %{sub_agent_templates: templates, workspace_root: parent_root})

      result =
        SubAgent.spawn_agents(ctx, %{
          "tasks" => [%{"task" => "read #{cwd_file}", "template" => "reader"}]
        })

      assert [%{output: output}] = result.results
      assert output =~ "escapes the workspace root"
      refute output =~ "defmodule Nous.MixProject"
    end
  end
end
