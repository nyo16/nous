defmodule Nous.Plugins.InputGuard.Engine do
  @moduledoc """
  The strategy engine shared by `Nous.Plugins.InputGuard` and
  `Nous.Plugins.DecisionGuard`: run a list of
  `Nous.Plugins.InputGuard.Strategy` modules over a text, aggregate their
  verdicts and fail closed on strategies that produced none.

  `run/4` reads these keys from `config` (see `Nous.Plugins.InputGuard` for
  their meaning and defaults): `:strategies`, `:aggregation`,
  `:short_circuit`, `:fail_closed`, `:strategy_timeout`, `:on_violation`.

  ## Options

    * `:telemetry_prefix` - prefix of the dropped-strategy event; the event is
      `prefix ++ [:strategy_dropped]`. Default: `[:nous, :input_guard]`.
    * `:label` - prefix of log messages. Default: `"InputGuard"`.

  ## Telemetry

    * `prefix ++ [:strategy_dropped]` - one or more strategies errored, timed
      out or returned `{:error, reason}`.
      * Measurements: `%{count: integer}`
      * Metadata: `%{aggregation: :any | :majority | :all, fail_closed: boolean}`
  """

  require Logger

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Plugins.InputGuard.Result
  alias Nous.Plugins.InputGuard.Strategies.Pattern

  @default_prefix [:nous, :input_guard]
  @default_label "InputGuard"

  @doc """
  Runs the configured strategies over `input` and returns the aggregated
  `Nous.Plugins.InputGuard.Result`, after the fail-closed upgrade for dropped
  strategies. Calls `config[:on_violation]` when the result is not `:safe`.

  `ctx` is handed to every strategy; it is `nil` on surfaces that have no
  agent context (see `c:Nous.Plugins.InputGuard.Strategy.check/3`).
  """
  @spec run(String.t(), Context.t() | nil, map(), keyword()) :: Result.t()
  def run(input, ctx, config, opts \\ []) do
    prefix = Keyword.get(opts, :telemetry_prefix, @default_prefix)
    label = Keyword.get(opts, :label, @default_label)

    strategies = Map.get(config, :strategies, [{Pattern, []}])
    short_circuit = Map.get(config, :short_circuit, false)
    timeout = Map.get(config, :strategy_timeout, 30_000)

    {results, dropped} = run_strategies(strategies, input, ctx, short_circuit, timeout, label)

    aggregated =
      results
      |> aggregate(length(strategies), config)
      |> apply_fail_closed(dropped, config, prefix, label)

    if aggregated.severity != :safe, do: fire_on_violation(aggregated, config, label)

    aggregated
  end

  @doc """
  The newest user message after the index stored in `ctx.deps[last_checked_key]`
  (default `-1`), as `{text, index}`, or `nil`. Only text parts count.
  """
  @spec unchecked_user_input(Context.t(), atom()) :: {String.t(), non_neg_integer()} | nil
  def unchecked_user_input(ctx, last_checked_key) do
    last_checked = Map.get(ctx.deps, last_checked_key, -1)

    ctx.messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} ->
      if msg.role == :user && idx > last_checked do
        {extract_text(msg), idx}
      end
    end)
  end

  @doc """
  The text a guard classifies for `message`: its content, or its text parts
  joined with spaces.
  """
  @spec message_text(Message.t()) :: String.t()
  def message_text(%Message{} = message), do: extract_text(message)

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
  # apply_fail_closed/5). Strategies skipped by short-circuiting after a
  # :blocked result are NOT drops.
  defp run_strategies(strategies, input, ctx, true = _short_circuit, _timeout, label) do
    {results, dropped} =
      Enum.reduce_while(strategies, {[], 0}, fn {mod, opts}, {acc, dropped} ->
        case safe_check(mod, input, opts, ctx, label) do
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

  # A dropped strategy produced no verdict. Under :any aggregation a single
  # surviving detector decides, so a crashed/timed-out detector silently
  # letting input through is a fail-open hole — upgrade :safe to :suspicious
  # unless the user explicitly opted out. :majority/:all already count drops
  # against the configured denominator, so they default to fail-open-tolerant.
  defp apply_fail_closed(aggregated, 0, _config, _prefix, _label), do: aggregated

  defp apply_fail_closed(aggregated, dropped, config, prefix, label) do
    mode = Map.get(config, :aggregation, :any)
    fail_closed = Map.get(config, :fail_closed, mode == :any)

    :telemetry.execute(prefix ++ [:strategy_dropped], %{count: dropped}, %{
      aggregation: mode,
      fail_closed: fail_closed
    })

    Logger.warning(
      "#{label}: #{dropped} strateg#{if dropped == 1, do: "y", else: "ies"} dropped " <>
        "(error/timeout); fail_closed=#{fail_closed}"
    )

    if fail_closed and aggregated.severity == :safe do
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
    flagged = Enum.count(results, &(&1.severity != :safe))

    if flagged > configured_count / 2 do
      most_severe(results)
    else
      %Result{severity: :safe}
    end
  end

  defp do_aggregate(results, configured_count, :all) do
    # Require EVERY configured strategy to have run AND flagged. A dropped or
    # errored strategy means unanimity can't be confirmed, so don't block.
    flagged = Enum.count(results, &(&1.severity != :safe))

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

  defp fire_on_violation(result, config, label) do
    case Map.get(config, :on_violation) do
      fun when is_function(fun, 1) -> fun.(result)
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("#{label}: on_violation callback failed: #{Exception.message(e)}")
  end
end
