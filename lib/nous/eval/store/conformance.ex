defmodule Nous.Eval.Store.Conformance do
  @moduledoc """
  Contract-conformance tests for a `Nous.Eval.Store` implementation.

  Like `Nous.Memory.Store.Conformance`, this is a test-time kit shipped in
  `lib/` so a backend implemented outside Nous is held to the battery Nous
  runs against its own stores:

      defmodule MyApp.Eval.Store.PostgresConformanceTest do
        use Nous.Eval.Store.Conformance,
          store: MyApp.Eval.Store.Postgres,
          # Hypothetical options of your store: `init/1` creates a schema
          # with a fresh unique name on every call.
          init_opts: [url: System.fetch_env!("EVAL_TEST_DATABASE_URL"), schema: :unique]
      end

  ## An isolated, empty store per test

  `init/1` runs once per test with the same options, and the store it
  returns **must be empty and isolated from every other test's store**,
  including tests of the same module running concurrently (the suite is
  `async: true`) and earlier runs of the suite. The kit asserts exact
  `list_runs/2` results and baseline histories, `:not_found` for labels it
  never set, and that stores refuse to re-put a run id, so a store that
  reopens the same database fails from the second test on. Use `:tmp_dir`
  for a file-backed store; for a database server, have `init/1` (or a
  test-only wrapper module around your store) create a fresh schema or
  database per call. Tests whose assertions do not depend on the rest of
  the store use run ids unique per test.

  ## Options

    * `:store` - the module under test (required)
    * `:init_opts` - keyword list passed to `init/1` (see above)
    * `:tag` - a module tag, e.g. `:sqlite`, so a suite needing a native
      dependency runs only where it is installed
    * `:tmp_dir` - give every test a fresh directory (ExUnit's `:tmp_dir`)
      and pass it to `init/1`: `:root` sets `root: dir`; `{:path, file}`
      sets `path: Path.join(dir, file)`. With it each test gets an empty
      store, and the suite also checks that records survive re-opening the
      store.

          use Nous.Eval.Store.Conformance,
            store: Nous.Eval.Store.File,
            tmp_dir: :root

  ## What it covers

  The `put_run/2` → `get_run/2` round trip of a run with a full trace
  (messages, tool calls, guard verdicts), `:not_found`, immutability of a
  stored run, `list_runs/2` ordering, filters, limit and filter validation,
  run id and label validation (path traversal included), and baselines:
  a label needs a stored run, is append-only with its history kept, and is
  `:not_found` when never set even though runs exist. For a store that
  implements the optional calibration callbacks: the
  `put_calibration/3` → `get_calibration/2` round trip, `:not_found`, the
  latest result per fingerprint winning, and key validation. For a store
  that implements the optional profile callbacks: round trips by id,
  version and label, per-name version numbering, idempotent re-puts, name
  conflicts, unnamed profiles, `:not_found` without fallback, append-only
  label history, and validation of names, labels, ids, refs and the
  profile itself. For a store that implements `delete_runs_before/3`: only
  the task's runs started strictly before the cutoff go (other tasks and
  runs without `started_at` stay), the count it returns, retention winning
  over a baseline label, argument validation, and durability.

  `run_fixture/2` is the realistic run the suite stores,
  `calibration_fixture/2` the judge calibration and `profile_fixture/3` the
  profile; use them in your own tests too.
  """

  alias Nous.Eval.{JudgeCalibration, Run, Sample, Score, ScorerError, Trace}
  alias Nous.Eval.Trace.Event
  alias Nous.Message
  alias Nous.Message.ContentPart
  alias Nous.Profile

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

      # A run id no other test, nor an earlier run of the suite, uses.
      defp unique_id(prefix),
        do: "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

      test "put_run/2 then get_run/2 round-trips a run with its trace", %{state: state} do
        id = unique_id("run-roundtrip")
        run = run_fixture(id)
        state = put!(state, run)

        assert {:ok, fetched} = @store.get_run(state, id)
        assert fetched == run

        [sample | _] = fetched.samples
        by_name = Map.new(sample.trace.events, &{&1.name, &1})
        assert by_name[[:nous, :agent, :tool_call, :stop]].metadata.outcome == :executed

        assert %Message{role: :assistant} =
                 by_name[[:nous, :agent, :model, :stop]].metadata.response
      end

      test "get_run/2 returns {:error, :not_found} for a missing id", %{state: state} do
        assert {:error, :not_found} = @store.get_run(state, unique_id("no-such-run"))
      end

      test "put_run/2 refuses an id that is already stored", %{state: state} do
        id = unique_id("run-once")
        original = run_fixture(id)
        state = put!(state, original)

        assert {:error, :already_exists} =
                 @store.put_run(state, %{original | task: "Other.Task", samples: []})

        assert {:ok, ^original} = @store.get_run(state, id)
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
        id = unique_id("run-a")
        state = put!(state, run_fixture(id))

        for label <- ["", "../main", "a/b", "Main", "with space", String.duplicate("l", 65), nil] do
          assert {:error, {:invalid_label, ^label}} = @store.put_baseline(state, label, id)
          assert {:error, {:invalid_label, ^label}} = @store.get_baseline(state, label)
          assert {:error, {:invalid_label, ^label}} = @store.list_baselines(state, label)
        end
      end

      if Code.ensure_loaded?(store) and function_exported?(store, :put_calibration, 3) do
        import Nous.Eval.Store.Conformance, only: [calibration_fixture: 1, calibration_fixture: 2]

        @fingerprint_a "sha256:" <> String.duplicate("a1", 32)
        @fingerprint_b "sha256:" <> String.duplicate("b2", 32)

        test "put_calibration/3 then get_calibration/2 round-trips a judge calibration",
             %{state: state} do
          result = calibration_fixture(@fingerprint_a)
          assert {:ok, state} = @store.put_calibration(state, @fingerprint_a, result)
          assert {:ok, ^result} = @store.get_calibration(state, @fingerprint_a)
        end

        test "get_calibration/2 is :not_found for a fingerprint never calibrated",
             %{state: state} do
          assert {:ok, state} =
                   @store.put_calibration(
                     state,
                     @fingerprint_a,
                     calibration_fixture(@fingerprint_a)
                   )

          assert {:error, :not_found} = @store.get_calibration(state, @fingerprint_b)
        end

        test "the latest calibration of a fingerprint wins; other fingerprints are untouched",
             %{state: state} do
          first = calibration_fixture(@fingerprint_a, kappa: 0.41)
          second = calibration_fixture(@fingerprint_a, kappa: 0.77)
          other = calibration_fixture(@fingerprint_b, kappa: 0.5)

          assert {:ok, state} = @store.put_calibration(state, @fingerprint_a, first)
          assert {:ok, state} = @store.put_calibration(state, @fingerprint_b, other)
          assert {:ok, state} = @store.put_calibration(state, @fingerprint_a, second)

          assert {:ok, ^second} = @store.get_calibration(state, @fingerprint_a)
          assert {:ok, ^other} = @store.get_calibration(state, @fingerprint_b)
        end

        test "calibration keys are validated", %{state: state} do
          result = calibration_fixture(@fingerprint_a)

          for id <- [
                "",
                "sha256:../../etc",
                "sha256:" <> String.duplicate("A1", 32),
                "md5:" <> String.duplicate("a", 32),
                String.duplicate("a1", 32),
                nil
              ] do
            assert {:error, {:invalid_fingerprint_id, ^id}} =
                     @store.put_calibration(state, id, result)

            assert {:error, {:invalid_fingerprint_id, ^id}} = @store.get_calibration(state, id)
          end

          assert {:error, :fingerprint_mismatch} =
                   @store.put_calibration(state, @fingerprint_b, result)

          assert {:error, :not_found} = @store.get_calibration(state, @fingerprint_b)
        end

        if tmp_dir do
          test "calibrations survive re-opening the store", %{state: state, init_opts: opts} do
            result = calibration_fixture(@fingerprint_a)
            assert {:ok, _state} = @store.put_calibration(state, @fingerprint_a, result)

            assert {:ok, reopened} = @store.init(opts)
            assert {:ok, ^result} = @store.get_calibration(reopened, @fingerprint_a)
          end
        end
      end

      if Code.ensure_loaded?(store) and function_exported?(store, :put_profile, 2) do
        import Nous.Eval.Store.Conformance, only: [profile_fixture: 2, profile_fixture: 3]

        alias Nous.Errors.ProfileError
        alias Nous.Eval.Store.ProfileLabel

        defp put_profile!(state, profile) do
          assert {:ok, stored, state} = @store.put_profile(state, profile)
          {stored, state}
        end

        test "put_profile/2 then get_profile/2 round-trips by id and by version",
             %{state: state} do
          profile = profile_fixture("support_agent", "first")
          {stored, state} = put_profile!(state, profile)

          assert stored == %{profile | version: 1}
          assert {:ok, ^stored} = @store.get_profile(state, {:id, profile.id})
          assert {:ok, ^stored} = @store.get_profile(state, {:version, "support_agent", 1})
        end

        test "versions are numbered per name on first put; re-putting is idempotent",
             %{state: state} do
          a = profile_fixture("support_agent", "a")
          b = profile_fixture("support_agent", "b")
          other = profile_fixture("billing_agent", "c")

          {%{version: 1}, state} = put_profile!(state, a)
          {%{version: 2}, state} = put_profile!(state, b)
          {%{version: 1}, state} = put_profile!(state, other)

          # Same content again, even with other metadata: the stored one.
          again = %{a | version: 9, provenance: %{"source" => "manual"}}

          assert {:ok, %{version: 1, provenance: %{"source" => "optimizer"}}, state} =
                   @store.put_profile(state, again)

          assert {:ok, %{id: id_b}} = @store.get_profile(state, {:version, "support_agent", 2})
          assert id_b == b.id

          assert {:ok, listed} = @store.list_profiles(state, "support_agent")
          assert Enum.map(listed, &{&1.version, &1.id}) == [{2, b.id}, {1, a.id}]
          assert {:ok, [%{id: other_id}]} = @store.list_profiles(state, "billing_agent")
          assert other_id == other.id
          assert {:ok, []} = @store.list_profiles(state, "never_stored")
        end

        test "a stored profile cannot move to another name", %{state: state} do
          profile = profile_fixture("support_agent", "a")
          {stored, state} = put_profile!(state, profile)

          assert {:error, {:name_conflict, "support_agent"}} =
                   @store.put_profile(state, %{profile | name: "billing_agent"})

          assert {:ok, ^stored} = @store.get_profile(state, {:id, profile.id})
          assert {:ok, []} = @store.list_profiles(state, "billing_agent")
        end

        test "an unnamed profile is stored by id only", %{state: state} do
          profile = profile_fixture(nil, "anonymous")
          {stored, state} = put_profile!(state, profile)

          assert %{name: nil, version: nil} = stored
          assert {:ok, ^stored} = @store.get_profile(state, {:id, profile.id})
          assert {:ok, ^stored, state} = @store.put_profile(state, profile)

          assert {:error, {:name_conflict, nil}} =
                   @store.put_profile(state, %{profile | name: "support_agent"})

          assert {:error, :not_found} =
                   @store.put_profile_label(state, "support_agent", "production", profile.id)
        end

        test "get_profile/2 is :not_found for unknown refs and never falls back",
             %{state: state} do
          {stored, state} = put_profile!(state, profile_fixture("support_agent", "a"))
          missing = profile_fixture("support_agent", "never stored")

          assert {:error, :not_found} = @store.get_profile(state, {:id, missing.id})
          assert {:error, :not_found} = @store.get_profile(state, {:version, "support_agent", 2})
          assert {:error, :not_found} = @store.get_profile(state, {:version, "other", 1})

          assert {:error, :not_found} =
                   @store.get_profile(state, {:label, "support_agent", "production"})

          assert {:ok, []} = @store.list_profile_labels(state, "support_agent", "production")
          assert {:ok, ^stored} = @store.get_profile(state, {:id, stored.id})
        end

        test "profile labels are append-only: re-pointing keeps the history", %{state: state} do
          {a, state} = put_profile!(state, profile_fixture("support_agent", "a"))
          {b, state} = put_profile!(state, profile_fixture("support_agent", "b"))
          {c, state} = put_profile!(state, profile_fixture("billing_agent", "c"))
          before = DateTime.utc_now()

          assert {:ok, state} =
                   @store.put_profile_label(state, "support_agent", "production", a.id)

          assert {:ok, state} =
                   @store.put_profile_label(state, "support_agent", "production", b.id)

          assert {:ok, state} = @store.put_profile_label(state, "support_agent", "staging", a.id)

          assert {:ok, state} =
                   @store.put_profile_label(state, "billing_agent", "production", c.id)

          assert {:ok, ^b} = @store.get_profile(state, {:label, "support_agent", "production"})
          assert {:ok, ^a} = @store.get_profile(state, {:label, "support_agent", "staging"})
          assert {:ok, ^c} = @store.get_profile(state, {:label, "billing_agent", "production"})

          # Rollback is one more entry.
          assert {:ok, state} =
                   @store.put_profile_label(state, "support_agent", "production", a.id)

          assert {:ok, ^a} = @store.get_profile(state, {:label, "support_agent", "production"})

          assert {:ok, history} =
                   @store.list_profile_labels(state, "support_agent", "production")

          assert Enum.map(history, & &1.profile_id) == [a.id, b.id, a.id]

          assert Enum.all?(
                   history,
                   &match?(%ProfileLabel{name: "support_agent", label: "production"}, &1)
                 )

          times = Enum.map(history, & &1.set_at)
          assert times == Enum.sort(times, {:desc, DateTime})
          assert DateTime.compare(List.last(times), before) != :lt
        end

        test "put_profile_label/4 needs a profile stored under that name", %{state: state} do
          {stored, state} = put_profile!(state, profile_fixture("support_agent", "a"))
          missing = profile_fixture("support_agent", "never stored")

          assert {:error, :not_found} =
                   @store.put_profile_label(state, "support_agent", "production", missing.id)

          assert {:error, :not_found} =
                   @store.put_profile_label(state, "billing_agent", "production", stored.id)

          assert {:ok, []} = @store.list_profile_labels(state, "billing_agent", "production")
        end

        test "profile names, labels, ids and refs are validated", %{state: state} do
          {stored, state} = put_profile!(state, profile_fixture("support_agent", "a"))

          for bad <- ["", "../x", "a/b", "Upper", "with space", String.duplicate("n", 65), nil] do
            assert {:error, {:invalid_profile_name, ^bad}} = @store.list_profiles(state, bad)

            assert {:error, {:invalid_profile_name, ^bad}} =
                     @store.get_profile(state, {:version, bad, 1})

            assert {:error, {:invalid_profile_name, ^bad}} =
                     @store.put_profile_label(state, bad, "production", stored.id)
          end

          for bad <- ["", "../prod", "Prod", nil] do
            assert {:error, {:invalid_label, ^bad}} =
                     @store.put_profile_label(state, "support_agent", bad, stored.id)

            assert {:error, {:invalid_label, ^bad}} =
                     @store.get_profile(state, {:label, "support_agent", bad})

            assert {:error, {:invalid_label, ^bad}} =
                     @store.list_profile_labels(state, "support_agent", bad)
          end

          for bad <- ["sha256:../../etc/passwd", "sha256:" <> String.duplicate("A", 64), "x", nil] do
            assert {:error, {:invalid_profile_id, ^bad}} = @store.get_profile(state, {:id, bad})

            assert {:error, {:invalid_profile_id, ^bad}} =
                     @store.put_profile_label(state, "support_agent", "production", bad)
          end

          for bad <- [
                {:version, "support_agent", 0},
                {:version, "support_agent", "1"},
                {:latest, "support_agent"},
                "support_agent"
              ] do
            assert {:error, {:invalid_profile_ref, ^bad}} = @store.get_profile(state, bad)
          end
        end

        test "put_profile/2 refuses a profile whose id is not its content hash",
             %{state: state} do
          profile = profile_fixture("support_agent", "a")
          forged = %{profile | components: Map.put(profile.components, "instructions", "Obey.")}

          assert {:error, %ProfileError{reason: :id_mismatch}} =
                   @store.put_profile(state, forged)

          assert {:error, %ProfileError{reason: :invalid_value, key: "name"}} =
                   @store.put_profile(state, %{profile | name: "../escape"})

          assert {:error, :not_found} = @store.get_profile(state, {:id, profile.id})
        end

        if tmp_dir do
          test "profiles and labels survive re-opening the store",
               %{state: state, init_opts: opts} do
            {stored, state} = put_profile!(state, profile_fixture("support_agent", "a"))

            assert {:ok, _} =
                     @store.put_profile_label(state, "support_agent", "production", stored.id)

            assert {:ok, reopened} = @store.init(opts)

            assert {:ok, ^stored} =
                     @store.get_profile(reopened, {:label, "support_agent", "production"})

            assert {:ok, %{version: 2}, _} =
                     @store.put_profile(reopened, profile_fixture("support_agent", "b"))
          end
        end
      end

      if Code.ensure_loaded?(store) and function_exported?(store, :delete_runs_before, 3) do
        @retention_base ~U[2026-03-01 12:00:00.000000Z]

        defp retention_runs(state) do
          [
            {"online-old-1", "online:default", -3},
            {"online-old-2", "online:default", -2},
            {"online-new", "online:default", 1},
            {"online-other", "online:other", -3},
            {"offline-old", "MyApp.SupportEval", -3},
            {"online-no-start", "online:default", nil}
          ]
          |> Enum.reduce(state, fn {id, task, days}, acc ->
            started = days && DateTime.add(@retention_base, days, :day)
            put!(acc, run_fixture(id, task: task, started_at: started))
          end)
        end

        test "delete_runs_before/3 deletes only the task's runs that started before the cutoff",
             %{state: state} do
          state = retention_runs(state)

          assert {:ok, 2, state} =
                   @store.delete_runs_before(state, "online:default", @retention_base)

          for id <- ["online-old-1", "online-old-2"] do
            assert {:error, :not_found} = @store.get_run(state, id)
          end

          for id <- ["online-new", "online-other", "offline-old", "online-no-start"] do
            assert {:ok, %Nous.Eval.Run{id: ^id}} = @store.get_run(state, id)
          end

          assert {:ok, summaries} = @store.list_runs(state, task: "online:default")
          assert Enum.sort(Enum.map(summaries, & &1.id)) == ["online-new", "online-no-start"]

          assert {:ok, 0, _state} =
                   @store.delete_runs_before(state, "online:default", @retention_base)
        end

        test "the cutoff is strict: a run started exactly at it is kept", %{state: state} do
          id = unique_id("online-edge")
          task = "online:" <> id
          state = put!(state, run_fixture(id, task: task, started_at: @retention_base))

          assert {:ok, 0, state} = @store.delete_runs_before(state, task, @retention_base)
          assert {:ok, _run} = @store.get_run(state, id)
        end

        test "retention wins over a baseline label: the label's run is deleted, its history kept",
             %{state: state} do
          state = retention_runs(state)
          assert {:ok, state} = @store.put_baseline(state, "online-main", "online-old-1")

          assert {:ok, 2, state} =
                   @store.delete_runs_before(state, "online:default", @retention_base)

          assert {:ok, %Baseline{run_id: "online-old-1"}} =
                   @store.get_baseline(state, "online-main")

          assert {:error, :not_found} = @store.get_run(state, "online-old-1")
        end

        test "delete_runs_before/3 validates its arguments", %{state: state} do
          state = retention_runs(state)

          assert {:error, {:invalid_argument, {:task, ""}}} =
                   @store.delete_runs_before(state, "", @retention_base)

          assert {:error, {:invalid_argument, {:task, nil}}} =
                   @store.delete_runs_before(state, nil, @retention_base)

          assert {:error, {:invalid_argument, {:before, "2026-03-01"}}} =
                   @store.delete_runs_before(state, "online:default", "2026-03-01")

          assert {:ok, %Nous.Eval.Run{}} = @store.get_run(state, "online-old-1")
        end

        if tmp_dir do
          test "deleted runs stay deleted after re-opening the store",
               %{state: state, init_opts: opts} do
            state = retention_runs(state)

            assert {:ok, 2, _state} =
                     @store.delete_runs_before(state, "online:default", @retention_base)

            assert {:ok, reopened} = @store.init(opts)
            assert {:error, :not_found} = @store.get_run(reopened, "online-old-2")
            assert {:ok, _run} = @store.get_run(reopened, "online-new")
          end
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
  A sealed-looking `Nous.Profile` named `name` (nil for an unnamed one)
  whose texts all contain `tag`: instructions with a safety rule, a tool
  description and a parameter description, a manifest of fixed base hashes,
  and optimizer provenance. Distinct tags give distinct ids.

  `overrides` replaces top-level `Nous.Profile` fields after the id is
  computed (only the unhashed `name`, `version`, `parent_id` and
  `provenance` keep the id valid).
  """
  @spec profile_fixture(String.t() | nil, String.t(), keyword()) :: Profile.t()
  def profile_fixture(name, tag, overrides \\ []) do
    {:ok, profile} =
      Profile.from_map(%{
        "nous_profile" => 1,
        "name" => name,
        "components" => %{
          "instructions" =>
            "You are the #{tag} support agent.\nNever quote internal prices.\nLook up the order first.",
          "tools" => %{
            "search_orders" => %{
              "description" => "Find orders (#{tag}).",
              "params" => %{"/properties/status" => "Order status (#{tag})."}
            }
          }
        },
        "manifest" => %{
          "instructions" => "sha256:" <> String.duplicate("1a", 32),
          "tool:search_orders" => "sha256:" <> String.duplicate("2b", 32)
        },
        "provenance" => %{
          "source" => "optimizer",
          "run_ids" => ["run-baseline", "run-candidate"],
          "optimizer" => %{"strategy" => "gepa", "seed" => 1234}
        }
      })

    struct!(profile, overrides)
  end

  @doc """
  A `Nous.Eval.JudgeCalibration.Result` for `fingerprint_id`: a Likert
  judge measured on 40 holdout cases with one judge error, every field set.

  `overrides` replaces top-level `Nous.Eval.JudgeCalibration.Result` fields.
  """
  @spec calibration_fixture(String.t(), keyword()) :: JudgeCalibration.Result.t()
  def calibration_fixture(fingerprint_id, overrides \\ []) do
    result = %JudgeCalibration.Result{
      fingerprint_id: fingerprint_id,
      judge: %{
        "model" => "openai:gpt-4o-2024-08-06",
        "provider" => "openai",
        "temperature" => 0,
        "seed" => 7,
        "prompt_hash" => "sha256:" <> String.duplicate("c3", 32),
        "scale" => %{
          "kind" => "likert",
          "min" => 1,
          "max" => 3,
          "labels" => %{"1" => "wrong", "3" => "right"}
        },
        "threshold" => 0.5,
        "include" => ["input", "output"],
        "samples" => 1,
        "reduce" => "majority",
        "max_span_bytes" => 20_000,
        "nous_version" => "0.20.0"
      },
      dataset_hash: "sha256:" <> String.duplicate("d4", 32),
      labels: ["1", "2", "3"],
      n_cases: 60,
      n_tune: 20,
      n_holdout: 40,
      n_scored: 39,
      n_errors: 1,
      agreement: %{estimate: 0.8205128205128205, ci: {0.6726, 0.9103}, count: 32, n: 39},
      kappa: 0.7312,
      kappa_kind: :quadratic_weighted,
      confusion: %{labels: ["1", "2", "3"], matrix: [[10, 2, 0], [1, 9, 2], [0, 2, 13]]},
      false_pass: %{estimate: 0.0833, ci: {0.0149, 0.3539}, count: 1, n: 12},
      error_rate: %{estimate: 0.025, ci: {0.0044, 0.1288}, count: 1, n: 40},
      errors: [%{case_id: "case-17", kind: :judge_out_of_range, reason: "verdict \"6\""}],
      usage: %Nous.Usage{
        input_tokens: 12_000,
        output_tokens: 900,
        total_tokens: 12_900,
        requests: 39
      },
      calibrated_at: ~U[2026-10-31 09:15:00.250000Z]
    }

    struct!(result, overrides)
  end

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
