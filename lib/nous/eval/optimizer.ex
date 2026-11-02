defmodule Nous.Eval.Optimizer do
  @moduledoc """
  Improves an agent's text (its instructions and tool descriptions) against
  an eval task, and produces a reviewed `Nous.Profile` rather than editing
  code.

      {:ok, result} =
        Nous.Eval.Optimizer.run(MyApp.Evals.Support,
          reflector: "openai:gpt-4o",
          components: ["instructions", "tool:search_orders"],
          budget: [max_cost: 5.0, max_metric_calls: 2_000],
          k: 3,
          store: {Nous.Eval.Store.File, root: ".nous/eval"},
          name: "support_agent"
        )

      result.verdict                                       #=> :accepted
      Nous.Eval.ProfileReport.render(result.report, format: :markdown)

  The accepted profile is applied with `Nous.new(..., profile: profile)`;
  nothing is deployed automatically.

  ## Splits

  Every case needs a split (`Nous.Eval.Dataset` assigns them by group):

    * **train** feeds the search: reflection minibatches (GEPA) or the
      fixed scoring subset (OPRO). Only train cases' text reaches the
      reflector.
    * **val** scores candidates for the Pareto pool and picks the best
      (GEPA). The reflector only ever sees val **scores**.
    * **test** is used once, for the accept/reject decision. No strategy
      sees it.

  Cases tagged `"guard"` (in any split) are the guard cases: a candidate
  must not regress them (see "Guard non-regression").

  ## Acceptance (on test)

  The best candidate and the seed are both evaluated on the test split
  with `k` samples per case, and compared with `Nous.Eval.Compare` on the
  gate metrics `[:case_score, :pass_rate]` (paired cluster bootstrap over
  cases, Holm across the two metrics, `alpha` default 0.05):

    1. **No regression**: `compare(seed, candidate)` must be `:pass` (no
       metric significantly worse, candidate error rate within
       `max_error_rate`, default 0).
    2. **Improvement**: `compare(candidate, seed)` must be `:regression`,
       i.e. on at least one gate metric the seed is significantly worse
       than the candidate (Holm-adjusted one-sided test at `alpha`), and
       an exact one-sided sign test on the test cases the candidate
       improved versus worsened (by pass rate) must have p below `alpha`.
       The bootstrap alone is anti-conservative on tiny splits; the sign
       test sets the floor: at alpha 0.05 the smallest test split that can
       pass is 5 cases, all improved (p = 0.5^5 = 0.03125).
    3. **Guard non-regression** on the test split's guard cases.

  Only then is the verdict `:accepted` and, with a `:store`, the profile
  persisted (`put_profile/2`). A rejected optimization still returns the
  report, so the evidence can be read.

  ## Feedback policy

  `feedback: :diagnostic` (default) shows the reflector, per train case,
  the scorer names, pass/fail, values and reasons, the paths of
  mismatched arguments, the names of expected tools that were not called
  and a judge's critique, but never a case's `expected` values, a rubric
  or judge prompt; reasons that quote them are withheld. This keeps the
  optimizer from writing answers or grader wording into the agent's text.
  `feedback: :with_expected` adds each train case's `expected` map (GEPA's
  default); it is recorded in the profile's provenance. Either way the
  lint (`Nous.Eval.Optimizer.Lint`) rejects proposals that repeat held-out
  text or carry fence markers.

  ## Budget

  `budget:` is required: `[max_tokens: n, max_cost: usd, max_metric_calls:
  n]` (at least one). Metric calls are samples run (cases × k). Every
  evaluation and reflector call is charged; with `max_cost`, an unpriced
  agent or reflector model is refused before any call. The measured cost of
  the seed's test evaluation is reserved for the final acceptance test, and
  a budget that cannot cover the seed's validation and test evaluations is
  refused (`{:error, {:budget_too_small, details}}`) — before any model
  call when `max_metric_calls` alone shows it.

  ## Options

    * `:reflector` - model string or keyword (required; see
      `Nous.Eval.Optimizer.Reflector`)
    * `:budget` - see above (required)
    * `:strategy` - `:gepa` (default), `:opro`, or a module implementing
      `Nous.Eval.Optimizer.Strategy`; `:strategy_opts` for it
    * `:components` - component keys to optimize (`Nous.Profile` grammar);
      default: the instructions (when static) and every app tool's
      description
    * `:max_steps` - search steps (default 20)
    * `:k` - samples per case (default 3)
    * `:minibatch_size` - GEPA train minibatch (default 3)
    * `:mode` - GEPA component selection, `:round_robin` (default),
      `:all` or `:coupled`
    * `:merge` - GEPA merges allowed (default 0)
    * `:seed` - integer seed for every random choice and sample seed
      (default 0)
    * `:feedback` - `:diagnostic` (default) or `:with_expected`
    * `:alpha`, `:max_error_rate` - acceptance test settings
    * `:guard` - a `fn before_eval, after_eval -> :ok | {:error, reason}`
      over guard-case evaluations (default
      `Nous.Eval.Optimizer.Context.guard_non_regression/2`), or `nil` to
      disable
    * `:adapter` - `{module, opts}` (default
      `{Nous.Eval.Optimizer.AgentAdapter, []}`)
    * `:store` - `{store_module, init_opts}` to persist an accepted profile
    * `:name` - the profile name (`~r/\\A[a-z0-9][a-z0-9_.-]{0,63}\\z/`)
  """

  alias Nous.Eval.Budget

  alias Nous.Eval.Optimizer.{
    AgentAdapter,
    Candidate,
    Context,
    Evaluation,
    Ledger,
    Lint,
    Reflector,
    Result
  }

  alias Nous.Eval.Optimizer.Strategies.{GEPA, OPRO}
  alias Nous.Eval.{Compare, ProfileReport}
  alias Nous.Eval.Stats.Hypothesis
  alias Nous.Profile

  @gate_metrics [:case_score, :pass_rate]
  @strategies %{gepa: GEPA, opro: OPRO}
  @name ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/

  @defaults [
    strategy: :gepa,
    strategy_opts: [],
    components: nil,
    max_steps: 20,
    k: 3,
    minibatch_size: 3,
    mode: :round_robin,
    merge: 0,
    seed: 0,
    feedback: :diagnostic,
    alpha: 0.05,
    max_error_rate: 0.0,
    guard: :default,
    adapter: {AgentAdapter, []},
    store: nil,
    name: nil,
    reflector: nil,
    budget: nil
  ]

  @doc """
  Runs an optimization for `task_module` (a `use Nous.Eval` task). See the
  moduledoc for options. Returns `{:ok, %Nous.Eval.Optimizer.Result{}}`
  (accepted or rejected) or `{:error, reason}` for a configuration or
  operational problem.
  """
  @spec run(module(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(task_module, opts) when is_list(opts) do
    with {:ok, opts} <- validate(opts),
         {adapter, adapter_opts} = opts[:adapter],
         {:ok, adapter_state} <- adapter.init(task_module, adapter_opts),
         agent = adapter.agent(adapter_state),
         {:ok, splits} <- splits(adapter.cases(adapter_state)),
         base_text = Profile.components(Profile.apply!(nil, agent)),
         {:ok, components} <- components(opts[:components], base_text),
         {:ok, reflector} <- Reflector.new(opts[:reflector]),
         {:ok, limits} <- Ledger.limits(opts[:budget]),
         :ok <- price_preflight(limits, [agent.model, reflector.model]),
         :ok <- metric_calls_cover_seed(limits, splits, opts[:k]),
         {:ok, seed} <- seed_profile(components, base_text, agent, opts) do
      cache = :ets.new(:nous_optimizer, [:set, :public])

      try do
        ctx = %Context{
          adapter: adapter,
          adapter_state: adapter_state,
          agent: agent,
          ledger: Ledger.new(limits),
          reflector: reflector,
          cache: cache,
          name: opts[:name],
          train: splits.train,
          val: splits.val,
          guard_cases: splits.guard,
          components: components,
          base_text: base_text,
          k: opts[:k],
          minibatch_size: opts[:minibatch_size],
          seed: opts[:seed],
          rng: :rand.seed_s(:exsss, opts[:seed]),
          feedback: opts[:feedback],
          mode: opts[:mode],
          merge: opts[:merge],
          guard: guard_fun(opts[:guard]),
          heldout: Lint.heldout_windows(splits.heldout_cases),
          provenance: provenance(opts, reflector),
          strategy_opts: opts[:strategy_opts]
        }

        optimize(ctx, seed, splits, opts)
      after
        :ets.delete(cache)
      end
    end
  end

  def run(_task_module, other), do: {:error, {:invalid_option, :opts, other}}

  # A cost budget needs a price for every model the optimization pays for.
  defp price_preflight(limits, models),
    do: Budget.preflight(%{max_cost: limits.max_cost, max_tokens: nil, max_samples: nil}, models)

  defp optimize(ctx, seed, splits, opts) do
    strategy = Map.get(@strategies, opts[:strategy], opts[:strategy])
    seed_candidate = %Candidate{profile: seed}

    with {:ok, seed_test} <- seed_test(ctx, seed, splits.test),
         {:ok, state} <- strategy_init(strategy, seed_candidate, ctx) do
      {state, steps, stop_reason} = loop(strategy, state, ctx, 0, opts[:max_steps])
      summary = strategy.summary(state)
      best = strategy.best(state)

      result = %Result{
        verdict: :rejected,
        seed_profile: seed,
        candidates: summary.candidates,
        rejections: summary.rejections,
        steps: steps,
        stop_reason: stop_reason
      }

      result =
        if Candidate.id(best) == seed.id,
          do: %{result | reasons: ["no candidate improved on the seed during the search"]},
          else: accept(ctx, best, seed_test, splits, opts, result)

      {:ok, %{result | budget: Ledger.report(ctx.ledger), run_ids: Context.run_ids(ctx)}}
    end
  end

  # The seed's test evaluation runs first: its measured spend is reserved
  # for the acceptance test of the final candidate.
  defp seed_test(ctx, seed, test_ids) do
    case Context.evaluate(ctx, seed, test_ids, "test") do
      {:ok, evaluation} ->
        Ledger.reserve(ctx.ledger, %{
          tokens: evaluation.tokens,
          cost: evaluation.cost,
          metric_calls: evaluation.metric_calls
        })

        {:ok, evaluation}

      {:error, :budget_exhausted} ->
        {:error, {:budget_too_small, %{phase: :seed_test, budget: Ledger.report(ctx.ledger)}}}

      {:error, {:evaluation_failed, reason}} ->
        {:error, reason}
    end
  end

  defp strategy_init(strategy, seed, ctx) do
    case strategy.init(seed, ctx) do
      {:ok, state} ->
        {:ok, state}

      {:error, :budget_exhausted} ->
        {:error,
         {:budget_too_small, %{phase: :seed_selection, budget: Ledger.report(ctx.ledger)}}}

      {:error, {:evaluation_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp loop(_strategy, state, _ctx, steps, max) when steps >= max, do: {state, steps, :max_steps}

  defp loop(strategy, state, ctx, steps, max) do
    if Ledger.exhausted?(ctx.ledger, :search) do
      {state, steps, :budget_exhausted}
    else
      case strategy.step(state, %{ctx | step: steps + 1}) do
        {:cont, state} -> loop(strategy, state, ctx, steps + 1, max)
        {:halt, reason, state} -> {state, steps + 1, reason}
      end
    end
  end

  # ── acceptance ─────────────────────────────────────────────────────────

  defp accept(ctx, best, seed_test, splits, opts, result) do
    profile = %{
      best.profile
      | provenance: Map.merge(best.profile.provenance, %{"run_ids" => Context.run_ids(ctx)})
    }

    result = %{result | profile: profile}

    case Context.evaluate(ctx, best.profile, splits.test, "test", :final) do
      {:ok, best_test} ->
        decide(ctx, profile, seed_test, best_test, splits, opts, result)

      {:error, reason} ->
        report(
          ctx,
          %{result | reasons: ["the acceptance test could not run: #{inspect(reason)}"]},
          nil,
          []
        )
    end
  end

  defp decide(ctx, profile, seed_test, best_test, splits, opts, result) do
    gate = %{
      metrics: @gate_metrics,
      margin: 0.0,
      alpha: opts[:alpha],
      max_error_rate: opts[:max_error_rate]
    }

    with {:ok, comparison} <-
           Compare.compare(seed_test.run, best_test.run, gate: gate, seed: opts[:seed]),
         {:ok, improvement} <-
           Compare.compare(best_test.run, seed_test.run,
             gate: %{gate | max_error_rate: 1.0},
             seed: opts[:seed]
           ) do
      guard = test_guard(ctx, seed_test, best_test, splits)
      sign_test = sign_test(improvement)
      improved? = improvement.verdict == :regression and sign_test.p_value < opts[:alpha]

      reasons =
        [
          comparison.verdict != :pass &&
            "the candidate is not free of regressions on test (#{comparison.verdict}: #{Enum.join(comparison.reasons, "; ")})",
          not improved? &&
            "no significant improvement on test (#{Enum.join(Enum.map(@gate_metrics, &Atom.to_string/1), ", ")}, Holm, alpha #{opts[:alpha]}; exact sign test p = #{format_p(sign_test.p_value)}, n = #{sign_test.b + sign_test.c})",
          match?({:error, _}, guard) && "guard cases regressed: #{inspect(elem(guard, 1))}"
        ]
        |> Enum.filter(& &1)

      verdict = if reasons == [], do: :accepted, else: :rejected

      result = %{
        result
        | verdict: verdict,
          reasons: reasons,
          comparison: comparison,
          improvement: improvement,
          sign_test: sign_test,
          guard: guard
      }

      gates = [
        %{name: "no regression on test", passed?: comparison.verdict == :pass, detail: nil},
        %{
          name: "significant improvement on test",
          passed?: improved?,
          detail: sign_test_detail(sign_test)
        },
        %{
          name: "guard non-regression",
          passed?: not match?({:error, _}, guard),
          detail: guard_detail(guard)
        }
      ]

      result
      |> then(&report(ctx, &1, comparison, gates))
      |> persist(profile, opts)
    else
      {:error, reason} ->
        report(
          ctx,
          %{result | reasons: ["the acceptance comparison failed: #{inspect(reason)}"]},
          nil,
          []
        )
    end
  end

  # Exact one-sided sign test on the per-case discordant pairs. `improvement`
  # compares the candidate (baseline) with the seed (candidate), so a negative
  # delta is a case the candidate improved.
  defp sign_test(improvement) do
    deltas = for %{delta: d} <- improvement.cases, is_number(d), do: d
    b = Enum.count(deltas, &(&1 < 0))
    c = Enum.count(deltas, &(&1 > 0))
    {:ok, %{p_value: two_sided}} = Hypothesis.mcnemar(b, c)
    %{b: b, c: c, p_value: if(b > c, do: two_sided / 2, else: 1.0)}
  end

  defp sign_test_detail(%{b: b, c: c, p_value: p}),
    do: "exact sign test: #{b} improved, #{c} worsened, one-sided p = #{format_p(p)}"

  defp format_p(p), do: :erlang.float_to_binary(p * 1.0, decimals: 4)

  defp test_guard(%Context{guard: nil}, _seed_test, _best_test, _splits), do: :skipped

  defp test_guard(ctx, seed_test, best_test, splits) do
    case Enum.filter(splits.test, &(&1 in splits.guard)) do
      [] ->
        :skipped

      ids ->
        ctx.guard.(
          Evaluation.take(seed_test, ids, "guard"),
          Evaluation.take(best_test, ids, "guard")
        )
    end
  end

  defp guard_detail(:skipped), do: "no guard cases on test"
  defp guard_detail(:ok), do: nil
  defp guard_detail({:error, reason}), do: inspect(reason)

  defp report(ctx, %Result{} = result, comparison, gates) do
    evidence =
      [
        decision: if(result.verdict == :accepted, do: :accept, else: :reject),
        split: "test",
        gates: gates
      ] ++
        if(comparison, do: [comparison: comparison], else: [])

    case ProfileReport.build(nil, result.profile, evidence, agent: ctx.agent) do
      {:ok, report} -> %{result | report: report}
      {:error, _} -> result
    end
  end

  defp persist(%Result{verdict: :accepted} = result, profile, opts) do
    case opts[:store] do
      nil ->
        result

      {module, init_opts} ->
        with {:ok, state} <- module.init(init_opts),
             true <-
               function_exported?(module, :put_profile, 2) || {:error, :store_without_profiles},
             {:ok, stored, _state} <- module.put_profile(state, profile) do
          %{result | profile: stored, stored?: true}
        else
          error ->
            %{
              result
              | reasons: result.reasons ++ ["the profile could not be stored: #{inspect(error)}"]
            }
        end
    end
  end

  defp persist(result, _profile, _opts), do: result

  # ── setup ──────────────────────────────────────────────────────────────

  defp validate(opts) do
    case Keyword.validate(opts, @defaults) do
      {:ok, opts} -> check(opts)
      {:error, unknown} -> {:error, {:unknown_options, unknown}}
    end
  end

  defp check(opts) do
    Enum.find_value(opts, {:ok, opts}, fn {key, value} ->
      if valid?(key, value), do: nil, else: {:error, {:invalid_option, key, value}}
    end)
  end

  defp valid?(:strategy, s),
    do:
      Map.has_key?(@strategies, s) or
        (is_atom(s) and Code.ensure_loaded?(s) and function_exported?(s, :step, 2))

  defp valid?(:strategy_opts, o), do: Keyword.keyword?(o)
  defp valid?(:components, nil), do: true
  defp valid?(:components, c), do: is_list(c) and c != [] and Enum.all?(c, &is_binary/1)
  defp valid?(key, n) when key in [:max_steps, :k, :minibatch_size], do: is_integer(n) and n > 0
  defp valid?(:merge, n), do: is_integer(n) and n >= 0
  defp valid?(:mode, m), do: m in [:round_robin, :all, :coupled]
  defp valid?(:seed, s), do: is_integer(s)
  defp valid?(:feedback, f), do: f in [:diagnostic, :with_expected]
  defp valid?(:alpha, a), do: is_number(a) and a > 0 and a < 1
  defp valid?(:max_error_rate, r), do: is_number(r) and r >= 0 and r <= 1
  defp valid?(:guard, g), do: g in [:default, nil] or is_function(g, 2)
  defp valid?(:adapter, {m, o}), do: is_atom(m) and is_list(o)
  defp valid?(:store, nil), do: true
  defp valid?(:store, {m, o}), do: is_atom(m) and is_list(o)
  defp valid?(:name, nil), do: true
  defp valid?(:name, n), do: is_binary(n) and Regex.match?(@name, n)
  defp valid?(:reflector, nil), do: false
  defp valid?(:reflector, _r), do: true
  defp valid?(:budget, b), do: is_list(b)
  defp valid?(_key, _value), do: false

  defp splits(cases) do
    by_split = Enum.group_by(cases, & &1.split)
    ids = fn split -> by_split |> Map.get(split, []) |> Enum.map(& &1.id) end

    case Enum.find(["train", "val", "test"], &(ids.(&1) == [])) do
      nil ->
        {:ok,
         %{
           train: ids.("train"),
           val: ids.("val"),
           test: ids.("test"),
           guard: for(c <- cases, "guard" in c.tags, do: c.id),
           heldout_cases: Map.get(by_split, "val", []) ++ Map.get(by_split, "test", [])
         }}

      missing ->
        {:error, {:missing_split, missing}}
    end
  end

  defp components(nil, base_text) do
    case Map.keys(base_text)
         |> Enum.filter(&(&1 == "instructions" or not String.contains?(&1, "#")))
         |> Enum.sort() do
      [] -> {:error, :no_components}
      keys -> {:ok, keys}
    end
  end

  defp components(keys, base_text) do
    case Enum.reject(keys, &Map.has_key?(base_text, &1)) do
      [] -> {:ok, Enum.uniq(keys)}
      unknown -> {:error, {:unknown_components, unknown}}
    end
  end

  defp metric_calls_cover_seed(%{max_metric_calls: nil}, _splits, _k), do: :ok

  defp metric_calls_cover_seed(%{max_metric_calls: max}, splits, k) do
    needed = (length(splits.val) + length(splits.test)) * k

    if max >= needed,
      do: :ok,
      else:
        {:error, {:budget_too_small, %{phase: :preflight, max_metric_calls: max, needed: needed}}}
  end

  # The seed carries the base text of every optimized component, so its
  # behaviour is the agent's own and children differ only where changed.
  defp seed_profile(components, base_text, agent, opts) do
    seed = %Profile{
      id: nil,
      name: opts[:name],
      components: Map.take(base_text, components),
      manifest: %{},
      provenance: %{"source" => "optimizer", "note" => "seed: the agent's base text"}
    }

    case Profile.seal(seed, agent) do
      {:ok, sealed} -> {:ok, sealed}
      {:error, error} -> {:error, {:invalid_components, Exception.message(error)}}
    end
  end

  defp guard_fun(:default), do: &Context.guard_non_regression/2
  defp guard_fun(nil), do: nil
  defp guard_fun(fun) when is_function(fun, 2), do: fun

  defp provenance(opts, reflector) do
    %{
      "source" => "optimizer",
      "strategy" => strategy_name(opts[:strategy]),
      "seed" => opts[:seed],
      "k" => opts[:k],
      "feedback" => Atom.to_string(opts[:feedback]),
      "reflector" => reflector.model
    }
  end

  defp strategy_name(s) when is_map_key(@strategies, s), do: Atom.to_string(s)
  defp strategy_name(module), do: inspect(module)
end
