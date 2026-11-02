defmodule Nous.Eval.Optimizer.Context do
  @moduledoc """
  What a `Nous.Eval.Optimizer.Strategy` searches with: the splits, the
  components it may change, and helpers that do the budget accounting and
  enforce the split and safety rules.

    * `evaluate/4` evaluates a profile on case ids (train, val or the
      guard cases), charging the budget; it returns
      `{:error, :budget_exhausted}` once the search budget is spent
    * `propose/4` asks the reflector for new text for some components from
      a train evaluation's records, then lints it (`Nous.Eval.Optimizer.Lint`)
    * `generate/4` asks for whole new versions (OPRO), each linted
    * `derive/4` turns proposed text into a sealed child profile
    * `feasible/3` runs the guard filter on a candidate

  Fields a strategy reads: `:train`, `:val` (case ids), `:components`,
  `:base_text` (component key => the agent's base text), `:k`,
  `:minibatch_size`, `:seed`, `:rng`, `:mode` (`:round_robin | :all |
  :coupled`), `:merge` (max merges, `0` disables), `:step`, plus
  strategy-specific `:strategy_opts`.
  """

  alias Nous.Eval.Optimizer.{Candidate, Evaluation, Ledger, Lint, Reflector}
  alias Nous.Profile

  @enforce_keys [:adapter, :adapter_state, :agent, :ledger, :reflector]
  defstruct [
    :adapter,
    :adapter_state,
    :agent,
    :ledger,
    :reflector,
    :cache,
    :name,
    train: [],
    val: [],
    guard_cases: [],
    components: [],
    base_text: %{},
    k: 1,
    minibatch_size: 3,
    seed: 0,
    rng: nil,
    feedback: :diagnostic,
    mode: :round_robin,
    merge: 0,
    guard: nil,
    heldout: MapSet.new(),
    step: 0,
    provenance: %{},
    strategy_opts: []
  ]

  @type t :: %__MODULE__{}

  @doc """
  Evaluates `profile` on `case_ids`, labelled `split`, within what is left
  of the search budget (the `:final` phase may also use the reserve held
  back for the acceptance test).

  Returns `{:ok, evaluation}` for a completed evaluation,
  `{:error, :budget_exhausted}`, or `{:error, {:evaluation_failed, reason}}`
  for an operational failure (the strategy should halt with it).
  """
  @spec evaluate(t(), Profile.t(), [String.t()], String.t(), :search | :final) ::
          {:ok, Evaluation.t()} | {:error, term()}
  def evaluate(%__MODULE__{} = ctx, %Profile{} = profile, case_ids, split, phase \\ :search) do
    case Ledger.remaining(ctx.ledger, phase) do
      :exhausted ->
        {:error, :budget_exhausted}

      {:ok, budget} ->
        batch = %{
          case_ids: case_ids,
          split: split,
          k: ctx.k,
          budget: budget,
          feedback: ctx.feedback,
          seed: ctx.seed
        }

        case ctx.adapter.evaluate(ctx.adapter_state, profile, batch) do
          {:ok, %Evaluation{} = evaluation} ->
            Ledger.charge(ctx.ledger, %{
              tokens: evaluation.tokens,
              cost: evaluation.cost,
              metric_calls: evaluation.metric_calls
            })

            record_run(ctx, evaluation)

            case evaluation.status do
              :completed -> {:ok, evaluation}
              :budget_exhausted -> {:error, :budget_exhausted}
              other -> {:error, {:evaluation_failed, {:status, other}}}
            end

          {:error, reason} ->
            {:error, {:evaluation_failed, reason}}
        end
    end
  end

  @doc """
  Proposes new text for `keys` of `parent` from a train evaluation's
  reflective records. Returns `{:ok, %{key => text}}` or `{:error, reason}`
  (`:budget_exhausted`, `:unparseable`, `:unrequested_component`,
  `:empty_proposal`, `{:heldout_leak, key}`, `{:fence_marker, key}`, ...).
  Text identical to the parent's is dropped; a proposal that changes
  nothing is `{:error, :no_change}`.
  """
  @spec propose(t(), Candidate.t(), Evaluation.t(), [String.t()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def propose(
        %__MODULE__{} = ctx,
        %Candidate{} = parent,
        %Evaluation{split: "train"} = eval,
        keys
      ) do
    records = ctx.adapter.reflective_records(eval, keys)
    current = current_text(ctx, parent.profile)

    with {:ok, updates} <- Reflector.reflect(ctx.reflector, current, records, keys, ctx.ledger),
         :ok <- Lint.check(updates, ctx.heldout) do
      changed(updates, current)
    end
  end

  @doc """
  Asks for `n` complete versions of every component from scored `history`
  (`[{profile, score}]`, best first) and example train inputs. Versions
  that fail the lint or change nothing are dropped and reported as
  rejections: `{:ok, versions, rejections}`.
  """
  @spec generate(t(), [{Profile.t(), float()}], [String.t()], pos_integer()) ::
          {:ok, [%{String.t() => String.t()}], [term()]} | {:error, term()}
  def generate(%__MODULE__{} = ctx, history, inputs, n) do
    texts = Enum.map(history, fn {profile, score} -> {current_text(ctx, profile), score} end)

    with {:ok, versions} <-
           Reflector.generate(ctx.reflector, texts, inputs, ctx.components, n, ctx.ledger) do
      known = MapSet.new(texts, fn {text, _} -> text end)

      {kept, rejected} =
        Enum.reduce(versions, {[], []}, fn version, {kept, rejected} ->
          full = Map.merge(ctx.base_text |> Map.take(ctx.components), version)

          cond do
            MapSet.member?(known, full) ->
              {kept, [:no_change | rejected]}

            match?({:error, _}, Lint.check(version, ctx.heldout)) ->
              {:error, reason} = Lint.check(version, ctx.heldout)
              {kept, [reason | rejected]}

            true ->
              {[version | kept], rejected}
          end
        end)

      {:ok, Enum.reverse(kept), Enum.reverse(rejected)}
    end
  end

  @doc """
  The child of `parent` with `updates` applied, sealed against the agent,
  named like the optimization and carrying the optimizer's provenance.
  """
  @spec derive(t(), Profile.t(), %{String.t() => String.t()}, map()) ::
          {:ok, Profile.t()} | {:error, term()}
  def derive(%__MODULE__{} = ctx, %Profile{} = parent, updates, provenance \\ %{}) do
    child = %Profile{
      id: nil,
      name: ctx.name,
      parent_id: parent.id,
      components: Map.merge(parent.components, updates),
      manifest: %{},
      provenance: Map.merge(ctx.provenance, provenance)
    }

    case Profile.seal(child, ctx.agent) do
      {:ok, sealed} -> {:ok, sealed}
      {:error, error} -> {:error, {:invalid_proposal, Exception.message(error)}}
    end
  end

  @doc """
  The guard filter: `:ok` when `child` does not regress the guard-tagged
  cases relative to `parent` (or there are none), `{:error, reason}`
  otherwise. Evaluations of the guard cases are cached per profile.
  """
  @spec feasible(t(), Candidate.t(), Profile.t()) :: :ok | {:error, term()}
  def feasible(%__MODULE__{guard_cases: []}, _parent, _child), do: :ok
  def feasible(%__MODULE__{guard: nil}, _parent, _child), do: :ok

  def feasible(%__MODULE__{} = ctx, %Candidate{} = parent, %Profile{} = child) do
    with {:ok, before} <- guard_evaluation(ctx, parent.profile),
         {:ok, after_} <- guard_evaluation(ctx, child) do
      ctx.guard.(before, after_)
    end
  end

  defp guard_evaluation(ctx, profile) do
    case :ets.lookup(ctx.cache, {:guard, profile.id}) do
      [{_, evaluation}] ->
        {:ok, evaluation}

      [] ->
        with {:ok, evaluation} <- evaluate(ctx, profile, ctx.guard_cases, "guard") do
          :ets.insert(ctx.cache, {{:guard, profile.id}, evaluation})
          {:ok, evaluation}
        end
    end
  end

  @doc """
  The default guard filter: on every guard-tagged case, the share of
  samples whose `guard_verdict` scores all passed must not drop. Cases
  without a `guard_verdict` score are ignored.
  """
  @spec guard_non_regression(Evaluation.t(), Evaluation.t()) :: :ok | {:error, term()}
  def guard_non_regression(%Evaluation{} = before, %Evaluation{} = after_) do
    old = guard_rates(before)
    new = guard_rates(after_)

    case Enum.filter(Map.keys(old), &(Map.get(new, &1, 0.0) < old[&1])) do
      [] -> :ok
      regressed -> {:error, {:guard_regression, Enum.sort(regressed)}}
    end
  end

  defp guard_rates(%Evaluation{run: %{samples: samples}}) do
    samples
    |> Enum.group_by(& &1.case_id)
    |> Enum.flat_map(fn {case_id, samples} ->
      rates =
        for sample <- samples,
            guard = Enum.filter(sample.scores, &String.starts_with?(&1.name, "guard_verdict")),
            guard != [] or sample.verdict == :error,
            do:
              if(sample.verdict != :error and Enum.all?(guard, & &1.passed?), do: 1.0, else: 0.0)

      if rates == [], do: [], else: [{case_id, Enum.sum(rates) / length(rates)}]
    end)
    |> Map.new()
  end

  defp guard_rates(%Evaluation{}), do: %{}

  @doc "The text `profile` gives each optimized component (its own, else the base)."
  @spec current_text(t(), Profile.t()) :: %{String.t() => String.t()}
  def current_text(%__MODULE__{} = ctx, %Profile{components: components}) do
    ctx.base_text |> Map.take(ctx.components) |> Map.merge(Map.take(components, ctx.components))
  end

  defp changed(updates, current) do
    case Map.reject(updates, fn {key, text} -> current[key] == text end) do
      empty when map_size(empty) == 0 -> {:error, :no_change}
      updates -> {:ok, updates}
    end
  end

  @doc false
  # Every run id an evaluation produced, for the provenance of the result.
  @spec run_ids(t()) :: [String.t()]
  def run_ids(%__MODULE__{cache: cache}) do
    for {{:run, _seq}, id} <- :ets.tab2list(cache) |> Enum.sort(), do: id
  end

  defp record_run(%__MODULE__{cache: cache}, %Evaluation{run: %{id: id}}) when is_binary(id),
    do: :ets.insert(cache, {{:run, System.unique_integer([:monotonic])}, id})

  defp record_run(_ctx, _evaluation), do: true
end
