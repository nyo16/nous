defmodule Nous.FanOutSaturationTest do
  # async: false — `saturate!/0` drops a GLOBAL supervisor's `:max_children` for
  # the duration of a test, so while it is in effect every spawn under
  # `Nous.TaskSupervisor` anywhere in the VM is refused. Nothing else may be
  # running. `use Nous.TaskSupervisorSaturation` will not compile in an
  # `async: true` module.
  use ExUnit.Case, async: false
  use Nous.TaskSupervisorSaturation

  alias Nous.{Agent, Message, Usage}
  alias Nous.Agent.Context
  alias Nous.Eval.{Runner, Suite, TestCase}
  alias Nous.Plugins.{InputGuard, SubAgent}
  alias Nous.RunContext
  alias Nous.Tools.SearchScrape
  alias Nous.Workflow
  alias Nous.Workflow.{Graph, Node, State}
  alias Nous.Workflow.Engine.ParallelExecutor

  # Every fan-out exercised here routes through `Nous.Tasks.stream/3`, which
  # degrades a refused batch to SEQUENTIAL execution of the identical per-item
  # function. These tests pin that the degraded path is indistinguishable from
  # the concurrent one — same results, same order, same per-item error
  # attribution, each item run exactly once — because that equivalence is the
  # only thing that makes the fallback safe to reach for. Without it each of
  # these entry points raised a RuntimeError out of a public API.
  #
  # NOT covered here, deliberately: `Nous.Research.Coordinator.search_parallel/5`.
  # `Coordinator.run/2` opens by wrapping the whole research loop in
  # `Nous.Tasks.async_nolink`, so under saturation it answers `{:error,
  # :saturated}` before `search_phase/2` is ever entered — the fan-out is
  # unreachable from every public entry point while the ceiling is down. In
  # production the ceiling is transient and the loop is long-lived, so the guard
  # there is still load-bearing; it just cannot be driven from a test without
  # widening the module's API for the test's benefit.

  @moduletag :capture_log

  defp tf(fun), do: %{transform_fn: fun}

  # ===========================================================================
  # Nous.Workflow.Engine.ParallelExecutor.execute_parallel/3
  # ===========================================================================

  describe "workflow :parallel node under a saturated supervisor" do
    test "still runs every branch and merges them" do
      saturate!()

      graph =
        Graph.new("deep_merge_saturated")
        |> Graph.add_node(:fan_out, :parallel, %{branches: [:a, :b], merge: :deep_merge})
        |> Graph.add_node(:a, :transform, tf(fn _data -> %{from_a: true} end))
        |> Graph.add_node(:b, :transform, tf(fn _data -> %{from_b: true} end))

      assert {:ok, state} = Workflow.run(graph)

      assert state.data.from_a == true
      assert state.data.from_b == true
    end

    test "a raising branch keeps its attribution instead of propagating" do
      # The sequential path has no task to crash, so it converts the raise into
      # the same `{:exit, {branch_id, {exception, stacktrace}}}` async_stream
      # reports under `zip_input_on_exit`. If that conversion were wrong the
      # raise would escape `Workflow.run/1` rather than land in state.errors.
      saturate!()

      graph =
        Graph.new("partial_fail_saturated")
        |> Graph.add_node(:fan_out, :parallel, %{
          branches: [:good, :bad],
          merge: :list_collect,
          on_branch_error: :continue_others,
          result_key: :results
        })
        |> Graph.add_node(:good, :transform, tf(fn _data -> %{ok: true} end))
        |> Graph.add_node(:bad, :transform, tf(fn _data -> raise "boom" end))

      assert {:ok, state} = Workflow.run(graph)

      assert length(state.data.results) == 1
      assert Enum.any?(state.errors, fn {id, _reason} -> id == "bad" end)
    end

    test "on_branch_error: :fail_fast still trips, naming the failed branch" do
      saturate!()

      graph =
        Graph.new("fail_fast_saturated")
        |> Graph.add_node(:fan_out, :parallel, %{
          branches: [:good, :bad],
          merge: :list_collect,
          on_branch_error: :fail_fast
        })
        |> Graph.add_node(:good, :transform, tf(fn _data -> %{ok: true} end))
        |> Graph.add_node(:bad, :transform, tf(fn _data -> raise "boom" end))

      assert {:error, {_node_id, {:parallel_branch_failed, "bad", _}}} = Workflow.run(graph)
    end
  end

  # ===========================================================================
  # Nous.Workflow.Engine.ParallelExecutor.execute_parallel_map/2
  # ===========================================================================

  describe "workflow :parallel_map node under a saturated supervisor" do
    test "maps every item, in input order" do
      saturate!()

      node = map_node(%{items: fn _state -> [1, 2, 3] end, handler: fn i, _ -> {:ok, i * 2} end})

      assert {:ok, [2, 4, 6], state} = ParallelExecutor.execute_parallel_map(node, State.new())
      assert state.data[:map_results] == [2, 4, 6]
    end

    test "a failing item is collected against its own index" do
      saturate!()

      node =
        map_node(%{
          items: fn _ -> [1, 2, 3] end,
          handler: fn
            2, _ -> {:error, :boom}
            i, _ -> {:ok, i}
          end
        })

      assert {:ok, [1, 3], state} = ParallelExecutor.execute_parallel_map(node, State.new())

      assert Enum.any?(state.errors, fn {key, reason} ->
               key == "map_item_1" and reason == :boom
             end)
    end

    test "on_error: :fail_fast still trips" do
      saturate!()

      node =
        map_node(%{
          items: fn _ -> [1, 2] end,
          handler: fn
            2, _ -> {:error, :boom}
            i, _ -> {:ok, i}
          end,
          on_error: :fail_fast
        })

      assert {:error, {:parallel_map_failed, _}} =
               ParallelExecutor.execute_parallel_map(node, State.new())
    end
  end

  defp map_node(config) do
    Node.new(%{id: "map", type: :parallel_map, label: "map", config: config})
  end

  # ===========================================================================
  # Nous.Plugins.InputGuard
  # ===========================================================================

  # Prompt-injection screening must degrade CLOSED. Screening fewer inputs
  # because the node is busy would be a bypass, so the fallback runs every
  # strategy rather than dropping the ones it has no slot for. These two
  # strategies report each invocation to the test process, which is what lets
  # the test tell "ran serially" apart from "silently skipped".
  defmodule SafeStrategy do
    @moduledoc false
    @behaviour Nous.Plugins.InputGuard.Strategy

    alias Nous.Plugins.InputGuard.Result

    @impl true
    def check(_input, config, _ctx) do
      send(Keyword.fetch!(config, :pid), {:checked, __MODULE__})
      {:ok, %Result{severity: :safe, strategy: __MODULE__}}
    end
  end

  defmodule BlockingStrategy do
    @moduledoc false
    @behaviour Nous.Plugins.InputGuard.Strategy

    alias Nous.Plugins.InputGuard.Result

    @impl true
    def check(_input, config, _ctx) do
      send(Keyword.fetch!(config, :pid), {:checked, __MODULE__})
      {:ok, %Result{severity: :blocked, reason: "test", strategy: __MODULE__}}
    end
  end

  describe "InputGuard strategies under a saturated supervisor" do
    test "every strategy still runs exactly once and the input is still blocked" do
      saturate!()

      # SafeStrategy is first, so a fallback that only screened what it had room
      # for would aggregate to :safe and wave the input through — that is the
      # bypass this asserts against.
      {ctx, _tools} =
        guard(%{
          strategies: [{SafeStrategy, pid: self()}, {BlockingStrategy, pid: self()}],
          policy: %{suspicious: :warn, blocked: :block}
        })

      assert ctx.needs_response == false
      assert List.last(ctx.messages).content =~ "can't process"

      assert_received {:checked, SafeStrategy}
      assert_received {:checked, BlockingStrategy}
      # Refusal arrives while claiming the FIRST slot, before any item has run,
      # so nothing is executed twice.
      refute_received {:checked, _}
    end

    test "the verdict matches the concurrent path with room to spare" do
      # The control: identical input and strategies, no saturation. If these two
      # tests ever disagree the fallback has stopped being equivalent.
      {ctx, _tools} =
        guard(%{
          strategies: [{SafeStrategy, pid: self()}, {BlockingStrategy, pid: self()}],
          policy: %{suspicious: :warn, blocked: :block}
        })

      assert ctx.needs_response == false
      assert List.last(ctx.messages).content =~ "can't process"

      assert_received {:checked, SafeStrategy}
      assert_received {:checked, BlockingStrategy}
      refute_received {:checked, _}
    end
  end

  defp guard(config) do
    agent = %Agent{
      name: "test",
      model: %Nous.Model{provider: :test, model: "test"},
      instructions: "test",
      tools: [],
      plugins: [InputGuard],
      model_settings: %{}
    }

    ctx =
      Context.new(deps: %{input_guard_config: config})
      |> Context.add_message(Message.user("hello"))

    InputGuard.before_request(agent, InputGuard.init(agent, ctx), [])
  end

  # ===========================================================================
  # Nous.Tools.SearchScrape
  # ===========================================================================

  describe "SearchScrape.scrape_results/2 under a saturated supervisor" do
    setup do
      # Bypass binds 127.0.0.1 and UrlGuard blocks loopback; the exact-IP escape
      # hatch opens 127.0.0.1 and nothing else.
      Application.put_env(:nous, :url_guard_allow_ips, [{127, 0, 0, 1}])
      on_exit(fn -> Application.delete_env(:nous, :url_guard_allow_ips) end)

      {:ok, bypass: Bypass.open()}
    end

    test "fetches every URL instead of returning none", %{bypass: bypass} do
      saturate!()

      Bypass.expect(bypass, "GET", "/a", &html_page/1)
      Bypass.expect(bypass, "GET", "/b", &html_page/1)

      urls = ["http://127.0.0.1:#{bypass.port}/a", "http://127.0.0.1:#{bypass.port}/b"]

      assert %{results: results, total_fetched: 2, total_requested: 2} =
               SearchScrape.scrape_results(RunContext.new(%{}), %{
                 "urls" => urls,
                 "query" => "greeting"
               })

      # Order follows the model-supplied list, exactly as the concurrent path
      # does — async_stream is ordered by default.
      assert Enum.map(results, & &1.url) == urls
      assert Enum.all?(results, &(&1.summary == "Hello world"))
    end
  end

  defp html_page(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.resp(200, """
    <html>
      <head><title>Test Page</title></head>
      <body><article><p>Hello world</p></article></body>
    </html>
    """)
  end

  # ===========================================================================
  # Nous.Eval.Runner
  # ===========================================================================

  describe "Eval.Runner parallel suite under a saturated supervisor" do
    test "every test case still produces a result, in order" do
      # Passing `model:` explicitly wins Config.get_model/3's precedence ladder,
      # so this does not depend on NOUS_EVAL_DEFAULT_MODEL. Saturation also
      # refuses each case's own inner spawn, so every case finalizes as an error
      # result — the point is that all of them come back, in order, instead of
      # the refused fan-out taking the whole suite down with a RuntimeError.
      saturate!()

      suite =
        Suite.new(
          name: "saturated",
          parallelism: 2,
          test_cases: [TestCase.new(id: "a", input: "hi"), TestCase.new(id: "b", input: "yo")]
        )

      assert {:ok, suite_result} = Runner.run(suite, parallelism: 2, model: "openai:test-model")

      assert Enum.map(suite_result.results, & &1.test_case_id) == ["a", "b"]
      assert suite_result.total_count == 2
    end
  end

  # ===========================================================================
  # Nous.Plugins.SubAgent
  # ===========================================================================

  # Text-only on purpose: a stub that emitted tool calls would fan out through
  # `Nous.AgentRunner.ToolExecution`, which deliberately does NOT degrade to
  # sequential (its per-call timeout is load-bearing) and answers with saturated
  # tool results instead — a different mechanism than the one under test here.
  defmodule EchoDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      user_content =
        Enum.find_value(messages, fn
          %Message{role: :user, content: content} when is_binary(content) -> content
          _ -> nil
        end)

      legacy = %{
        parts: [{:text, "Mock response for: #{user_content || "unknown"}"}],
        usage: %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, requests: 1},
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      }

      {:ok, Message.from_legacy(legacy)}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  describe "SubAgent.spawn_agents/2 under a saturated supervisor" do
    setup do
      # Process-scoped: `Nous.ModelDispatcher` resolves through `$callers`, which
      # async_stream propagates into its tasks — and the sequential fallback runs
      # in this very process. One stub therefore covers both paths.
      Nous.ModelDispatcher.put_dispatcher(EchoDispatcher)

      templates = %{
        "researcher" => Agent.new("openai:test-model", instructions: "Research.")
      }

      {:ok, ctx: Context.new(deps: %{sub_agent_templates: templates})}
    end

    test "runs every sub-agent instead of refusing the batch", %{ctx: ctx} do
      saturate!()

      assert %{total: 2, succeeded: 2, failed: 0, results: results} =
               SubAgent.spawn_agents(ctx, %{
                 "tasks" => [
                   %{"task" => "first", "template" => "researcher"},
                   %{"task" => "second", "template" => "researcher"}
                 ]
               })

      # Zipped back against the input list, so order is the model's order.
      assert Enum.map(results, & &1.task) == ["first", "second"]
      assert Enum.all?(results, & &1.success)
      assert hd(results).output =~ "Mock response for: first"
    end
  end
end
