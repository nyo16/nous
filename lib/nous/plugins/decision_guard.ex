defmodule Nous.Plugins.DecisionGuard do
  @moduledoc """
  Security guard backed by a `Nous.DecisionModel`: per-surface question packs
  classify user input, tool calls, tool results and model output, and
  probability bands turn the answers into allow / escalate / deny.

      agent = Nous.new("openai:gpt-4.1", plugins: [Nous.Plugins.DecisionGuard])

      Nous.run(agent, prompt,
        deps: %{
          decision_guard_config: %{
            model: "workers_ai:clef-flash",
            surfaces: [:user_input, :tool_call]
          }
        }
      )

  ## Surfaces

  | Surface | Runs in | Pack | Deny means |
  |---|---|---|---|
  | `:user_input` (default) | plugin `before_request/3` | `Packs.UserInput` | blocked exactly like `Nous.Plugins.InputGuard`'s `:block`: an assistant refusal is added and no chat request is sent |
  | `:tool_call` | `:pre_tool_use` hook | `Packs.ToolCall` | the tool never runs; the model is told the call was denied |
  | `:tool_result` | `:post_tool_use` hook | `Packs.ToolResult` | the result is withheld from the model, history and callbacks |
  | `:model_output` | `:post_response` hook (blocking) | `Packs.ModelOutput` | the run returns `{:error, %Nous.Errors.ResponseDenied{}}` |

  The user-input surface runs `Nous.Plugins.InputGuard.Strategies.DecisionModel`
  and (with `:pattern_ensemble`) `Nous.Plugins.InputGuard.Strategies.Pattern`
  through `Nous.Plugins.InputGuard.Engine` under `:any`: a Pattern hit blocks
  even when the model says safe. It checks each new user message once (the
  InputGuard message scan), including the initial prompt of `Nous.run/3`.

  The other surfaces are `:decision` hooks (`Nous.Hook.Decision`) contributed
  through `c:Nous.Plugin.hooks/2` at priority **900** with `fail_closed:
  true`, so they classify what earlier (lower-priority) hooks produced.

  Only `:user_input` is on by default: on a laptop-local model every check
  costs ~0.5–1 s, and tool results routinely need several chunks.

  ## Configuration (`deps[:decision_guard_config]`, map or keyword list)

    * `:model` — **required**. A `%Nous.DecisionModel{}` or a
      `Nous.DecisionModel.parse/2` string.
    * `:model_family` — inferred as `"clef"` when the model name contains
      "clef". Packs refuse default bands for any other family; pass
      per-surface `:bands` for every question then.
    * `:surfaces` — default `[:user_input]`. A list of surfaces, or a keyword
      list / map of `surface => opts` with per-surface overrides:
      `:questions` (`{:replace, qs}` or `{:extend, qs}`), `:bands`
      (`%{id => band}`), `:include`, `:preset`, `:on_escalate`, `:on_error`,
      `:oversize`, `:max_chunks`, `:timeout`, `:canary` and (tool surfaces)
      `:matcher`.
    * `:preset` — user-input band preset: `:balanced` (default) or `:strict`.
    * `:pattern_ensemble` — default `true`: run Pattern beside the model on
      user input.
    * `:canary` — default `false`. A separate canary call per check and
      chunk; a wrong answer floors the verdict at escalate. Weak evidence.
    * `:on_escalate` — what an escalation means:
      * user input: `(info -> :allow | :deny | {:edit, %{content: text}})`
        with `info = %{surface: :user_input, content, reason,
        probabilities}`; `{:edit, ...}` replaces the user message. Without a
        handler, an escalation blocks.
      * hook surfaces: as `Nous.Hook.Decision` (`info.event` names the
        event). Without a handler, `:tool_call` asks the run's approval
        handler (`Nous.Permissions.consult_handler/2`; none rejects) and the
        other surfaces deny.
    * `:on_error` — `:deny` (default), `:escalate` or `:allow`: what a
      decision-model error or timeout means.
    * `:oversize` — `:chunk` (default), `:suspicious` or `:head_tail`.
    * `:max_chunks` — default 8.
    * `:timeout` — per decision-model call, in ms. Default `10_000`; size it
      for your backend (seconds for a laptop-local model).
    * `:skip_empty` — default `true`: blank user messages are not checked.

  ## Sub-agents

  `:decision_guard_config` is confinement: `Nous.Plugins.SubAgent` always
  forwards it (whatever `:sub_agent_shared_deps` says) and re-adds this plugin
  to every sub-agent. A sub-agent template cannot loosen it; it can only add
  hooks of its own, and those do not reach grandchildren.

  ## Limits

    * A guard verdict is a classifier's opinion, not a trust signal: an
      allowed input is not "trusted". Keep permissions, the sandbox and
      approvals in place.
    * `run_stream/3` does not invoke `before_request/3`, so the user-input
      surface does not apply there, and under `stream: true` a denied
      response's tokens were already streamed.
    * `Nous.Workflow` nodes are not covered: guard each `:agent_step` agent
      explicitly.

  ## Telemetry

    * `[:nous, :decision_guard, :verdict]` — every classified check.
      * Measurements: `%{duration: native_time, chunk_count: integer}`
      * Metadata: `%{surface, verdict, result, probabilities, canary_failed, error}`,
        with `verdict` one of `:allow`, `:escalate`, `:deny` and `result` one of
        `:allow`, `:deny`, `:modify` (after escalation).
    * `[:nous, :decision_guard, :canary_failed]` — a canary was answered
      wrongly. Measurements `%{count: integer}`, metadata `%{surface}`.
    * `[:nous, :decision_guard, :strategy_dropped]` — a user-input strategy
      produced no verdict (see `Nous.Plugins.InputGuard.Engine`).
  """

  @behaviour Nous.Plugin

  require Logger

  alias Nous.Agent.Context
  alias Nous.Hook
  alias Nous.Hook.Decision
  alias Nous.Plugins.DecisionGuard.Pack
  alias Nous.Plugins.DecisionGuard.Packs
  alias Nous.Plugins.InputGuard.{Engine, Policy, Result}
  alias Nous.Plugins.InputGuard.Strategies

  @surfaces [:user_input, :tool_call, :tool_result, :model_output]
  @packs %{
    user_input: Packs.UserInput,
    tool_call: Packs.ToolCall,
    tool_result: Packs.ToolResult,
    model_output: Packs.ModelOutput
  }
  @events %{tool_call: :pre_tool_use, tool_result: :post_tool_use, model_output: :post_response}
  @surface_keys [
    :questions,
    :bands,
    :include,
    :preset,
    :on_escalate,
    :on_error,
    :oversize,
    :max_chunks,
    :timeout,
    :canary,
    :matcher
  ]
  @priority 900
  @last_checked :decision_guard_last_checked
  @strategy_severity %{deny: :blocked, escalate: :suspicious, allow: :safe}
  @verdicts %{safe: :allow, suspicious: :escalate, blocked: :deny}

  # ── Plugin callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_agent, ctx), do: Context.merge_deps(ctx, %{@last_checked => -1})

  @impl true
  def hooks(_agent, ctx) do
    case config(ctx) do
      nil ->
        []

      config ->
        # Validate the user-input surface eagerly too: a misconfigured guard
        # must fail the run loudly, not drop to "no verdict" on every message.
        case config.surfaces[:user_input] do
          nil -> :ok
          surface -> validate_user_input!(config, surface)
        end

        for {surface, opts} <- config.surfaces, surface != :user_input do
          hook(config, surface, opts)
        end
    end
  end

  @impl true
  def before_request(_agent, ctx, tools) do
    with %{} = config <- config(ctx),
         %{} = surface <- config.surfaces[:user_input],
         {input, index} <- Engine.unchecked_user_input(ctx, @last_checked) do
      ctx = Context.merge_deps(ctx, %{@last_checked => index})

      if config.skip_empty and String.trim(input) == "",
        do: {ctx, tools},
        else: check_user_input(input, index, ctx, tools, config, surface)
    else
      _ -> {ctx, tools}
    end
  end

  # ── user input ─────────────────────────────────────────────────────────────

  defp check_user_input(input, index, ctx, tools, config, surface) do
    start = System.monotonic_time()
    opts = strategy_opts(config, surface)

    strategies =
      [{Strategies.DecisionModel, opts}] ++
        if config.pattern_ensemble, do: [{Strategies.Pattern, []}], else: []

    engine_config = %{
      strategies: strategies,
      aggregation: :any,
      short_circuit: false,
      strategy_timeout: engine_timeout(opts)
    }

    result =
      Engine.run(input, ctx, engine_config,
        telemetry_prefix: [:nous, :decision_guard],
        label: "DecisionGuard"
      )

    verdict = Map.fetch!(@verdicts, result.severity)
    surface = Map.put_new(surface, :on_escalate, config.on_escalate)
    {ctx_and_tools, outcome} = act(verdict, result, input, index, ctx, tools, surface)

    model_info = if result.strategy == Strategies.DecisionModel, do: result.metadata, else: %{}

    emit_verdict(:user_input, System.monotonic_time() - start, %{
      verdict: verdict,
      result: outcome,
      probabilities: Map.get(model_info, :probabilities, %{}),
      canary_failed: Map.get(model_info, :canary_failed, 0),
      chunk_count: Map.get(model_info, :chunk_count, 0),
      error: nil
    })

    ctx_and_tools
  end

  defp act(:allow, _result, _input, _index, ctx, tools, _surface), do: {{ctx, tools}, :allow}

  defp act(:deny, result, _input, _index, ctx, tools, _surface),
    do: {block(result.reason, ctx, tools), :deny}

  defp act(:escalate, result, input, index, ctx, tools, surface) do
    info = %{
      surface: :user_input,
      content: input,
      reason: result.reason,
      probabilities: Map.get(result.metadata, :probabilities, %{})
    }

    case escalate(surface[:on_escalate], info) do
      :allow ->
        {{ctx, tools}, :allow}

      {:edit, %{content: content}} when is_binary(content) ->
        {{replace_content(ctx, index, content), tools}, :modify}

      _ ->
        reason = "#{result.reason || "flagged"}; escalated and not approved"
        {block(reason, ctx, tools), :deny}
    end
  end

  defp escalate(fun, info) when is_function(fun, 1) do
    fun.(info)
  rescue
    e ->
      Logger.warning("DecisionGuard: on_escalate raised: #{Exception.message(e)}; blocking")
      :deny
  catch
    kind, reason ->
      Logger.warning("DecisionGuard: on_escalate #{kind}: #{inspect(reason)}; blocking")
      :deny
  end

  defp escalate(_none, _info), do: :deny

  defp block(reason, ctx, tools) do
    Policy.apply(
      %Result{severity: :blocked, reason: reason || "Input blocked by DecisionGuard"},
      ctx,
      tools,
      %{policy: %{blocked: :block}}
    )
  end

  defp replace_content(ctx, index, content) do
    %{ctx | messages: List.update_at(ctx.messages, index, &%{&1 | content: content})}
  end

  defp strategy_opts(config, surface) do
    [
      model: config.model,
      model_family: config.model_family,
      questions: surface[:questions],
      bands: surface[:bands],
      include: surface[:include] || [],
      preset: surface[:preset] || config.preset,
      canary: Map.get(surface, :canary, config.canary),
      oversize: surface[:oversize] || config.oversize,
      max_chunks: surface[:max_chunks] || config.max_chunks,
      timeout: surface[:timeout] || config.timeout,
      on_error: Map.fetch!(@strategy_severity, surface[:on_error] || config.on_error),
      on_verdict: &canary_telemetry(:user_input, &1.canary_failed)
    ]
  end

  # Raises ArgumentError on an invalid band / question / family setup.
  defp validate_user_input!(config, surface) do
    opts = strategy_opts(config, surface)

    pack_opts =
      Keyword.take(opts, [:questions, :bands, :include, :preset, :model_family])

    Decision.new([model: config.model] ++ Pack.build(Packs.UserInput, pack_opts))
    :ok
  end

  # Each decision call is bounded by `:timeout`; a check makes at most
  # max_chunks calls, doubled by the canary.
  defp engine_timeout(opts) do
    case opts[:timeout] do
      :infinity -> :infinity
      t -> t * opts[:max_chunks] * if(opts[:canary], do: 2, else: 1) + 1_000
    end
  end

  # ── hook surfaces ──────────────────────────────────────────────────────────

  defp hook(config, surface, opts) do
    pack = Map.fetch!(@packs, surface)

    pack_opts =
      opts
      |> Map.take([:questions, :bands, :include, :preset])
      |> Map.to_list()
      |> Keyword.put(:model_family, config.model_family)

    decision =
      Decision.new(
        [
          model: config.model,
          state: &pack.state/2,
          on_error: opts[:on_error] || config.on_error,
          oversize: opts[:oversize] || config.oversize,
          max_chunks: opts[:max_chunks] || config.max_chunks,
          canary: Map.get(opts, :canary, config.canary),
          on_escalate: Map.get(opts, :on_escalate, config.on_escalate),
          on_verdict: &hook_verdict(surface, &1)
        ] ++ Pack.build(pack, pack_opts)
      )

    Hook.new(Map.fetch!(@events, surface),
      name: "decision_guard:#{surface}",
      handler: decision,
      priority: @priority,
      fail_closed: true,
      timeout: opts[:timeout] || config.timeout,
      matcher: opts[:matcher]
    )
  end

  defp hook_verdict(surface, report) do
    canary_telemetry(surface, report.canary_failed)

    emit_verdict(surface, report.duration, %{
      verdict: report.verdict,
      result: report.result,
      probabilities: report.probabilities,
      canary_failed: report.canary_failed,
      chunk_count: report.chunk_count,
      error: report.error
    })
  end

  # ── telemetry ──────────────────────────────────────────────────────────────

  defp emit_verdict(surface, duration, report) do
    :telemetry.execute(
      [:nous, :decision_guard, :verdict],
      %{duration: duration, chunk_count: report.chunk_count},
      %{
        surface: surface,
        verdict: report.verdict,
        result: report.result,
        probabilities: report.probabilities,
        canary_failed: report.canary_failed,
        error: report.error
      }
    )
  end

  defp canary_telemetry(_surface, 0), do: :ok

  defp canary_telemetry(surface, count) do
    Logger.warning("DecisionGuard: #{count} canary check(s) failed on #{surface}")

    :telemetry.execute([:nous, :decision_guard, :canary_failed], %{count: count}, %{
      surface: surface
    })
  end

  # ── config ─────────────────────────────────────────────────────────────────

  defp config(ctx) do
    case Map.get(ctx.deps, :decision_guard_config) do
      nil -> nil
      raw when is_list(raw) or is_map(raw) -> normalize(Map.new(raw))
      other -> raise ArgumentError, ":decision_guard_config must be a map, got: #{inspect(other)}"
    end
  end

  defp normalize(raw) do
    model =
      case Map.fetch(raw, :model) do
        {:ok, model} -> Pack.resolve_model!(model)
        :error -> raise ArgumentError, ":decision_guard_config requires :model"
      end

    %{
      model: model,
      model_family: Pack.model_family(model, Map.take(raw, [:model_family]) |> Map.to_list()),
      surfaces: raw |> Map.get(:surfaces, [:user_input]) |> normalize_surfaces(),
      preset: Map.get(raw, :preset, :balanced),
      pattern_ensemble: Map.get(raw, :pattern_ensemble, true),
      canary: Map.get(raw, :canary, false),
      on_escalate: Map.get(raw, :on_escalate),
      on_error: Map.get(raw, :on_error, :deny),
      oversize: Map.get(raw, :oversize, :chunk),
      max_chunks: Map.get(raw, :max_chunks, 8),
      timeout: Map.get(raw, :timeout, 10_000),
      skip_empty: Map.get(raw, :skip_empty, true)
    }
    |> validate!()
  end

  defp normalize_surfaces(surfaces) when is_list(surfaces) or is_map(surfaces) do
    surfaces
    |> Enum.map(fn
      {surface, opts} when is_list(opts) or is_map(opts) -> {surface, Map.new(opts)}
      surface -> {surface, %{}}
    end)
    |> Enum.map(fn {surface, opts} ->
      unless surface in @surfaces,
        do:
          raise(
            ArgumentError,
            "unknown DecisionGuard surface #{inspect(surface)}; expected one of #{inspect(@surfaces)}"
          )

      case Map.keys(opts) -- @surface_keys do
        [] ->
          :ok

        unknown ->
          raise ArgumentError, "unknown options for #{inspect(surface)}: #{inspect(unknown)}"
      end

      {surface, opts}
    end)
  end

  defp normalize_surfaces(other),
    do: raise(ArgumentError, ":surfaces must be a list or map, got: #{inspect(other)}")

  defp validate!(config) do
    on_errors = [config.on_error | for({_, o} <- config.surfaces, o[:on_error], do: o[:on_error])]

    unless Enum.all?(on_errors, &(&1 in [:deny, :escalate, :allow])),
      do: raise(ArgumentError, ":on_error must be :deny, :escalate or :allow")

    unless is_nil(config.on_escalate) or is_function(config.on_escalate, 1),
      do: raise(ArgumentError, ":on_escalate must be a 1-arity function")

    config
  end
end
