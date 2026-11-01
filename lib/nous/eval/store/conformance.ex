defmodule Nous.Eval.Store.Conformance do
  @moduledoc """
  Contract-conformance tests for a `Nous.Eval.Store` implementation.

  Like `Nous.Memory.Store.Conformance`, this is a test-time kit shipped in
  `lib/` so a backend implemented outside Nous is held to the battery Nous
  runs against its own stores:

      defmodule MyApp.Eval.Store.PostgresConformanceTest do
        use Nous.Eval.Store.Conformance,
          store: MyApp.Eval.Store.Postgres,
          init_opts: [url: "postgres://localhost/eval_test"]
      end

  ## Options

    * `:store` - the module under test (required)
    * `:init_opts` - keyword list passed to `init/1`
    * `:tag` - a module tag, e.g. `:sqlite`, so a suite needing a native
      dependency runs only where it is installed
    * `:tmp_dir` - give every test a fresh directory (ExUnit's `:tmp_dir`)
      and pass it to `init/1`: `:root` sets `root: dir`; `{:path, file}`
      sets `path: Path.join(dir, file)`. With it the suite also checks that
      records survive re-opening the store.

          use Nous.Eval.Store.Conformance,
            store: Nous.Eval.Store.File,
            tmp_dir: :root

  ## What it covers

  The `put_run/2` → `get_run/2` round trip of a run with a full trace
  (messages, tool calls, guard verdicts), `:not_found`, immutability of a
  stored run, `list_runs/2` ordering, filters, limit and filter validation,
  run id and label validation (path traversal included), and baselines:
  a label needs a stored run, is append-only with its history kept, and is
  `:not_found` when never set even though runs exist.

  `run_fixture/2` is the realistic run the suite stores; use it in your own
  tests too.
  """

  alias Nous.Eval.{Run, Sample, Score, ScorerError, Trace}
  alias Nous.Eval.Trace.Event
  alias Nous.Message
  alias Nous.Message.ContentPart

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)
    init_opts = Keyword.get(opts, :init_opts, [])
    tag = Keyword.get(opts, :tag)
    tmp_dir = Keyword.get(opts, :tmp_dir)

    quote bind_quoted: [store: store, init_opts: init_opts, tag: tag, tmp_dir: tmp_dir] do
      use ExUnit.Case, async: true

      import Nous.Eval.Store.Conformance, only: [run_fixture: 1, run_fixture: 2]

      alias Nous.Eval.Store.{Baseline, RunSummary}
      alias Nous.Message

      @store store
      @base_init_opts init_opts
      @tmp_dir_opt tmp_dir

      if tag, do: @moduletag(tag)
      if tmp_dir, do: @moduletag(:tmp_dir)

      setup context do
        opts =
          Nous.Eval.Store.Conformance.init_opts(@base_init_opts, @tmp_dir_opt, context[:tmp_dir])

        {:ok, state} = @store.init(opts)
        %{state: state, init_opts: opts}
      end

      defp put!(state, run) do
        assert {:ok, state} = @store.put_run(state, run)
        state
      end

      test "put_run/2 then get_run/2 round-trips a run with its trace", %{state: state} do
        run = run_fixture("run-roundtrip")
        state = put!(state, run)

        assert {:ok, fetched} = @store.get_run(state, "run-roundtrip")
        assert fetched == run

        [sample | _] = fetched.samples
        by_name = Map.new(sample.trace.events, &{&1.name, &1})
        assert by_name[[:nous, :agent, :tool_call, :stop]].metadata.outcome == :executed

        assert %Message{role: :assistant} =
                 by_name[[:nous, :agent, :model, :stop]].metadata.response
      end

      test "get_run/2 returns {:error, :not_found} for a missing id", %{state: state} do
        assert {:error, :not_found} = @store.get_run(state, "no-such-run")
      end

      test "put_run/2 refuses an id that is already stored", %{state: state} do
        original = run_fixture("run-once")
        state = put!(state, original)

        assert {:error, :already_exists} =
                 @store.put_run(state, %{original | task: "Other.Task", samples: []})

        assert {:ok, ^original} = @store.get_run(state, "run-once")
      end

      test "list_runs/2 returns summaries newest first, runs without a start last",
           %{state: state} do
        base = ~U[2026-03-01 12:00:00.000000Z]

        state =
          [{"run-b", 2}, {"run-none", nil}, {"run-c", 3}, {"run-a", 1}]
          |> Enum.reduce(state, fn {id, minutes}, acc ->
            started = minutes && DateTime.add(base, minutes, :minute)
            put!(acc, run_fixture(id, started_at: started))
          end)

        assert {:ok, summaries} = @store.list_runs(state, [])
        assert Enum.map(summaries, & &1.id) == ["run-c", "run-b", "run-a", "run-none"]

        assert [%RunSummary{id: "run-c", sample_count: 2, task: "MyApp.SupportEval"} | _] =
                 summaries
      end

      test "list_runs/2 filters by task, status, time window and limit", %{state: state} do
        base = ~U[2026-03-01 12:00:00Z]

        runs = [
          run_fixture("run-1", task: "A", status: :completed, started_at: base),
          run_fixture("run-2",
            task: "A",
            status: :aborted,
            started_at: DateTime.add(base, 1, :hour)
          ),
          run_fixture("run-3",
            task: "B",
            status: :completed,
            started_at: DateTime.add(base, 2, :hour)
          ),
          run_fixture("run-4", task: "A", status: :completed, started_at: nil)
        ]

        state = Enum.reduce(runs, state, &put!(&2, &1))
        ids = fn filters -> state |> @store.list_runs(filters) |> elem(1) |> Enum.map(& &1.id) end

        assert ids.(task: "A") == ["run-2", "run-1", "run-4"]
        assert ids.(status: :completed) == ["run-3", "run-1", "run-4"]
        assert ids.(task: "A", status: :completed) == ["run-1", "run-4"]
        assert ids.(since: DateTime.add(base, 1, :hour)) == ["run-3", "run-2"]
        assert ids.(until: DateTime.add(base, 1, :hour)) == ["run-1"]

        assert ids.(since: base, until: DateTime.add(base, 2, :hour)) == ["run-2", "run-1"]

        assert ids.(limit: 2) == ["run-3", "run-2"]
        assert ids.(limit: 0) == []
      end

      test "list_runs/2 rejects unknown and mistyped filters", %{state: state} do
        assert {:error, {:invalid_filter, _}} = @store.list_runs(state, statuz: :completed)
        assert {:error, {:invalid_filter, _}} = @store.list_runs(state, status: "completed")
        assert {:error, {:invalid_filter, _}} = @store.list_runs(state, status: :running)
        assert {:error, {:invalid_filter, _}} = @store.list_runs(state, limit: -1)
        assert {:error, {:invalid_filter, _}} = @store.list_runs(state, since: "2026-01-01")
      end

      test "run ids that could escape storage are rejected", %{state: state} do
        state = put!(state, run_fixture("run-ok"))

        for id <- [
              "../escape",
              "..",
              "a/b",
              "a\\b",
              "/etc/passwd",
              "",
              ".hidden",
              "Upper",
              "with space",
              "nul\0byte",
              String.duplicate("a", 129)
            ] do
          assert {:error, {:invalid_run_id, ^id}} = @store.put_run(state, run_fixture(id))
          assert {:error, {:invalid_run_id, ^id}} = @store.get_run(state, id)
          assert {:error, {:invalid_run_id, ^id}} = @store.put_baseline(state, "main", id)
        end

        assert {:error, {:invalid_run_id, nil}} = @store.get_run(state, nil)
        assert {:ok, [%RunSummary{id: "run-ok"}]} = @store.list_runs(state, [])
      end

      test "put_baseline/3 requires a stored run", %{state: state} do
        assert {:error, :not_found} = @store.put_baseline(state, "main", "never-stored")
        assert {:error, :not_found} = @store.get_baseline(state, "main")
      end

      test "get_baseline/2 never falls back to the latest run", %{state: state} do
        state = put!(state, run_fixture("run-latest"))

        assert {:error, :not_found} = @store.get_baseline(state, "main")
        assert {:ok, []} = @store.list_baselines(state, "main")
      end

      test "baselines are append-only: re-pointing keeps the history", %{state: state} do
        state = Enum.reduce(["run-a", "run-b"], state, &put!(&2, run_fixture(&1)))
        before = DateTime.utc_now()

        assert {:ok, state} = @store.put_baseline(state, "main", "run-a")
        assert {:ok, state} = @store.put_baseline(state, "main", "run-b")

        assert {:ok, %Baseline{label: "main", run_id: "run-b"}} =
                 @store.get_baseline(state, "main")

        assert {:ok, state} = @store.put_baseline(state, "main", "run-a")
        assert {:ok, %Baseline{run_id: "run-a"} = latest} = @store.get_baseline(state, "main")
        assert DateTime.compare(latest.set_at, before) != :lt

        assert {:ok, history} = @store.list_baselines(state, "main")
        assert Enum.map(history, & &1.run_id) == ["run-a", "run-b", "run-a"]
        assert Enum.all?(history, &(&1.label == "main"))

        times = Enum.map(history, & &1.set_at)
        assert times == Enum.sort(times, {:desc, DateTime})
      end

      test "baseline labels are independent", %{state: state} do
        state = Enum.reduce(["run-a", "run-b"], state, &put!(&2, run_fixture(&1)))

        assert {:ok, state} = @store.put_baseline(state, "main", "run-a")
        assert {:ok, state} = @store.put_baseline(state, "release-0.20", "run-b")

        assert {:ok, %Baseline{run_id: "run-a"}} = @store.get_baseline(state, "main")
        assert {:ok, %Baseline{run_id: "run-b"}} = @store.get_baseline(state, "release-0.20")
        assert {:ok, [%Baseline{run_id: "run-a"}]} = @store.list_baselines(state, "main")
      end

      test "baseline labels are validated", %{state: state} do
        state = put!(state, run_fixture("run-a"))

        for label <- ["", "../main", "a/b", "Main", "with space", String.duplicate("l", 65), nil] do
          assert {:error, {:invalid_label, ^label}} = @store.put_baseline(state, label, "run-a")
          assert {:error, {:invalid_label, ^label}} = @store.get_baseline(state, label)
          assert {:error, {:invalid_label, ^label}} = @store.list_baselines(state, label)
        end
      end

      if tmp_dir do
        test "runs and baselines survive re-opening the store", %{state: state, init_opts: opts} do
          run = run_fixture("run-durable")
          state = put!(state, run)
          assert {:ok, _state} = @store.put_baseline(state, "main", "run-durable")

          assert {:ok, reopened} = @store.init(opts)
          assert {:ok, ^run} = @store.get_run(reopened, "run-durable")
          assert {:ok, [%RunSummary{id: "run-durable"}]} = @store.list_runs(reopened, [])
          assert {:ok, %Baseline{run_id: "run-durable"}} = @store.get_baseline(reopened, "main")
        end
      end
    end
  end

  @doc false
  @spec init_opts(keyword(), nil | :root | {:path, String.t()}, String.t() | nil) :: keyword()
  def init_opts(opts, nil, _dir), do: opts
  def init_opts(opts, :root, dir) when is_binary(dir), do: Keyword.put(opts, :root, dir)

  def init_opts(opts, {:path, file}, dir) when is_binary(dir),
    do: Keyword.put(opts, :path, Path.join(dir, file))

  @doc """
  A realistic `Nous.Eval.Run` with id `id`: two samples, one passing with a
  full trace (run start, model start with the request messages, model stop
  with an assistant `Nous.Message` requesting a tool, tool-call start/stop
  with outcome atoms, guard verdicts, run stop), one with a scorer error.

  `overrides` replaces top-level `Nous.Eval.Run` fields.
  """
  @spec run_fixture(String.t(), keyword()) :: Run.t()
  def run_fixture(id, overrides \\ []) do
    at = ~U[2026-03-01 12:00:00.123456Z]
    trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
    agent_run_id = "00f067aa0ba902b7"

    scope = %{
      trace_id: trace_id,
      agent_run_id: agent_run_id,
      parent_agent_run_id: nil
    }

    system = %{Message.system("You are a support agent.") | created_at: at}

    user = %{
      Message.user([
        ContentPart.text("Where is order 42?"),
        ContentPart.image_url("https://x.test/a.png")
      ])
      | created_at: at
    }

    response = %{
      Message.assistant("",
        tool_calls: [%{id: "call_1", name: "lookup_order", arguments: %{"order_id" => 42}}]
      )
      | created_at: at
    }

    events = [
      event(
        0,
        [:nous, :agent, :run, :start],
        %{system_time: 1_772_366_400_000_000_000},
        Map.merge(scope, %{agent_name: "support", role: :agent, model_provider: :openai})
      ),
      event(
        1,
        [:nous, :agent, :model, :start],
        %{monotonic_time: -576_460_751_000},
        Map.merge(scope, %{iteration: 1, messages: [system, user], tool_names: ["lookup_order"]})
      ),
      event(
        2,
        [:nous, :agent, :model, :stop],
        %{duration: 120_000_000, input_tokens: 31, output_tokens: 12},
        Map.merge(scope, %{
          finish_reason: :tool_calls,
          response: response,
          requested_tool_calls: [%{tool_call_id: "call_1", tool_name: "lookup_order"}]
        })
      ),
      event(
        3,
        [:nous, :agent, :tool_call, :start],
        %{system_time: 1},
        Map.merge(scope, %{
          tool_call_id: "call_1",
          tool_name: "lookup_order",
          arguments: %{"order_id" => 42}
        })
      ),
      event(
        4,
        [:nous, :decision_guard, :verdict],
        %{duration: 5_000, chunk_count: 1},
        Map.merge(scope, %{
          surface: :tool_call,
          verdict: :allow,
          probabilities: %{"allow" => 0.97, "deny" => 0.03},
          canary_failed: false,
          error: nil
        })
      ),
      event(
        5,
        [:nous, :agent, :tool_call, :stop],
        %{duration: 2_000_000},
        Map.merge(scope, %{
          tool_call_id: "call_1",
          tool_name: "lookup_order",
          outcome: :executed,
          approval: :not_required,
          result: %{"status" => "shipped", "eta" => {2026, 3, 4}},
          result_modified: false,
          error: nil
        })
      ),
      event(
        6,
        [:nous, :input_guard, :verdict],
        %{duration: 900, strategies: 2, dropped: 0},
        Map.merge(scope, %{severity: :safe, aggregation: :any, fail_closed: true, action: :allow})
      ),
      event(
        7,
        [:nous, :agent, :run, :stop],
        %{duration: 300_000_000, total_tokens: 43},
        Map.merge(scope, %{agent_name: "support", fallback_used: false})
      )
    ]

    passing = %Sample{
      case_id: "order-status",
      index: 0,
      seed: 7,
      trace_id: trace_id,
      outcome: :ok,
      output: "Order 42 has shipped.",
      verdict: :pass,
      case_score: 0.875,
      scores: [
        %Score{name: "contains", value: :pass, passed?: true, reason: "found \"shipped\""},
        %Score{
          name: "judge.helpfulness",
          value: 0.75,
          passed?: true,
          details: %{"critique" => "Concise."},
          metadata: %{judge_model: "openai:gpt-4o-mini", scale: {1, 5}}
        },
        %Score{name: "tone", value: {:label, "neutral"}, passed?: true}
      ],
      skipped: [{"similarity", "no expected output"}],
      trace: %Trace{trace_id: trace_id, events: events, dropped: 1},
      usage: %Nous.Usage{requests: 1, input_tokens: 31, output_tokens: 12, total_tokens: 43},
      cost: 0.00042,
      duration_ms: 300,
      iterations: 1
    }

    errored = %Sample{
      case_id: "refund",
      index: 0,
      outcome: :error,
      error: "provider returned 503",
      verdict: :error,
      scorer_errors: [
        %ScorerError{
          scorer: "judge",
          kind: :judge_unparseable,
          reason: "no verdict",
          details: %{"raw" => "maybe?"}
        }
      ],
      trace: %Trace{trace_id: "0af7651916cd43dd8448eb211c80319c", truncated?: true}
    }

    struct!(
      %Run{
        id: id,
        task: "MyApp.SupportEval",
        status: :completed,
        started_at: at,
        finished_at: DateTime.add(at, 5, :second),
        fingerprint: %{"model" => "openai:gpt-4o", "instructions" => "sha256:77e0"},
        dataset_hash: "sha256:c3d1",
        k: 1,
        seed: 7,
        budget: %{limits: %{cost: 1.0}, spent: %{cost: 0.00042, tokens: 43}},
        samples: [passing, errored],
        summary: %{pass_rate: 0.5, cases: 2},
        metadata: %{"git_sha" => "abc123", "ci" => true}
      },
      overrides
    )
  end

  defp event(seq, name, measurements, metadata) do
    %Event{name: name, measurements: measurements, metadata: metadata, at: 1_000 + seq, seq: seq}
  end
end
