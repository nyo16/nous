defmodule Nous.AgentRunner.Routing do
  @moduledoc false
  # The runner side of `Nous.Router`: decides whether this iteration is a
  # routing boundary for the agent's granularity, consults the router, and
  # caches the decision in a runtime-only `ctx.deps` key. Internal to the
  # runner; `Nous.AgentRunner.IterationLoop.effective_model/2` is the only
  # caller of route/3.
  #
  # The cached decision is `%{model: Model.t() | nil, rank: integer | nil,
  # turn: pos_integer}`. `model: nil` means "no route" (`:default` or an
  # error): requests go to `agent.model`. `rank` is the tier index under
  # `:escalate_only` and nil otherwise. The key is stripped with the sticky
  # fallback (IterationLoop.clear_runtime_models/1), so it never reaches
  # `result.deps`, a persisted context or the next run.

  alias Nous.{Agent, Message, Model, Router}
  alias Nous.Agent.Context

  require Logger

  @route_key :__nous_route__

  @doc false
  # Returns `{:boundary, ctx}` when the router was consulted for this request
  # (the caller then drops the sticky fallback) and `{:hold, ctx}` otherwise.
  @spec route(Agent.t(), Context.t(), pos_integer()) :: {:boundary | :hold, Context.t()}
  def route(%Agent{router: {module, opts}} = agent, %Context{} = ctx, turn) do
    granularity = Router.granularity(opts)
    current = Map.get(ctx.deps, @route_key)

    case tiers(module, opts, granularity) do
      {:ok, tiers} ->
        if boundary?(granularity, current, turn, tiers) do
          decision = decide(agent, ctx, turn, granularity, current, tiers)
          {:boundary, %{ctx | deps: Map.put(ctx.deps, @route_key, decision)}}
        else
          {:hold, ctx}
        end

      # Routing fails open: without usable tiers the request goes to the
      # current routed model, or to agent.model before the first decision.
      :error ->
        {:hold, ctx}
    end
  end

  @doc false
  # The model the last routing decision chose, or nil (no router, no decision
  # yet, or "no route").
  @spec routed_model(Context.t()) :: Model.t() | nil
  def routed_model(%Context{deps: deps}) do
    case Map.get(deps, @route_key) do
      %{model: model} -> model
      _none -> nil
    end
  end

  @doc false
  @spec clear(Context.t()) :: Context.t()
  def clear(%Context{} = ctx), do: %{ctx | deps: Map.delete(ctx.deps, @route_key)}

  # `Router.new/1` checked the tiers once, but `tiers/1` is user code that runs
  # again for every request: a raise, an exit or a return that is not a
  # non-empty list of models must not take the run down.
  defp tiers(module, opts, :escalate_only) do
    case Router.tiers(module, opts) do
      {:ok, tiers} ->
        {:ok, tiers}

      {:error, reason} ->
        Logger.warning(
          "Nous.Router: #{inspect(module)}.tiers/1 failed (#{inspect(reason)}); " <>
            "not routing this request"
        )

        :error
    end
  end

  defp tiers(_module, _opts, _granularity), do: {:ok, []}

  # ── boundaries ─────────────────────────────────────────────────────────────

  defp boundary?(_granularity, nil, _turn, _tiers), do: true
  defp boundary?(:once, _current, _turn, _tiers), do: false
  defp boundary?(:per_turn, %{turn: routed_turn}, turn, _tiers), do: routed_turn != turn
  defp boundary?(:per_iteration, _current, _turn, _tiers), do: true
  # Nothing above the top tier: stop paying for decisions once it is reached.
  defp boundary?(:escalate_only, %{rank: rank}, _turn, tiers), do: rank < length(tiers) - 1

  # ── deciding ───────────────────────────────────────────────────────────────

  defp decide(agent, ctx, turn, granularity, current, tiers) do
    {module, opts} = agent.router

    info = %{
      text: last_user_text(ctx.messages),
      messages: ctx.messages,
      iteration: ctx.iteration,
      turn: turn,
      granularity: granularity,
      current_model: current && current.model
    }

    start = System.monotonic_time()
    outcome = call_router(module, agent, info, opts)
    duration = System.monotonic_time() - start

    {decision, meta} = resolve(outcome, granularity, current, tiers)
    decision = Map.put(decision, :turn, turn)

    report(agent, ctx, turn, granularity, decision, meta, duration)
    decision
  end

  # A router is user code on the request path. Whatever it does — an invalid
  # return, a raise, an exit — the request still goes out on the agent's own
  # model: routing fails open by design (it is a cost control, not a security
  # control). The failure is logged in full and reported as `cause: :error`.
  defp call_router(module, agent, info, opts) do
    case module.route(agent, info, opts) do
      {:ok, %Model{} = model} -> {:ok, model, %{}}
      {:ok, %Model{} = model, meta} when is_map(meta) -> {:ok, model, meta}
      :default -> {:default, %{}}
      {:default, meta} when is_map(meta) -> {:default, meta}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_route, other}}
    end
  catch
    kind, reason ->
      Logger.warning(
        "Nous.Router: #{inspect(module)}.route/3 crashed; using the agent's model\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error, {kind, reason}}
  end

  # → `{%{model, rank}, report_meta}`
  defp resolve({:ok, model, meta}, :escalate_only, current, tiers) do
    current_rank = current_rank(current)

    case Enum.find_index(tiers, &(&1 == model)) do
      rank when is_integer(rank) and rank > current_rank ->
        {%{model: model, rank: rank}, Map.put(meta, :cause, :routed)}

      _lower_equal_or_unknown ->
        {hold(current, tiers), Map.put(meta, :cause, :held)}
    end
  end

  defp resolve({:ok, model, meta}, _granularity, _current, _tiers) do
    {%{model: model, rank: nil}, Map.put(meta, :cause, :routed)}
  end

  defp resolve({:default, meta}, granularity, current, tiers) do
    {no_route(granularity, current, tiers), Map.put_new(meta, :cause, :default)}
  end

  defp resolve({:error, reason}, granularity, current, tiers) do
    {no_route(granularity, current, tiers), %{cause: :error, reason: reason}}
  end

  # Under :escalate_only "no route" keeps the current tier (the cheapest one
  # before the first decision) — falling back to agent.model could move down.
  defp no_route(:escalate_only, current, tiers), do: hold(current, tiers)
  defp no_route(_granularity, _current, _tiers), do: %{model: nil, rank: nil}

  defp hold(nil, [cheapest | _]), do: %{model: cheapest, rank: 0}
  defp hold(%{model: model, rank: rank}, _tiers), do: %{model: model, rank: rank}

  defp current_rank(nil), do: -1
  defp current_rank(%{rank: rank}), do: rank

  defp report(agent, ctx, turn, granularity, decision, meta, duration) do
    {module, _opts} = agent.router
    model = decision.model || agent.model
    cause = Map.get(meta, :cause)
    reason = Map.get(meta, :reason)
    tier = Map.get(meta, :tier)

    :telemetry.execute(
      [:nous, :router, :route],
      %{duration: duration},
      %{
        agent_name: agent.name,
        router: module,
        granularity: granularity,
        turn: turn,
        iteration: ctx.iteration,
        cause: cause,
        tier: tier,
        probabilities: Map.get(meta, :probabilities, []),
        confidence: Map.get(meta, :confidence),
        reason: reason,
        model_provider: model.provider,
        model_name: model.model
      }
    )

    label = "#{model.provider}:#{model.model}"

    case cause do
      :error ->
        Logger.warning(
          "Nous.Router: routing failed for #{agent.name} (#{inspect(reason)}); using #{label}"
        )

      cause when cause in [:routed, :held] ->
        Logger.debug("Nous.Router: #{agent.name} → #{label} (tier #{inspect(tier)}, #{cause})")

      cause ->
        Logger.info(
          "Nous.Router: no route for #{agent.name} (#{inspect(cause)}" <>
            if(reason, do: ": #{inspect(reason)}", else: "") <> "); using #{label}"
        )
    end
  end

  defp last_user_text(messages) do
    Enum.find_value(Enum.reverse(messages), "", fn
      %Message{role: :user} = message -> Message.extract_text(message)
      _other -> nil
    end)
  end
end
