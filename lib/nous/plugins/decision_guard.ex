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
  | `:user_input` (default) | plugin `before_request/3` | `Packs.UserInput` | the refused messages are redacted in place (`"[user message blocked by DecisionGuard]"`; the originals stay in the session log), an assistant refusal is added and no chat request is sent |
  | `:tool_call` | `:pre_tool_use` hook | `Packs.ToolCall` | the tool never runs; the model is told the call was denied |
  | `:tool_result` | `:post_tool_use` hook | `Packs.ToolResult` | the result is withheld from the model, history and callbacks |
  | `:model_output` | `:post_response` hook (blocking) | `Packs.ModelOutput` | the run returns `{:error, %Nous.Errors.ResponseDenied{}}` |

  The user-input surface runs `Nous.Plugins.InputGuard.Strategies.DecisionModel`
  and (with `:pattern_ensemble`) `Nous.Plugins.InputGuard.Strategies.Pattern`
  through `Nous.Plugins.InputGuard.Engine` under `:any`: a Pattern hit blocks
  even when the model says safe. It checks every user message added since its
  last check once, oldest first, including the initial prompt of
  `Nous.run/3`. A step boundary can add several at once (an inbox batch);
  the worst verdict wins, so one denied message refuses the whole batch.

  "Since its last check" is tracked by session-log position (`Nous.Session.Log`
  seqs), not by place in `ctx.messages`, so compaction cannot hide a message.
  The marker lives in `ctx.deps` and carries over to the next run on the same
  context (each `Nous.AgentServer` turn checks only its own input); on any
  other context it does not apply and everything is checked again. If a
  plugin wrote `ctx.messages` directly, so the list is not exactly the log's
  projection, every user message in it is checked. A message is classified
  on the text a provider will send: for a multimodal message, its
  `metadata.content_parts` (see `Nous.Plugins.InputGuard.Engine.message_text/1`).
  A refused batch is replaced by fresh messages (parts dropped), so it reaches
  the model on no later turn either.

  ### Plugin order

  Only user messages that exist when this plugin's `before_request/3` runs are
  checked before the request:

    * list it **after** plugins that add user messages in `before_request/3`
      (`Nous.Plugins.LoopGuard`'s advisories), so their messages are checked
      too. LoopGuard's text is framework-written, so this is not enforced; a
      third-party plugin that adds user-role content needs the same placement;
    * list it **before** `Nous.Plugins.Summarization` (or any plugin that
      rewrites the transcript there): run the other way round, unchecked
      messages would be summarised first. With Summarization first, the run
      raises `ArgumentError`.

  For example `plugins: [Nous.Plugins.LoopGuard, Nous.Plugins.DecisionGuard,
  Nous.Plugins.Summarization]`.

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
      decision-model error or timeout means, including a user-input strategy
      that exits (e.g. a llama.cpp process that is down) or is killed at its
      timeout.
    * `:oversize` — `:chunk` (default), `:suspicious` or `:head_tail`.
      **`:head_tail` never classifies the middle of the content**, so an
      injection placed mid-content is missed and nothing floors the verdict.
      It trades coverage for cost; do not use it where the middle matters.
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
  alias Nous.{Hook, Message}
  alias Nous.Hook.Decision
  alias Nous.Plugins.DecisionGuard.Pack
  alias Nous.Plugins.DecisionGuard.Packs
  alias Nous.Plugins.InputGuard.{Engine, Policy, Result}
  alias Nous.Plugins.InputGuard.Strategies
  alias Nous.Session.Log

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
  @checked :decision_guard_checked
  @redacted "[user message blocked by DecisionGuard]"
  @strategy_severity %{deny: :blocked, escalate: :suspicious, allow: :safe}
  @verdicts %{safe: :allow, suspicious: :escalate, blocked: :deny}

  # ── Plugin callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(agent, ctx) do
    if Map.has_key?(ctx.deps, :decision_guard_config), do: check_plugin_order!(agent.plugins)
    ctx
  end

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
         [_ | _] = inputs <- unchecked_user_inputs(ctx) do
      inputs =
        if config.skip_empty,
          do: Enum.reject(inputs, fn {input, _index} -> String.trim(input) == "" end),
          else: inputs

      {ctx, tools} = check_user_inputs(inputs, ctx, tools, config, surface)
      {mark_checked(ctx), tools}
    else
      _ -> {ctx, tools}
    end
  end

  # Summarization (or any plugin that rewrites the transcript in
  # `before_request/3`) running first would summarise user messages this guard
  # has not classified yet, sending them to the summarizer and into a system
  # message.
  defp check_plugin_order!(plugins) do
    guard = Enum.find_index(plugins, &(&1 == __MODULE__))
    summarization = Enum.find_index(plugins, &(&1 == Nous.Plugins.Summarization))

    if guard && summarization && summarization < guard do
      raise ArgumentError,
            "Nous.Plugins.DecisionGuard must come before Nous.Plugins.Summarization in " <>
              ":plugins, or unclassified user messages are summarised"
    end

    :ok
  end

  # ── which user messages are new ────────────────────────────────────────────

  # "Checked" is a position in the session log, not in `ctx.messages`: log
  # seqs only grow, and compaction (`Context.replace_message_range/4`) appends
  # a replacement instead of renumbering, whereas list positions shrink when
  # Summarization collapses old messages. The marker is `%{count, anchor}`:
  # every event below `count` has been seen, and `anchor` fingerprints event
  # `count - 1` so the marker only applies to the log it was taken from. A
  # marker from another log (a sub-agent given the parent's deps, a cleared
  # history, a reseeded log) or whose anchor a snapshot dropped does not
  # match, and every user message is checked again: the failure mode is a
  # repeated check, never a skipped one.
  defp unchecked_user_inputs(ctx) do
    indexed = Log.derive_indexed(ctx.log)
    offset = length(ctx.messages) - length(indexed)
    logged = Enum.map(indexed, fn {_seq, message} -> message end)

    if in_step?(ctx.messages, logged, ctx.system_prompt_overlay) do
      from = checked_count(ctx)

      for {{seq, %Message{role: :user} = message}, i} <- Enum.with_index(indexed),
          seq >= from,
          do: {Engine.message_text(message), i + offset}
    else
      # The view was written around the log (a plugin's `%{ctx | messages:
      # ...}`), so seqs say nothing about it: every user message counts as new.
      for {%Message{role: :user} = message, i} <- Enum.with_index(ctx.messages),
          do: {Engine.message_text(message), i}
    end
  end

  # Whether `ctx.messages` is exactly the log's projection plus the system-prompt
  # overlay, i.e. what `Nous.Agent.Context` itself would materialize. This
  # mirrors its overlay rule (appended to a leading system message, or a
  # system message of its own); if that rule ever changes, this returns false
  # and every user message is checked: drift costs repeated checks, never a
  # skipped one.
  defp in_step?(messages, logged, nil), do: messages == logged

  defp in_step?(
         [%Message{role: :system} = view | view_rest],
         [%Message{role: :system} = head | logged_rest],
         overlay
       ),
       do:
         view_rest == logged_rest and
           view == %{head | content: (head.content || "") <> "\n\n" <> overlay}

  defp in_step?([%Message{role: :system, content: overlay} | view_rest], logged, overlay),
    do: view_rest == logged

  defp in_step?(_messages, _logged, _overlay), do: false

  defp checked_count(ctx) do
    with %{count: count, anchor: anchor} when is_integer(count) and is_integer(anchor) <-
           Map.get(ctx.deps, @checked),
         true <- count > 0 and Log.count(ctx.log) >= count,
         ^anchor <- anchor(ctx.log, count - 1) do
      count
    else
      _ -> 0
    end
  end

  defp mark_checked(ctx) do
    count = Log.count(ctx.log)
    Context.merge_deps(ctx, %{@checked => %{count: count, anchor: anchor(ctx.log, count - 1)}})
  end

  defp anchor(log, seq) when seq >= 0 do
    case Log.since(log, seq) do
      [%{seq: ^seq} = event | _] -> :erlang.phash2({event.type, event.data, event.time})
      _ -> nil
    end
  end

  defp anchor(_log, _seq), do: nil

  # ── user input ─────────────────────────────────────────────────────────────

  # A step boundary can add several user messages at once (an inbox batch, or
  # a run started with several new messages), so every one of them is
  # classified, oldest first. The worst verdict wins: the first deny stops the
  # scan and refuses the whole batch. Escalations are resolved only when
  # nothing was denied, so no handler is asked about a batch that is refused
  # anyway.
  defp check_user_inputs([], ctx, tools, _config, _surface), do: {ctx, tools}

  defp check_user_inputs(inputs, ctx, tools, config, surface) do
    surface = Map.put_new(surface, :on_escalate, config.on_escalate)
    checks = classify_all(inputs, ctx, config, surface)

    {ctx_and_tools, outcomes} =
      case Enum.find(checks, &(&1.verdict == :deny)) do
        %{result: result} ->
          {block(result.reason, inputs, ctx, tools), Enum.map(checks, fn _ -> :deny end)}

        nil ->
          resolve_escalations(checks, inputs, ctx, tools, surface)
      end

    Enum.zip_with(checks, outcomes, &emit_check/2)
    ctx_and_tools
  end

  defp classify_all(inputs, ctx, config, surface) do
    opts = strategy_opts(config, surface)
    on_error = surface[:on_error] || config.on_error

    strategies =
      [{Strategies.DecisionModel, opts}] ++
        if config.pattern_ensemble, do: [{Strategies.Pattern, []}], else: []

    engine_config = %{
      strategies: strategies,
      aggregation: :any,
      short_circuit: false,
      strategy_timeout: engine_timeout(config, surface)
    }

    inputs
    |> Enum.reduce_while([], fn {input, index}, checks ->
      check = classify(input, index, ctx, engine_config, on_error)
      if check.verdict == :deny, do: {:halt, [check | checks]}, else: {:cont, [check | checks]}
    end)
    |> Enum.reverse()
  end

  defp classify(input, index, ctx, engine_config, on_error) do
    start = System.monotonic_time()

    result =
      Engine.run(input, ctx, engine_config,
        telemetry_prefix: [:nous, :decision_guard],
        label: "DecisionGuard"
      )

    model_info = if result.strategy == Strategies.DecisionModel, do: result.metadata, else: %{}

    # A strategy that produced no verdict (killed at the engine's timeout) is
    # a decision-model error: it follows :on_error, never an escalation whose
    # handler would judge input nobody classified.
    {verdict, error} =
      if result.metadata[:fail_closed],
        do: {on_error, result.reason},
        else: {Map.fetch!(@verdicts, result.severity), Map.get(model_info, :error)}

    %{
      input: input,
      index: index,
      result: result,
      verdict: verdict,
      error: error,
      model_info: model_info,
      duration: System.monotonic_time() - start
    }
  end

  # → {{ctx, tools}, [outcome per check]}. The first escalation that is not
  # approved refuses the batch.
  defp resolve_escalations(checks, inputs, ctx, tools, surface) do
    checks
    |> Enum.reduce_while({ctx, []}, fn check, {ctx, outcomes} ->
      case resolve(check, ctx, surface) do
        {:ok, ctx, outcome} -> {:cont, {ctx, [outcome | outcomes]}}
        {:block, reason} -> {:halt, {:block, reason, ctx}}
      end
    end)
    |> case do
      {:block, reason, ctx} ->
        {block(reason, inputs, ctx, tools), Enum.map(checks, fn _ -> :deny end)}

      {ctx, outcomes} ->
        {{ctx, tools}, Enum.reverse(outcomes)}
    end
  end

  defp resolve(%{verdict: :allow}, ctx, _surface), do: {:ok, ctx, :allow}

  defp resolve(%{verdict: :escalate, result: result} = check, ctx, surface) do
    info = %{
      surface: :user_input,
      content: check.input,
      reason: result.reason,
      probabilities: Map.get(result.metadata, :probabilities, %{})
    }

    # Only a string :content is an edit of user input; any other edit (an
    # empty map, a hook surface's :arguments / :result / :response) is not an
    # approval and blocks.
    case escalate(surface[:on_escalate], info) do
      :allow ->
        {:ok, ctx, :allow}

      {:edit, %{content: content}} when is_binary(content) ->
        {:ok, replace_content(ctx, check.index, content), :modify}

      _ ->
        {:block, "#{result.reason || "flagged"}; escalated and not approved"}
    end
  end

  defp emit_check(check, outcome) do
    emit_verdict(:user_input, check.duration, %{
      verdict: check.verdict,
      result: outcome,
      probabilities: Map.get(check.model_info, :probabilities, %{}),
      canary_failed: Map.get(check.model_info, :canary_failed, 0),
      chunk_count: Map.get(check.model_info, :chunk_count, 0),
      error: check.error
    })
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

  # A refused batch is redacted in place before the refusal is added: the
  # checked marker moves past it, so a message left verbatim would reach the
  # model on the next turn without being classified again. Every message of
  # the batch goes, including ones the scan did not reach after the deny.
  # `Context.replace_message/3` keeps the originals in the session log.
  defp block(reason, inputs, ctx, tools) do
    ctx =
      Enum.reduce(inputs, ctx, fn {_input, index}, ctx ->
        replace_content(ctx, index, @redacted)
      end)

    Policy.apply(
      %Result{severity: :blocked, reason: reason || "Input blocked by DecisionGuard"},
      ctx,
      tools,
      %{policy: %{blocked: :block}}
    )
  end

  # A fresh user message, not an update of the old one: the provider adapters
  # send `metadata.content_parts` instead of `content` whenever it is present,
  # so carrying the old metadata over would send the original anyway.
  defp replace_content(ctx, index, content) do
    Context.replace_message(ctx, index, Message.user(content))
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

  # Raises ArgumentError on an invalid band / question / family / chunking setup.
  defp validate_user_input!(config, surface) do
    user_input_decision(config, surface)
    :ok
  end

  # The decision `Strategies.DecisionModel` builds from the same options.
  defp user_input_decision(config, surface) do
    opts = strategy_opts(config, surface)
    pack_opts = Keyword.take(opts, [:questions, :bands, :include, :preset, :model_family])

    Decision.new(
      [
        model: config.model,
        oversize: opts[:oversize],
        max_chunks: opts[:max_chunks],
        canary: opts[:canary]
      ] ++ Pack.build(Packs.UserInput, pack_opts)
    )
  end

  # The engine's kill is a backstop: `Decision.budget/2` covers the planning
  # task and every decision-model call, so the decision's own (typed) timeout
  # always fires first. The extra second covers building the decision.
  defp engine_timeout(config, surface) do
    case Decision.budget(
           user_input_decision(config, surface),
           surface[:timeout] || config.timeout
         ) do
      :infinity -> :infinity
      budget -> budget + 1_000
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
