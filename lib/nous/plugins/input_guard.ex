defmodule Nous.Plugins.InputGuard do
  @moduledoc """
  Modular malicious input classifier plugin.

  InputGuard detects prompt injection, jailbreak attempts, and other malicious inputs
  using a composable strategy pattern. Detection backends, aggregation modes, and
  policy actions are all configurable.

  ## Architecture

      User Input → InputGuard (before_request hook)
                     ├─ Strategy 1: Pattern matching
                     ├─ Strategy 2: LLM Judge
                     ├─ Strategy N: Custom function
                     ↓
                   Aggregator (any / majority / all)
                     ↓
                   Policy (block / warn / log / callback)
                     ↓
                   Modified Context (or halted execution)

  ## Configuration

  Store configuration in `deps` under the `:input_guard_config` key:

      agent = Nous.new("openai:gpt-4",
        plugins: [Nous.Plugins.InputGuard]
      )

      {:ok, result} = Nous.run(agent, "Hello",
        deps: %{
          input_guard_config: %{
            strategies: [
              {Nous.Plugins.InputGuard.Strategies.Pattern, []},
              {Nous.Plugins.InputGuard.Strategies.LLMJudge, model: "openai:gpt-4o-mini"},
              {MyApp.InputGuard.Blocklist, words: ["hack", "exploit"]}
            ],
            policy: %{suspicious: :warn, blocked: :block, dropped: :block},
            aggregation: :any,
            short_circuit: false,
            on_violation: &MyApp.log_violation/1,
            skip_empty: true
          }
        }
      )

  ## Configuration Options

    * `:strategies` — List of `{module, keyword_opts}` tuples. Each module must
      implement `Nous.Plugins.InputGuard.Strategy`. Default: `[{Strategies.Pattern, []}]`
    * `:policy` — Map of severity to action, plus `:dropped` for a fail-closed
      result (see below). Default: `%{suspicious: :warn, blocked: :block, dropped: :block}`;
      a policy map without `:dropped` still blocks on it. See `Nous.Plugins.InputGuard.Policy`.
    * `:aggregation` — How to combine results from multiple strategies.
      `:any` (default) flags if any strategy flags, `:majority` if more than half flag,
      `:all` only if every strategy flags. `:majority` and `:all` count against the
      number of *configured* strategies, not the ones that produced a verdict.
    * `:short_circuit` — When `true`, stops running strategies on first `:blocked` result.
      Default: `false`
    * `:fail_closed` — How to treat strategies that error, time out or return
      `{:error, reason}` ("dropped" strategies). Default: `true`, in every
      aggregation mode. A drop then counts as a vote that *flagged* the input,
      and if that could change the outcome — under `:any` whenever the
      survivors did not block, under `:majority` when the drops could make
      up the majority, under `:all` when every survivor flagged (so also when
      every strategy dropped) — the result is fail-closed: `:suspicious` with
      `metadata: %{fail_closed: true, dropped_strategies: n}`, handled by
      `policy[:dropped]`: with the default `:block` no chat request is sent;
      `dropped: :warn` lets it through with a warning. A `:blocked` survivor
      verdict is kept as is. With `fail_closed: false`
      (explicit fail-open) a drop counts as a vote that did *not* flag: under
      `:any` the survivors decide, and if every strategy drops the input
      passes as `:safe`. Dropped strategies always emit a `Logger` warning and a
      `[:nous, :input_guard, :strategy_dropped]` telemetry event.
    * `:strategy_timeout` — Per-strategy timeout in ms, on both the parallel
      and the `short_circuit` path; a strategy exceeding it is killed and
      counts as dropped. Default: `30_000`
    * `:on_violation` — Optional callback function `fn result -> ... end` called when
      input is flagged.
    * `:skip_empty` — Skip checking empty or whitespace-only messages. Default: `true`
    * `:max_attachment_bytes` — How many bytes of a `text/*` attachment are
      decoded and classified. Gemini / Vertex AI send such a part to the model
      as a document, so its text is checked like the message. A larger
      attachment, or one that is not valid base64 / UTF-8, cannot be
      classified and fails closed (`policy[:dropped]`, default `:block`).
      Default: `1_048_576`

  ## Which messages are checked

  Every user message the model has not answered yet: all user messages after
  the last assistant message that were not checked earlier in the run. When
  several messages arrive in one turn (queued `Nous.AgentServer.steer/2`
  calls, or `:message_history` ending in user messages), each is classified
  and the strictest result applies. Messages the model already answered are
  history and are not classified again.

  ## Streaming Limitation

  InputGuard operates via the `before_request` plugin hook, which is not invoked
  during `run_stream` in AgentRunner. When using streaming, InputGuard will not
  apply — validate input before calling `run_stream` if needed.

  """

  @behaviour Nous.Plugin

  require Logger

  alias Nous.Agent.Context
  alias Nous.Plugins.InputGuard.{Engine, Policy, Result}

  @max_attachment_bytes 1_048_576

  @impl true
  def init(_agent, ctx) do
    config = get_config(ctx)

    # Initialize last_checked_index to track which messages we've already checked.
    # This prevents re-checking the same user message on tool-call loop iterations.
    last_checked = Map.get(config, :last_checked_index, -1)
    ctx = Context.merge_deps(ctx, %{input_guard_last_checked: last_checked})
    ctx
  end

  @impl true
  def before_request(_agent, ctx, tools) do
    config = get_config(ctx)

    opts = [max_decoded_bytes: Map.get(config, :max_attachment_bytes, @max_attachment_bytes)]

    case Engine.unchecked_user_inputs(ctx, :input_guard_last_checked, opts) do
      [] ->
        {ctx, tools}

      inputs ->
        {_input, last} = List.last(inputs)
        ctx = Context.merge_deps(ctx, %{input_guard_last_checked: last})

        inputs
        |> Enum.reject(fn {input, _index} -> skip_empty?(config) and blank?(input) end)
        |> classify_all(ctx, config)
        |> Policy.apply(ctx, tools, config)
    end
  end

  # --- Private ---

  @label "InputGuard"

  # Each message is classified on its own (a detector must not see a malicious
  # message diluted by benign ones); the strictest result applies. A :blocked
  # verdict ends the scan: nothing can be stricter.
  defp classify_all(inputs, ctx, config) do
    inputs
    |> Enum.reduce_while(%Result{severity: :safe}, fn {input, _index}, strictest ->
      result = classify(input, ctx, config)
      strictest = Enum.max_by([strictest, result], &rank/1)

      if result.severity == :blocked, do: {:halt, strictest}, else: {:cont, strictest}
    end)
  end

  defp classify({:ok, text}, ctx, config), do: run_engine(text, ctx, config)

  defp classify({:error, reason, text}, ctx, config) do
    text |> run_engine(ctx, config) |> unreadable(reason, config)
  end

  defp run_engine(text, ctx, config) do
    Engine.run(text, ctx, config,
      telemetry_prefix: [:nous, :input_guard],
      label: @label,
      fail_closed_on: [:safe, :suspicious]
    )
  end

  # Part of the message could not be classified, so a :safe or :suspicious
  # verdict only covers the rest of it: fail closed like a dropped strategy.
  defp unreadable(%Result{severity: :blocked} = result, _reason, _config), do: result

  defp unreadable(result, reason, config) do
    Logger.warning("#{@label}: attachment could not be classified: #{inspect(reason)}")

    if Map.get(config, :fail_closed, true) do
      escalated = %Result{
        severity: :suspicious,
        reason:
          "A text attachment could not be read for classification " <>
            "(#{describe_unreadable(reason)}); failing closed",
        metadata: %{fail_closed: true, attachment_unreadable: reason}
      }

      Engine.fire_on_violation(escalated, config, @label)
      escalated
    else
      result
    end
  end

  defp describe_unreadable({:attachment_unreadable, {kind, media_type}}),
    do: "#{kind} #{media_type}"

  defp describe_unreadable(other), do: inspect(other)

  # A fail-closed result outranks a :suspicious verdict: the default policy
  # blocks it, where it only warns on :suspicious.
  defp rank(%Result{severity: :blocked}), do: 3
  defp rank(%Result{metadata: %{fail_closed: true}}), do: 2
  defp rank(%Result{severity: :suspicious}), do: 1
  defp rank(%Result{}), do: 0

  defp get_config(ctx) do
    Map.get(ctx.deps, :input_guard_config, %{})
  end

  defp skip_empty?(config), do: Map.get(config, :skip_empty, true)

  # A message with an unreadable attachment is never "empty".
  defp blank?({:ok, text}), do: String.trim(text) == ""
  defp blank?(_unreadable), do: false
end
