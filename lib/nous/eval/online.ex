defmodule Nous.Eval.Online do
  @moduledoc """
  Online evaluation: sample production agent runs, redact them, score them
  in the background and store them, without touching the request path.

  Off by default. Add the child to your application's supervision tree:

      children = [
        {Nous.Eval.Online,
         sample_rate: 0.05,
         redact: MyApp.TraceRedactor,
         store: {Nous.Eval.Store.File, root: "/var/lib/myapp/nous-online"},
         retention: [max_age: {14, :day}],
         rules: [
           [name: "trajectory", scorers: [Nous.Eval.Scorers.NoToolErrors]],
           [name: "helpfulness", sample_rate: 0.01,
            scorers: [{Nous.Eval.Scorers.Judge, judge: "anthropic:claude-haiku-4-5-20251001",
                       rubric: "The answer resolves the user's request."}]]
         ],
         budget: [max_cost: 5.0, per: :hour]}
      ]

  The child **refuses to start** (`{:error, {:invalid_config, reason}}`, so
  the application does not boot) without a redactor, a store, a sample rate
  or a retention policy; with a model-calling scorer and no budget, or a
  model without a known price; with a rule rate above the capture rate; and
  with a scorer that reads content under `redact: :drop_content`.

  ## How a run is captured

  At the root `[:nous, :agent, :run, :start]` (no parent run; runs Nous
  starts for itself - judges, simulators, reflectors - are never sampled)
  the decision is deterministic: the trace id's low 56 bits against
  `sample_rate` (`Nous.Eval.Online.Sampler`). Sub-agent runs share the
  root's trace and are captured with it. Then the `agents` allowlist and the
  `filter` apply, and admission against `max_in_flight`. The run's events
  are collected (`Nous.Eval.Trace`); at its stop the trace is queued for a
  background job, which redacts it, scores it and hands it to the store
  writer. The request path does a few atomic counter and ETS operations and
  at most one `send/2`: no call, no wait, no allocation proportional to the
  trace. Overload drops new work and counts it.

  ## Redaction

  Every captured trace goes through `redact:` before anything else sees it:
  scorers, the store, the exporter. See `Nous.Eval.Online.Redactor` for
  the contract and `Nous.Eval.Online.Content` for what is skeleton
  (always kept: ids, names, timings, tokens, cost, outcomes, verdicts) and
  what is content (everything else, including `metadata.content_parts`). A
  failing redactor drops the sample's content and keeps the skeleton.

  ## Options

  Required:

    * `:sample_rate` - share of root runs captured, `0.0..1.0` (`0.0`
      pauses capture)
    * `:redact` - `:drop_content`, a 1-arity function, or a module
      implementing `Nous.Eval.Online.Redactor`
    * `:store` - `{store_module, init_opts}` (a `Nous.Eval.Store`)
    * `:retention` - `[max_age: {n, :second | :minute | :hour | :day}]` or
      `:infinity`; a finite retention needs a store with
      `delete_runs_before/3`

  Capture:

    * `:name` - registered name (default `Nous.Eval.Online`); one instance
      per name per node
    * `:instance` - instance name stored with the samples (default
      `"default"`; `a-z`, `0-9`, `_`, `-`)
    * `:sample_by` - `:trace` (default) or `:session`: sample whole
      sessions by the run's `session_id` (`deps[:session_id]`, or the
      `Nous.AgentServer` session), falling back to the trace id when a run
      has none
    * `:sampling_salt` - a secret binary of at least 16 bytes (e.g.
      `:crypto.strong_rand_bytes(32)`, from runtime config) keying the
      `sample_by: :session` decision (HMAC-SHA-256 of the session id; only
      with `sample_by: :session`). Without it the decision is a public
      function of the session id (`sampled?/2`): a client that picks its
      own session ids can choose ones that are never sampled. Changing the
      salt changes which sessions are sampled
    * `:agents` - only capture root runs of these agent names (strings)
    * `:filter` - `fn run_start_metadata -> boolean end`, called on the
      request path for runs the rate admitted: keep it cheap and pure. A
      raise or a non-boolean is "not captured" and counted `filter_error`

  Scoring:

    * `:rules` - a list of `[name: string, scorers: [...], sample_rate:
      rate, when: fun]`. `scorers` are modules, `{module, opts}` or
      `Nous.Eval.Scorer.Spec`s. A rule's `sample_rate` (default: the
      capture rate) must not exceed `:sample_rate`; the rule scores the
      captured traces its own rate admits (the same deterministic rule, so
      a subset). `when` receives the redacted `Nous.Eval.Sample`
    * `:budget` - required when a scorer calls a model (`kind/0` is
      `:model_graded`): `[max_cost: usd, per: :minute | :hour | :day | ms,
      reserve_tokens: [input: 16_000, output: 2_000]]`. Each model-graded
      scorer names its model in its `:judge` or `:model` option, which must
      have a price (`Nous.Usage.cost/2`). Before each call its worst case
      (`reserve_tokens` per request, two requests per judge sample) is
      reserved; a call that does not fit the window is skipped
      (`skipped: {"<rule>/<scorer>", "budget_exhausted"}`), never run.
      The reservation is fixed, not derived from the judge:
      `reserve_tokens[:input]` must cover the judge's largest request, about
      (`max_transcript_bytes` × message-list spans + `max_span_bytes` ×
      other spans) ÷ ~3 bytes per token. With the judge defaults
      (`max_transcript_bytes: 40_000`), a transcript judge's ~10k tokens
      fit the default 16_000
    * `:score_timeout` - ms per scorer (default 30_000)

  Bounds (see "Backpressure"):

    * `:max_in_flight` - captured traces not yet finalized (default 200)
    * `:max_queue` - finalize jobs waiting (default 1_000)
    * `:max_concurrency` - jobs running at once (default 4)
    * `:max_events` / `:max_bytes` - per trace, then it is truncated
      (defaults 2_000 / 4_000_000)
    * `:redact_timeout` - ms per redactor call (default 2_000)
    * `:max_trace_age` - ms after which a run that never stopped is stored
      as abandoned (default 15 minutes)

  Store and export:

    * `:batch_size` - samples per stored run (default 100); a partial batch
      is written every `:window_ms`
    * `:store_retries` / `:store_backoff` - write attempts (default 3) and
      the ms between them, growing linearly (default 1_000)
    * `:prune_interval` - ms between retention prunes (default 1 hour; also
      at start)
    * `:exporter` - `fn sample -> any end` called with every stored
      (redacted) sample, e.g. `Nous.Eval.Online.OTel.exporter/1`
    * `:window_ms` - the coverage window (default 1 minute);
      `:sweep_interval` - ms between abandoned-run sweeps and handler checks
      (default 10_000)

  ## Backpressure

  | Stage | Bound | Overflow |
  |---|---|---|
  | capture | `max_in_flight` | not captured, `dropped_admission` |
  | trace size | `max_events`, `max_bytes` | trace `truncated?` |
  | finalize queue | `max_queue` | events discarded, `dropped_queue` |
  | jobs | `max_concurrency` | wait in the queue |
  | model spend | `budget` | scorer skipped, `skipped_budget` |
  | redactor, scorers | `redact_timeout`, `score_timeout` | content dropped / `:timeout` error |
  | store | `store_retries` | batch dropped, `dropped_store` |

  Worst-case memory is about `max_in_flight * max_bytes` plus
  `max_concurrency` traces being processed. Every window emits
  `[:nous, :eval, :online, :window]` with what was seen, captured, dropped,
  scored and stored, so the effective capture rate under overload is known
  (see `Nous.Telemetry`).

  ## Storage

  Samples are stored as `Nous.Eval.Run`s of task `"online:<instance>"`
  (`task/1`), one run per batch, each sample's case id being its trace id.
  The run's `metadata["online"]["samples"]` holds, per trace id,
  `captured_at`, `redaction` (`"redacted"`, `"dropped"` or `"failed"`, with
  `redaction_failure`), `explanations`, the applied `rules`, `abandoned`
  and a `group` hash (of the session, else the trace). Scores are named
  `"<rule>/<score>"`; a sample's verdict is the worst per-scorer verdict.
  The coordinator is the only writer of the store on its node: give each
  node its own File root or database file. Read samples back with
  `list/2`, promote them to datasets with `Nous.Eval.promote/3`.

  ## Multiple nodes

  Each node samples, scores, budgets and stores on its own. Sampling is
  deterministic, so all nodes agree on which traces are captured; divide
  the cluster's budget by the node count.
  """

  use Supervisor

  alias Nous.Eval.Online.{Config, Coordinator, Promote, Registry, Sampler}
  alias Nous.Eval.{Run, Sample}

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts an instance. Returns `{:error, {:invalid_config, reason}}` for an
  invalid or incomplete configuration (see "Options").
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | {:error, {:invalid_config, term()}}
  def start_link(opts) do
    with {:ok, config} <- Config.new(opts) do
      Supervisor.start_link(__MODULE__, config, name: config.name)
    end
  end

  @impl true
  def init(config) do
    children = [
      {Registry, config},
      {Task.Supervisor,
       name: Coordinator.task_sup(config.name), max_children: config.max_concurrency},
      {Task.Supervisor, name: Coordinator.scorer_sup(config.name)},
      {Coordinator, config}
    ]

    # The registry owns the tables the coordinator works on: if it goes,
    # everything after it restarts with the new tables.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "The store task of an instance's runs: `\"online:\" <> instance`."
  @spec task(String.t()) :: String.t()
  def task(instance) when is_binary(instance), do: "online:" <> instance

  @doc "Whether `trace_id` is sampled at `rate` (see `Nous.Eval.Online.Sampler`)."
  @spec sampled?(String.t(), number()) :: boolean()
  defdelegate sampled?(trace_id, rate), to: Sampler

  @doc """
  Waits until every queued trace has been processed and the current batch
  is written. Runs still in progress are not waited for. For tests and
  graceful shutdown.
  """
  @spec drain(atom(), timeout()) :: :ok
  def drain(name \\ __MODULE__, timeout \\ 30_000),
    do: GenServer.call(Coordinator.name(name), :drain, timeout)

  @doc """
  Applies the retention policy now. Returns `{:ok, deleted_runs}`
  (`{:ok, 0}` with `retention: :infinity`).
  """
  @spec prune(atom()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(name \\ __MODULE__), do: GenServer.call(Coordinator.name(name), :prune, 60_000)

  @doc """
  Runs the periodic housekeeping now: the abandoned-run sweep, the handler
  check and the coverage window report.
  """
  @spec tick(atom()) :: :ok
  def tick(name \\ __MODULE__), do: Registry.tick(name)

  @doc """
  The stored online samples of an instance, oldest batch first.

  `store` is `{store_module, store_state}` (from the module's `init/1`).
  Each entry is `%{run_id, sample, info}` with `info` the sample's entry of
  the run's `metadata["online"]["samples"]` (see "Storage").

  Options: `:instance` (default `"default"`), `:since` / `:until`
  (`DateTime`, on the batch's start), `:ids` (trace ids), `:outcome`
  (`:ok | :error | :killed`), `:verdict`, `:rule` (applied rule name),
  `:score_below` (`{score_name, float}`: samples whose score converts to a
  float below it).
  """
  @spec list({module(), term()}, keyword()) ::
          {:ok, [%{run_id: String.t(), sample: Sample.t(), info: map()}]} | {:error, term()}
  def list({module, state}, opts \\ []) do
    instance = Keyword.get(opts, :instance, "default")
    filters = [task: task(instance)] ++ Keyword.take(opts, [:since, :until])

    with {:ok, summaries} <- module.list_runs(state, filters) do
      summaries
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, []}, fn summary, {:ok, acc} ->
        case module.get_run(state, summary.id) do
          {:ok, run} -> {:cont, {:ok, acc ++ entries(run, opts)}}
          {:error, :not_found} -> {:cont, {:ok, acc}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp entries(%Run{id: id, samples: samples, metadata: metadata}, opts) do
    infos = get_in(metadata, ["online", "samples"]) || %{}

    for %Sample{} = sample <- samples,
        info = Map.get(infos, sample.trace_id, %{}),
        Promote.matches?(sample, info, opts),
        do: %{run_id: id, sample: sample, info: info}
  end
end
