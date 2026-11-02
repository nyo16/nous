defmodule Nous.Eval do
  @moduledoc """
  Evaluate agents against datasets, with repeated samples, traces and
  scorers.

  ## The model

    * A **task** is a module that `use`s `Nous.Eval`. It says which agent to
      build, which dataset to run and which scorers judge every case.
    * A **dataset** (`Nous.Eval.Dataset`) is a validated list of
      `Nous.Eval.Case`s, written in Elixir, YAML or JSONL. Every case has a
      stable string id, a split (`train`/`val`/`test`) and a content hash.
    * Each case runs `k` times. Every run is a **sample** (`Nous.Eval.Sample`)
      with the agent's output and the trace of what it did (model calls, tool
      calls, guard verdicts).
    * **Scorers** (`Nous.Eval.Scorer`) turn a sample into scores. Required
      scorers are gates; the others form a weighted soft group compared with
      the case threshold. A scorer that fails to run is an error, never a
      pass.
    * A **run** (`Nous.Eval.Run`) records every sample, the summary
      statistics and a **fingerprint** (`Nous.Eval.Fingerprint`) of the model,
      prompt, tools, guards, data and scorers, so runs are only compared with
      runs of the same configuration.

  ## A task module

      defmodule MyApp.Evals.Refunds do
        use Nous.Eval

        @impl true
        def dataset, do: "evals/refunds.yaml"

        @impl true
        def scorers, do: [{MyApp.Eval.NoToolErrors, []}]

        @impl true
        def setup(_opts), do: {:ok, %{orders: MyApp.Fixtures.orders()}}

        @impl true
        def deps(%{orders: orders}), do: %{orders: orders}

        @impl true
        def agent(%{deps: _deps}) do
          Nous.new("openai:gpt-4o-mini",
            instructions: "You are Acme's support agent.",
            tools: [&MyApp.Tools.search_orders/2, &MyApp.Tools.refund_order/2]
          )
        end
      end

  ## Callbacks

    * `c:agent/1` (required) - builds the agent for one sample. The context
      map carries `:case` (the `Nous.Eval.Case`), `:sample` (0-based sample
      index), `:seed` (the sample's seed or `nil`), `:deps` (the run deps)
      and `:state` (what `c:setup/1` returned)
    * `c:dataset/0` (required) - a `Nous.Eval.Dataset`, a list of cases
      (see `Nous.Eval.Dataset.new/2`) or the path of a YAML/JSONL file
    * `c:scorers/0` - scorers applied to every case, before the case's own
      (default `[]`)
    * `c:setup/1` / `c:teardown/1` - run once around the whole eval run;
      `setup/1` receives the run options and returns `{:ok, state}` or
      `{:error, reason}` (which aborts the run)
    * `c:deps/1` - the deps every sample runs with, from the setup state
      (default `%{}`)
    * `c:simulator/0`, `c:episode_setup/1`, `c:episode_state/1`,
      `c:episode_teardown/1` - for simulated multi-turn cases
      (`nous.sim_case/1`): the simulated user's model, and the environment
      of each episode (see `Nous.Eval.Simulator`). `simulator/0` is required
      when the dataset holds simulated cases, `episode_state/1` when one of
      them checks an end state; the others are optional (no environment)

  `use Nous.Eval` sets `@behaviour Nous.Eval` and defines overridable
  defaults for `c:scorers/0`, `c:setup/1`, `c:teardown/1` and `c:deps/1`.
  `Nous.Eval.Task.load/2` validates a task module before it runs.

  ## The workflow

    1. **Run** the task: `Nous.Eval.run(MyApp.Evals.Refunds, k: 3, seed: 1)`
       or `mix nous.eval --task MyApp.Evals.Refunds`. Every case runs `k`
       times under the trace collector; each sample is scored and the run
       record carries the samples, their traces and the summary statistics
       (`Nous.Eval.Summary`).
    2. **Store** it: pass `store: {Nous.Eval.Store.File, root: ".nous/eval"}`
       (or SQLite/DuckDB, see `Nous.Eval.Store`). `mix nous.eval` stores
       every run.
    3. **Report**: `Nous.Eval.Reporter.render(run, format: :console |
       :markdown | :json)`.
    4. **Compare** against a baseline: `Nous.Eval.Compare.compare(baseline,
       candidate)` matches cases by id and gates on a paired bootstrap of
       the declared metrics. Baselines are append-only labels in the store
       (`mix nous.eval --set-baseline main`, then `mix nous.eval --baseline
       main` in CI; see `Mix.Tasks.Nous.Eval` for the exit codes).
    5. **Inspect** failures through the sample's trace with the
       `Nous.Eval.Trace` queries (`tool_calls/2`, `guard_verdicts/2`,
       `transcript/2`, ...).
    6. **Re-score** stored traces after changing scorers, without calling
       the agent again: `Nous.Eval.rescore/3` or `mix nous.eval.rescore`.

  `Nous.Eval.Examples.Basic` is a complete task that runs offline.
  """

  alias Nous.Eval.{Case, Dataset, Run, Runner}
  alias Nous.Eval.Scorer.Spec

  @typedoc "The context `c:agent/1` receives for one sample."
  @type context :: %{
          required(:case) => Case.t(),
          required(:sample) => non_neg_integer(),
          required(:seed) => integer() | nil,
          required(:deps) => map(),
          required(:state) => term(),
          optional(atom()) => term()
        }

  @typedoc "A scorer as a task or case declares it."
  @type scorer :: module() | {module(), keyword()} | Spec.t()

  @doc "Builds the agent that runs one sample."
  @callback agent(context()) :: Nous.Agent.t()

  @doc "The cases to run: a dataset, a list of cases, or a dataset file path."
  @callback dataset() :: Dataset.t() | [Case.t() | map() | keyword()] | Path.t()

  @doc "Scorers applied to every case."
  @callback scorers() :: [scorer()]

  @doc "Prepares shared state once per eval run."
  @callback setup(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @doc "Releases what `c:setup/1` acquired; runs even when the run fails."
  @callback teardown(state :: term()) :: term()

  @doc "The deps every sample's agent run receives."
  @callback deps(state :: term()) :: map()

  @typedoc "The context `c:episode_setup/1` receives for one simulated episode."
  @type episode_context :: %{
          required(:case) => Case.t(),
          required(:sample) => non_neg_integer(),
          required(:seed) => integer() | nil,
          required(:deps) => map(),
          required(:state) => term(),
          required(:fixture) => String.t() | nil
        }

  @doc """
  The simulated user's configuration (see `Nous.Eval.Simulator.new/1`):
  `[model: "provider:model", model_settings: %{...}, max_retries: n]`.
  """
  @callback simulator() :: keyword()

  @doc """
  Builds the environment of one simulated episode. `env.deps` (a map,
  optional) is merged over the run deps for the agent.
  """
  @callback episode_setup(episode_context()) :: {:ok, env :: map()} | {:error, term()}

  @doc "The end state of an episode's environment, read after the conversation."
  @callback episode_state(env :: map()) :: {:ok, map()} | {:error, term()}

  @doc "Releases the episode's environment; runs after `c:episode_state/1`."
  @callback episode_teardown(env :: map()) :: term()

  @optional_callbacks scorers: 0,
                      setup: 1,
                      teardown: 1,
                      deps: 1,
                      simulator: 0,
                      episode_setup: 1,
                      episode_state: 1,
                      episode_teardown: 1

  @doc """
  Runs an eval task and returns the run record.

      {:ok, run} = Nous.Eval.run(MyApp.Evals.Refunds, k: 3, seed: 42)
      run.summary["pass_rate"]["estimate"]

  ## Options

    * `:k` - samples per case (default `3`)
    * `:parallelism` - samples in flight (default
      `System.schedulers_online/0`)
    * `:timeout` - per-sample limit in ms (default `120_000`). A sample past
      it is killed: outcome `:killed`, its trace kept up to the kill
    * `:seed` - base seed (integer, default `nil`). Each sample gets its own
      seed, a deterministic function of the base seed, the case id and the
      sample index, set as the agent's `model_settings[:seed]` and passed to
      `c:agent/1` as `:seed`. Whether the provider honours it is recorded as
      `"seed_forwarded"` in the fingerprint
    * `:splits` - run only these splits (`["test"]`; see
      `Nous.Eval.Case.splits/0`)
    * `:tags` - run only cases carrying at least one of these tags
    * `:cases` - run only the cases with these ids (strings), after the
      `:splits` and `:tags` filters; an id they do not hold is
      `{:error, {:unknown_cases, ids}}`
    * `:profile` - a `Nous.Profile` applied (`Nous.Profile.apply/2`) to every
      agent `c:agent/1` builds, so the whole run uses the profile's text; the
      fingerprint records its id. A profile that does not apply to the first
      case's agent is `{:error, {:profile, %Nous.Errors.ProfileError{}}}`
      before any model call; one that fails on a later case's agent makes
      that sample `:error`. `Nous.Eval.Optimizer` evaluates its candidates
      this way
    * `:budget` - `[max_tokens: n, max_cost: usd, max_samples: n]`, see
      "Budgets"
    * `:store` - `{store_module, init_opts}`: the run is persisted with
      `c:Nous.Eval.Store.put_run/2` (see `Nous.Eval.Store`)
    * `:scorer_timeout` - per-scorer limit, as `Nous.Eval.Scoring.score/3`'s
      `:timeout`
    * `:max_trace_events` / `:max_trace_bytes` - per-sample trace caps
      (defaults 10 000 events / 8 MB); past them the trace is `truncated?`
    * `:metadata` - a map stored on the run (git sha, CI job, ...)

  The options are also passed to the task's `c:setup/1`.

  ## What happens

  The task is loaded and its dataset filtered (no case left is
  `{:error, :no_cases}`); `c:setup/1` runs; every scorer's
  `c:Nous.Eval.Scorer.init/1` runs (the task's scorers, then each case's,
  which come after the task's); the fingerprint is built from the first
  case's agent; the budget is checked. Any failure so far is an
  `{:error, reason}` before a single model call. Then each (case, sample)
  runs the agent built by `c:agent/1` (a string input with
  `Nous.run(agent, input)`, a message list with `Nous.run(agent, messages:
  input)`) under its own trace, scores it, and records a
  `Nous.Eval.Sample`. `c:teardown/1` runs last, also after a failure.

  Samples are sorted by case id, then index. Each carries the outcome
  (`:ok`, `:error`, `:killed`, `:budget_exhausted`), the verdict, every
  score and scorer error, the trace, the usage (`Nous.Eval.Trace.usage/1`),
  the cost (each answered request priced with `Nous.Usage.cost/2`; `nil`
  when a model has no price), the duration and the iterations (from the
  root run's stop event). A sample whose agent could not be built has
  outcome `:error`, verdict `:error` and no trace.

  The run `:status` is `:completed`, `:budget_exhausted` (see below) or
  `:aborted`: the trace collector's telemetry handler was detached, so
  traces could no longer be trusted. An aborted run stops scheduling
  samples, keeps the ones that finished and says why in
  `metadata.abort_reason`; it never passes a comparison.

  ## Budgets

  `:max_tokens` and `:max_cost` (USD) bound what the run's model requests
  spend, counted from every answered request of every sample's trace
  (including turns that failed afterwards and samples later killed) plus
  the usage model-graded scorers report in `Nous.Eval.Score`'s
  `metadata.usage` (the LLM judge does). Requests are priced with
  `Nous.Usage.cost/2` at the model that answered (a fallback or a route
  counts at its own price). `:max_samples` bounds how many samples start.

  With `:max_cost`, every model the run is known to call must have a price
  (the agent's model and fallbacks, the judge model a model-graded scorer
  names in `c:Nous.Eval.Scorer.describe/1`): otherwise the run is refused
  with `{:error, {:unknown_price, "provider:model"}}` before any model call.
  An unpriced request discovered later (a routed model) exhausts the budget.
  Add prices with `config :nous, :model_prices` (see `Nous.Usage.Pricing`).

  Once a limit is reached no new sample starts; with a token or cost limit,
  running agents are cancelled at their next step (`:cancellation_check`)
  and model-graded scorers are no longer called (their scorer gets a
  `:budget_exhausted` `Nous.Eval.ScorerError`, so the sample is `:error`).
  Samples that never started or were cancelled have outcome
  `:budget_exhausted` and no verdict, and the run's status is
  `:budget_exhausted`, so partial results are never mistaken for a full
  run. A sample that finishes normally after the limit was crossed is kept,
  so the spend can exceed a limit by the requests already in flight. The
  run's `:budget` holds `limits`, what was `spent` (`tokens`, `cost`,
  `samples`, `unpriced_requests`) and which limit `exhausted` it.

  ## Errors

  `{:error, reason}` with `reason`:

    * a message string - the task module is invalid or one of its callbacks
      failed (see `Nous.Eval.Task`)
    * `:no_cases` - the filters left no case
    * `{:unknown_cases, ids}` - `:cases` names ids the filtered dataset
      does not hold
    * `{:profile, error}` - the `:profile` does not apply to the task's agent
    * `{:unknown_options, keys}` / `{:invalid_option, key, value}`
    * `{:scorer_init_failed, module, reason}` - a scorer's options are
      invalid
    * `{:unknown_price, "provider:model"}` - see "Budgets"
    * `:trace_handler_detached` / `:trace_tables_missing` - the collector
      cannot run
    * `{:store, reason}` - the store could not be opened (checked before
      `c:setup/1`)
    * `{:store_put_failed, reason, run}` - the run finished but could not be
      stored; the run is in the error
  """
  @spec run(module(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run(task_module, opts \\ []), do: Runner.run(task_module, opts)

  @doc """
  Scores a stored run's samples again with the task's current scorers,
  without running the agent, and returns a new run.

      {:ok, run} = store.get_run(state, "20261101t153012z-1a2b3c4d")
      {:ok, rescored} = Nous.Eval.rescore(run, MyApp.Evals.Refunds)

  Each sample keeps its output, trace, usage, cost and duration; scores,
  scorer errors, verdict and case score are recomputed against the task's
  current dataset entry of the same case id (every case of the run must
  still exist: `{:error, {:missing_cases, ids}}` otherwise). Samples that
  never reached the scorers (`:budget_exhausted`, or no trace) are copied
  unchanged.

  The new run has a new id, `metadata.rescored_from` set to the source
  run's id, and the source fingerprint with `"scorers"` and `"dataset"`
  replaced by the current ones (and a new `"id"`). Its dataset hash covers
  the run's cases as the task defines them now, so a rescore whose expected
  values changed is compared with the original only with
  `allow_dataset_change: true`. Model-graded scorers are called again; what
  they spend is in the new run's `:budget`.

  Options: `:parallelism`, `:store`, `:scorer_timeout` and `:metadata`, as
  for `run/2`, and `:budget` with `:max_tokens` / `:max_cost` only: it bounds
  what model-graded scorers spend, and once it is exhausted their scorers
  get `:budget_exhausted` errors (the run's status is then
  `:budget_exhausted`).
  """
  @spec rescore(Run.t(), module(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def rescore(%Run{} = run, task_module, opts \\ []), do: Runner.rescore(run, task_module, opts)

  @doc """
  Promotes stored online samples (`Nous.Eval.Online`) into a dataset file.

      {:ok, %{promoted: 2, skipped: [{"4bf9...", :no_content}]}} =
        Nous.Eval.promote({Nous.Eval.Store.File, store_state}, trace_ids,
          to: "test/eval/datasets/support.jsonl",
          redact: MyApp.TraceRedactor,
          reviewer: "alice")

  `store` is `{store_module, store_state}`; `trace_ids` name the samples.
  Each promoted sample is **redacted again** with `:redact` (required: a
  1-arity function or a `Nous.Eval.Online.Redactor` module) before
  anything is taken from it, and appended to `:to` as one JSONL line;
  the file is rewritten through a temporary file and a rename.

  Options:

    * `:to` - the dataset file (required)
    * `:redact` - the redactor (required; `:drop_content` is refused)
    * `:as` - `:case` (default): a `nous.case/1` line whose `input` is the
      root run's request (the user message, or its user/assistant turns),
      `expected` left empty: the production answer is never copied into
      the expectation. `{:guard_case, surface: s}` with `s` one of
      `"user_input"`, `"tool_call"`, `"tool_result"`, `"model_output"`
      (and optionally `tool: name` for the tool surfaces): a
      `nous.guard_case/1` line with `label: null` and `provenance.review:
      "pending"`, waiting for a human label (`Nous.Eval.Online.Review`).
      The guard's own verdict is recorded as
      `provenance.promoted_from.observed_verdict`, never as the label.
    * `:reviewer` - recorded in the provenance
    * `:instance` - the online instance (default `"default"`)
    * `:redact_timeout` - ms (default 2_000)

  Every line's provenance names the instance, run, trace, redactor and Nous
  version. A sample is skipped with a reason: `:not_found`, `:no_content`
  (stored under `:drop_content` or after a failed redaction, or without an
  input for the target), `:redaction_failed` (the redactor failed now), or
  `:duplicate` (its trace or its content is already in the file).
  """
  @spec promote({module(), term()}, [String.t()], keyword()) ::
          {:ok, %{promoted: non_neg_integer(), skipped: [{String.t(), atom()}]}}
          | {:error, term()}
  def promote(store, trace_ids, opts),
    do: Nous.Eval.Online.Promote.promote(store, trace_ids, opts)

  defmacro __using__(_opts) do
    quote do
      @behaviour Nous.Eval

      @impl Nous.Eval
      def scorers, do: []

      @impl Nous.Eval
      def setup(_opts), do: {:ok, nil}

      @impl Nous.Eval
      def teardown(_state), do: :ok

      @impl Nous.Eval
      def deps(_state), do: %{}

      defoverridable scorers: 0, setup: 1, teardown: 1, deps: 1
    end
  end
end
