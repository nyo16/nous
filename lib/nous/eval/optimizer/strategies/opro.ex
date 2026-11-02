defmodule Nous.Eval.Optimizer.Strategies.OPRO do
  @moduledoc """
  Optimization by prompting (OPRO, Yang et al. 2023): the cheap mode.

  The reflector sees the best earlier versions of every component with
  their scores (up to 20, shown in ascending order) and a few example
  inputs, and writes `proposals` new versions per step (8 by default) at
  temperature 1.0. Each version is linted, sealed and scored on a **fixed**
  subset of the train split; the history keeps the 20 best.

  No traces or per-case feedback reach the reflector, so OPRO is blind to
  why a case failed: GEPA is the better choice when the signal is in the
  trajectory (wrong tool, wrong arguments), OPRO when only the score moves.

  `best/1` is the version with the best subset score; like the paper, OPRO
  selects on train, and the optimizer's held-out test acceptance is what
  protects against overfitting the subset.

  ## Options (`strategy_opts:`)

    * `:proposals` - versions per step (default 8)
    * `:subset_size` - train cases in the fixed subset (default 20, at most
      the train split)
    * `:history` - versions kept and shown (default 20)
    * `:examples` - example inputs shown per step (default 3)
  """

  @behaviour Nous.Eval.Optimizer.Strategy

  alias Nous.Eval.Optimizer.{Candidate, Context, Evaluation}

  @defaults [proposals: 8, subset_size: 20, history: 20, examples: 3]

  @impl true
  def init(%Candidate{} = seed, %Context{} = ctx) do
    opts = Keyword.merge(@defaults, ctx.strategy_opts)
    {shuffled, rng} = shuffle(ctx.train, ctx.rng)
    subset = Enum.take(shuffled, min(opts[:subset_size], length(shuffled)))

    with {:ok, eval} <- Context.evaluate(ctx, seed.profile, subset, "train") do
      seed = %{seed | scores: eval.scores, mean: Evaluation.mean(eval)}
      inputs = inputs(eval)

      {:ok,
       %{opts: opts, subset: subset, inputs: inputs, history: [seed], rng: rng, rejections: []}}
    end
  end

  @impl true
  def step(state, %Context{} = ctx) do
    {examples, rng} = sample(state.inputs, state.opts[:examples], state.rng)
    state = %{state | rng: rng}
    history = Enum.map(state.history, &{&1.profile, &1.mean})

    case Context.generate(ctx, history, examples, state.opts[:proposals]) do
      {:ok, versions, rejected} ->
        state = reject(state, ctx, rejected)
        score_versions(versions, state, ctx)

      {:error, :budget_exhausted} ->
        {:halt, :budget_exhausted, state}

      {:error, reason} ->
        {:cont, reject(state, ctx, [reason])}
    end
  end

  defp score_versions([], state, _ctx), do: {:cont, state}

  defp score_versions([version | rest], state, ctx) do
    [top | _] = state.history

    result =
      with {:ok, child} <- Context.derive(ctx, top.profile, version, %{"step" => ctx.step}),
           :ok <- new_version(state.history, child),
           {:ok, eval} <- Context.evaluate(ctx, child, state.subset, "train") do
        {:ok,
         %Candidate{
           profile: child,
           parent_id: Candidate.id(top),
           step: ctx.step,
           scores: eval.scores,
           mean: Evaluation.mean(eval),
           changed: Map.keys(version)
         }}
      end

    case result do
      {:ok, candidate} ->
        history =
          [candidate | state.history]
          |> Enum.sort_by(&(-&1.mean))
          |> Enum.take(state.opts[:history])

        score_versions(rest, %{state | history: history}, ctx)

      {:error, :budget_exhausted} ->
        {:halt, :budget_exhausted, state}

      {:error, {:evaluation_failed, _} = reason} ->
        {:halt, reason, state}

      {:error, reason} ->
        score_versions(rest, reject(state, ctx, [reason], %{proposal: version}), ctx)
    end
  end

  defp new_version(history, child) do
    if Enum.any?(history, &(Candidate.id(&1) == child.id)), do: {:error, :duplicate}, else: :ok
  end

  defp reject(state, ctx, reasons, extra \\ %{})

  defp reject(state, _ctx, [], _extra), do: state

  defp reject(state, ctx, reasons, extra) do
    entries =
      Enum.map(
        reasons,
        &Map.merge(%{step: ctx.step, reason: &1, components: ctx.components}, extra)
      )

    %{state | rejections: state.rejections ++ entries}
  end

  defp inputs(%Evaluation{cases: cases}) do
    cases
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn
      %{input: text} when is_binary(text) -> text
      %{input: messages} -> Enum.map_join(messages, "\n", &Nous.Message.extract_text/1)
    end)
  end

  defp sample(items, n, rng) do
    {shuffled, rng} = shuffle(items, rng)
    {Enum.take(shuffled, n), rng}
  end

  defp shuffle(list, rng) do
    {keyed, rng} =
      Enum.map_reduce(list, rng, fn item, rng ->
        {x, rng} = :rand.uniform_s(rng)
        {{x, item}, rng}
      end)

    {keyed |> Enum.sort() |> Enum.map(&elem(&1, 1)), rng}
  end

  @impl true
  def best(%{history: [top | _]}), do: top

  @impl true
  def summary(state), do: %{candidates: state.history, rejections: state.rejections}
end
