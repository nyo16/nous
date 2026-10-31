defmodule Nous.Plugins.InputGuard.Engine do
  @moduledoc """
  The strategy engine shared by `Nous.Plugins.InputGuard` and
  `Nous.Plugins.DecisionGuard`: run a list of
  `Nous.Plugins.InputGuard.Strategy` modules over a text, aggregate their
  verdicts and fail closed on strategies that produced none.

  `run/4` reads these keys from `config` (see `Nous.Plugins.InputGuard` for
  their meaning and defaults): `:strategies`, `:aggregation`,
  `:short_circuit`, `:fail_closed`, `:strategy_timeout`, `:on_violation`.

  ## Dropped strategies

  A strategy that errors, times out or returns `{:error, reason}` is
  *dropped*: it produced no verdict. With `:fail_closed` (default `true`) a
  drop counts as a flagging vote against the configured strategy count, and
  when that could change the outcome — under `:any` always, under
  `:majority` when the drops could make up the majority, under `:all` when
  every survivor flagged (including when every strategy dropped) — the result
  is a fail-closed one: severity `:suspicious`, `metadata: %{fail_closed:
  true, dropped_strategies: n}`. Callers map that marker to their own action
  (`Nous.Plugins.InputGuard.Policy` blocks by default). With `fail_closed:
  false` a drop counts as a vote that did not flag, so if every strategy
  drops the input is `:safe`.

  ## Options

    * `:telemetry_prefix` - prefix of the dropped-strategy event; the event is
      `prefix ++ [:strategy_dropped]`. Default: `[:nous, :input_guard]`.
    * `:label` - prefix of log messages. Default: `"InputGuard"`.
    * `:fail_closed_on` - the survivors' verdicts a fail-closed result may
      replace. Default: `[:safe]`. `Nous.Plugins.InputGuard` passes
      `[:safe, :suspicious]`, so a `:suspicious` survivor cannot downgrade a
      detector outage to a warning; `Nous.Plugins.DecisionGuard` keeps the
      default and escalates a `:suspicious` verdict. A `:blocked` verdict is
      never replaced.

  ## Telemetry

    * `prefix ++ [:strategy_dropped]` - one or more strategies errored, timed
      out or returned `{:error, reason}`.
      * Measurements: `%{count: integer}`
      * Metadata: `%{aggregation: :any | :majority | :all, fail_closed: boolean}`
  """

  require Logger

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Message.ContentPart
  alias Nous.Plugins.InputGuard.Result
  alias Nous.Plugins.InputGuard.Strategies.Pattern

  @default_prefix [:nous, :input_guard]
  @default_label "InputGuard"

  @doc """
  Runs the configured strategies over `input` and returns the aggregated
  `Nous.Plugins.InputGuard.Result`, after the fail-closed check for dropped
  strategies (see the moduledoc). Calls `config[:on_violation]` when the
  result is not `:safe`.

  `ctx` is handed to every strategy; it is `nil` on surfaces that have no
  agent context (see `c:Nous.Plugins.InputGuard.Strategy.check/3`).
  """
  @spec run(String.t(), Context.t() | nil, map(), keyword()) :: Result.t()
  def run(input, ctx, config, opts \\ []) do
    strategies = Map.get(config, :strategies, [{Pattern, []}])
    short_circuit = Map.get(config, :short_circuit, false)
    timeout = Map.get(config, :strategy_timeout, 30_000)
    label = Keyword.get(opts, :label, @default_label)

    {results, dropped} = run_strategies(strategies, input, ctx, short_circuit, timeout, label)

    aggregated =
      results
      |> aggregate(length(strategies), config)
      |> apply_fail_closed(results, length(strategies), dropped, config, opts)

    if aggregated.severity != :safe, do: fire_on_violation(aggregated, config, label)

    aggregated
  end

  @doc """
  Every user message the guard has not classified yet, oldest first, as
  `{message_text(message, opts), index}`.

  The window starts after the later of the index stored in
  `ctx.deps[last_checked_key]` (default `-1`) and the last `:assistant`
  message: all user messages the model has not answered yet, which is every
  message queued in this turn (several `Nous.AgentServer.steer/2` calls, or
  `:message_history` ending in user messages), not just the newest one.
  Messages the model already answered are history and are not classified
  again on each run. `opts` go to `message_text/2` (`:max_decoded_bytes`).
  """
  @spec unchecked_user_inputs(Context.t(), atom(), keyword()) ::
          [{{:ok, String.t()} | {:error, term(), String.t()}, non_neg_integer()}]
  def unchecked_user_inputs(ctx, last_checked_key, opts \\ []) do
    indexed = Enum.with_index(ctx.messages)

    answered =
      Enum.reduce(indexed, -1, fn
        {%Message{role: :assistant}, i}, _acc -> i
        _other, acc -> acc
      end)

    from = max(Map.get(ctx.deps, last_checked_key, -1), answered)

    for {%Message{role: :user} = message, i} <- indexed,
        i > from,
        do: {message_text(message, opts), i}
  end

  @doc """
  The text a guard classifies for `message`: what a provider will read.

  The OpenAI, Anthropic and Gemini adapters send `metadata.content_parts`
  instead of `content` whenever it is a list, so for such a message the parts
  are classified (each as the adapters render it as text, joined with spaces).
  `content` is added when it says something the parts do not: a message whose
  two halves disagree must not pass on the half that is never sent. Otherwise
  this is `content`, or its text parts joined with spaces.

  A binary part with a `text/*` media type (an `:image` part's `media_type`,
  or a base64 `data:` URL) is sent as a document by Gemini / Vertex AI, so it
  is decoded and its text classified. Other binary parts (images, PDFs) are
  not: they are classified as their placeholder only.

  Returns `{:ok, text}`, or `{:error, reason, text}` when a `text/*` part
  could not be decoded within `opts[:max_decoded_bytes]` (an integer, or a
  0-arity function returning one; default `0`, i.e. never decode) or is not
  valid UTF-8. `text` then has that part as its placeholder, and the caller
  must treat the message as not fully classified.
  """
  @spec message_text(Message.t(), keyword()) ::
          {:ok, String.t()} | {:error, term(), String.t()}
  def message_text(message, opts \\ [])

  def message_text(%Message{metadata: %{content_parts: parts}} = message, opts)
      when is_list(parts) do
    limit = Keyword.get(opts, :max_decoded_bytes, 0)
    {texts, errors} = parts |> Enum.map(&part_text(&1, limit)) |> Enum.unzip()
    parts_text = Enum.join(texts, " ")
    content = extract_text(message)

    # `Message.user/2` stores `ContentPart.to_text(parts)` as `content`.
    rendered = [Enum.map_join(parts, " ", &rendered/1), Enum.map_join(parts, &rendered/1)]

    text =
      if content in ["", parts_text | rendered],
        do: parts_text,
        else: content <> "\n" <> parts_text

    case Enum.reject(errors, &is_nil/1) do
      [] -> {:ok, text}
      [reason | _] -> {:error, reason, text}
    end
  end

  def message_text(%Message{} = message, _opts), do: {:ok, extract_text(message)}

  # → {text, nil | error_reason}
  defp part_text(%ContentPart{type: :image, content: data, options: opts} = part, limit)
       when is_binary(data) do
    media_type = Map.get(opts || %{}, :media_type, "image/png")

    if text_media?(media_type),
      do: decode_text(part, media_type, data, limit),
      else: {rendered(part), nil}
  end

  defp part_text(%ContentPart{type: :image_url, content: "data:" <> _ = url} = part, limit) do
    case ContentPart.parse_data_url(url) do
      {:ok, media_type, data} ->
        if text_media?(media_type),
          do: decode_text(part, media_type, data, limit),
          else: {rendered(part), nil}

      {:error, _} ->
        {rendered(part), nil}
    end
  end

  defp part_text(part, _limit), do: {rendered(part), nil}

  defp text_media?(media_type) when is_binary(media_type),
    do: media_type |> String.downcase() |> String.starts_with?("text/")

  defp text_media?(_), do: false

  # The size check runs on the encoded length, before anything is decoded.
  defp decode_text(part, media_type, data, limit) do
    max = if is_function(limit, 0), do: limit.(), else: limit

    with true <- div(byte_size(data) * 3, 4) <= max || {:too_large, media_type},
         {:ok, text} <- Base.decode64(data, ignore: :whitespace, padding: false),
         true <- String.valid?(text) || {:not_utf8, media_type} do
      {"[Document #{media_type}] " <> text, nil}
    else
      :error -> {rendered(part), {:attachment_unreadable, {:invalid_base64, media_type}}}
      reason -> {rendered(part), {:attachment_unreadable, reason}}
    end
  end

  # `ContentPart.to_text/1` of one part is exactly what the OpenAI adapter sends
  # for a part it has no native shape for. Anything that is not a part is
  # classified as inspected rather than crashing the guard.
  defp rendered(%ContentPart{} = part), do: ContentPart.to_text([part])
  defp rendered(other), do: inspect(other)

  defp extract_text(%Message{content: content}) when is_binary(content), do: content

  defp extract_text(%Message{content: parts}) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %{type: :text} -> true
      _ -> false
    end)
    |> Enum.map_join(" ", & &1.content)
  end

  defp extract_text(_), do: ""

  @doc """
  Collapses whitespace and caps a strategy reason at 300 characters.

  A reason may come from an LLM judge whose output is influenced by the
  (untrusted) input, so it must not smuggle instructions or formatting into
  the trusted system/assistant message it is embedded in.
  """
  @spec sanitize_reason(term()) :: String.t()
  def sanitize_reason(reason) when is_binary(reason) do
    reason
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 300)
  end

  def sanitize_reason(_), do: ""

  # Both variants return {results, dropped_count}. A "dropped" strategy is one
  # that errored, timed out, or returned `{:error, reason}` — it produced no
  # verdict, which must not be mistaken for a :safe verdict (see
  # apply_fail_closed/6). Strategies skipped by short-circuiting after a
  # :blocked result are NOT drops. Both variants bound each strategy by
  # `timeout`: a hung detector is a drop, never a hung run.
  defp run_strategies(strategies, input, ctx, true = _short_circuit, timeout, label) do
    {results, dropped} =
      Enum.reduce_while(strategies, {[], 0}, fn {mod, opts}, {acc, dropped} ->
        case bounded_check(mod, input, opts, ctx, timeout, label) do
          {:ok, %Result{severity: :blocked} = result} ->
            {:halt, {[result | acc], dropped}}

          {:ok, result} ->
            {:cont, {[result | acc], dropped}}

          :error ->
            {:cont, {acc, dropped + 1}}
        end
      end)

    {Enum.reverse(results), dropped}
  end

  defp run_strategies(strategies, input, ctx, false = _short_circuit, timeout, label) do
    {results, dropped} =
      Task.Supervisor.async_stream_nolink(
        Nous.TaskSupervisor,
        strategies,
        fn {mod, opts} -> safe_check(mod, input, opts, ctx, label) end,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(strategies)
      |> Enum.reduce({[], 0}, fn
        {{:ok, {:ok, result}}, _strategy}, {acc, dropped} ->
          {[result | acc], dropped}

        {{:ok, :error}, _strategy}, {acc, dropped} ->
          # safe_check already logged the failure in-process
          {acc, dropped + 1}

        {{:exit, reason}, {mod, _opts}}, {acc, dropped} ->
          # Timeout kills bypass safe_check's rescue — log here
          Logger.warning("#{label}: Strategy #{inspect(mod)} dropped (exit: #{inspect(reason)})")

          {acc, dropped + 1}
      end)

    {Enum.reverse(results), dropped}
  end

  # One strategy, run in a task so `timeout` applies on the sequential path
  # as it does on the parallel one.
  defp bounded_check(mod, input, opts, ctx, timeout, label) do
    task =
      Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
        safe_check(mod, input, opts, ctx, label)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        Logger.warning("#{label}: Strategy #{inspect(mod)} dropped (exit: #{inspect(reason)})")
        :error

      nil ->
        Logger.warning("#{label}: Strategy #{inspect(mod)} dropped (timeout after #{timeout}ms)")
        :error
    end
  end

  # A dropped strategy produced no verdict, and counting it as :safe is a
  # fail-open hole: an attacker who can make the real detector error or time
  # out (a large input, a judge endpoint that is down) would pass. With
  # :fail_closed (the default in every mode) a drop is counted as a flagging
  # vote against the configured denominator; if that changes the outcome the
  # survivors decided, the result is the fail-closed marker, which the caller
  # maps to its own action. With `fail_closed: false` a drop is a vote that
  # did not flag (the explicit fail-open opt-out).
  defp apply_fail_closed(aggregated, _results, _configured, 0, _config, _opts), do: aggregated

  defp apply_fail_closed(aggregated, results, configured, dropped, config, opts) do
    prefix = Keyword.get(opts, :telemetry_prefix, @default_prefix)
    label = Keyword.get(opts, :label, @default_label)
    replaceable = Keyword.get(opts, :fail_closed_on, [:safe])
    mode = Map.get(config, :aggregation, :any)
    fail_closed = Map.get(config, :fail_closed, true)

    :telemetry.execute(prefix ++ [:strategy_dropped], %{count: dropped}, %{
      aggregation: mode,
      fail_closed: fail_closed
    })

    Logger.warning(
      "#{label}: #{dropped} strateg#{if dropped == 1, do: "y", else: "ies"} dropped " <>
        "(error/timeout); fail_closed=#{fail_closed}"
    )

    if fail_closed and aggregated.severity != :blocked and aggregated.severity in replaceable and
         drops_could_flag?(mode, results, configured, dropped) do
      %Result{
        severity: :suspicious,
        reason:
          "#{dropped} input-guard strateg#{if dropped == 1, do: "y", else: "ies"} " <>
            "did not complete (error or timeout); failing closed",
        metadata: %{dropped_strategies: dropped, fail_closed: true}
      }
    else
      aggregated
    end
  end

  # Would the input be flagged if every dropped strategy had flagged it?
  defp drops_could_flag?(:any, _results, _configured, dropped), do: dropped > 0

  defp drops_could_flag?(:majority, results, configured, dropped),
    do: flagged_count(results) + dropped > configured / 2

  defp drops_could_flag?(:all, results, configured, dropped),
    do: flagged_count(results) + dropped == configured

  defp flagged_count(results), do: Enum.count(results, &(&1.severity != :safe))

  # Normalises every way a strategy can fail to produce a verdict — raise,
  # throw/exit, or the contract's own `{:error, reason}` — to `:error`, so the
  # two run_strategies/6 variants count all of them as dropped.
  defp safe_check(mod, input, opts, ctx, label) do
    case mod.check(input, opts, ctx) do
      {:ok, %Result{}} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("#{label}: Strategy #{inspect(mod)} dropped: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.warning("#{label}: Strategy #{inspect(mod)} failed: #{Exception.message(e)}")
      :error
  catch
    kind, reason ->
      Logger.warning(
        "#{label}: Strategy #{inspect(mod)} failed: #{inspect(kind)} #{inspect(reason)}"
      )

      :error
  end

  # The survivors' verdict, with drops counted as votes that did not flag.
  # Whether the drops could change it is apply_fail_closed/6's call, so an
  # all-dropped run is :safe here and fail-closed there.
  defp aggregate([], _configured_count, _config), do: %Result{severity: :safe}

  defp aggregate(results, configured_count, config) do
    mode = Map.get(config, :aggregation, :any)
    do_aggregate(results, configured_count, mode)
  end

  defp do_aggregate(results, _configured_count, :any) do
    # Return the most severe result
    results
    |> Enum.sort_by(&severity_rank/1, :desc)
    |> List.first()
  end

  defp do_aggregate(results, configured_count, :majority) do
    # Denominator is the number of CONFIGURED strategies, not survivors —
    # otherwise an attacker who makes benign strategies error/time-out shrinks
    # the vote and flips the outcome.
    flagged = flagged_count(results)

    if flagged > configured_count / 2 do
      most_severe(results)
    else
      %Result{severity: :safe}
    end
  end

  defp do_aggregate(results, configured_count, :all) do
    # Require EVERY configured strategy to have run AND flagged. Unanimity
    # that only the dropped strategies could complete is a fail-closed
    # outcome (apply_fail_closed/6), not a verdict.
    flagged = flagged_count(results)

    if flagged == configured_count and length(results) == configured_count do
      most_severe(results)
    else
      %Result{severity: :safe}
    end
  end

  defp most_severe(results) do
    results
    |> Enum.reject(&(&1.severity == :safe))
    |> Enum.sort_by(&severity_rank/1, :desc)
    |> List.first()
    |> Kernel.||(%Result{severity: :safe})
  end

  defp severity_rank(%Result{severity: :safe}), do: 0
  defp severity_rank(%Result{severity: :suspicious}), do: 1
  defp severity_rank(%Result{severity: :blocked}), do: 2

  @doc false
  # Called by `run/4`, and by `Nous.Plugins.InputGuard` for a result it
  # escalates after the run (an unreadable attachment).
  @spec fire_on_violation(Result.t(), map(), String.t()) :: term()
  def fire_on_violation(result, config, label) do
    case Map.get(config, :on_violation) do
      fun when is_function(fun, 1) -> fun.(result)
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("#{label}: on_violation callback failed: #{Exception.message(e)}")
  end
end
