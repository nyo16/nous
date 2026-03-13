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
            policy: %{suspicious: :warn, blocked: :block},
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
    * `:policy` — Map of severity to action. Default: `%{suspicious: :warn, blocked: :block}`
    * `:aggregation` — How to combine results from multiple strategies.
      `:any` (default) flags if any strategy flags, `:majority` if more than half flag,
      `:all` only if every strategy flags.
    * `:short_circuit` — When `true`, stops running strategies on first `:blocked` result.
      Default: `false`
    * `:on_violation` — Optional callback function `fn result -> ... end` called when
      input is flagged.
    * `:skip_empty` — Skip checking empty or whitespace-only messages. Default: `true`

  ## Streaming Limitation

  InputGuard operates via the `before_request` plugin hook, which is not invoked
  during `run_stream` in AgentRunner. When using streaming, InputGuard will not
  apply — validate input before calling `run_stream` if needed.

  """

  @behaviour Nous.Plugin

  require Logger

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Plugins.InputGuard.{Policy, Result}

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

    case find_unchecked_user_input(ctx) do
      nil ->
        {ctx, tools}

      {input, index} ->
        # Update the checked index
        ctx = Context.merge_deps(ctx, %{input_guard_last_checked: index})

        # Skip empty input if configured
        if skip_empty?(config) && blank?(input) do
          {ctx, tools}
        else
          run_guard(input, ctx, tools, config)
        end
    end
  end

  # --- Private ---

  defp get_config(ctx) do
    Map.get(ctx.deps, :input_guard_config, %{})
  end

  defp find_unchecked_user_input(ctx) do
    last_checked = Map.get(ctx.deps, :input_guard_last_checked, -1)

    ctx.messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} ->
      if msg.role == :user && idx > last_checked do
        {extract_text(msg), idx}
      end
    end)
  end

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

  defp skip_empty?(config), do: Map.get(config, :skip_empty, true)

  defp blank?(str), do: String.trim(str) == ""

  defp run_guard(input, ctx, tools, config) do
    strategies = Map.get(config, :strategies, [{__MODULE__.Strategies.Pattern, []}])
    short_circuit = Map.get(config, :short_circuit, false)

    results = run_strategies(strategies, input, ctx, short_circuit)
    aggregated = aggregate(results, config)

    # Fire on_violation callback if flagged
    if aggregated.severity != :safe do
      fire_on_violation(aggregated, config)
    end

    # Apply policy
    Policy.apply(aggregated, ctx, tools, config)
  end

  defp run_strategies(strategies, input, ctx, true = _short_circuit) do
    Enum.reduce_while(strategies, [], fn {mod, opts}, acc ->
      case safe_check(mod, input, opts, ctx) do
        {:ok, %Result{severity: :blocked} = result} ->
          {:halt, [result | acc]}

        {:ok, result} ->
          {:cont, [result | acc]}

        :error ->
          {:cont, acc}
      end
    end)
    |> Enum.reverse()
  end

  defp run_strategies(strategies, input, ctx, false = _short_circuit) do
    strategies
    |> Task.async_stream(
      fn {mod, opts} -> safe_check(mod, input, opts, ctx) end,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce([], fn
      {:ok, {:ok, result}}, acc -> [result | acc]
      {:ok, :error}, acc -> acc
      {:exit, _reason}, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp safe_check(mod, input, opts, ctx) do
    mod.check(input, opts, ctx)
  rescue
    e ->
      Logger.warning("InputGuard: Strategy #{inspect(mod)} failed: #{Exception.message(e)}")
      :error
  catch
    kind, reason ->
      Logger.warning(
        "InputGuard: Strategy #{inspect(mod)} failed: #{inspect(kind)} #{inspect(reason)}"
      )

      :error
  end

  defp aggregate([], _config), do: %Result{severity: :safe}

  defp aggregate(results, config) do
    mode = Map.get(config, :aggregation, :any)
    do_aggregate(results, mode)
  end

  defp do_aggregate(results, :any) do
    # Return the most severe result
    results
    |> Enum.sort_by(&severity_rank/1, :desc)
    |> List.first()
    |> case do
      %Result{severity: :safe} = r -> r
      result -> result
    end
  end

  defp do_aggregate(results, :majority) do
    flagged = Enum.count(results, &(&1.severity != :safe))
    total = length(results)

    if flagged > total / 2 do
      results
      |> Enum.reject(&(&1.severity == :safe))
      |> Enum.sort_by(&severity_rank/1, :desc)
      |> List.first()
    else
      %Result{severity: :safe}
    end
  end

  defp do_aggregate(results, :all) do
    if Enum.all?(results, &(&1.severity != :safe)) do
      results
      |> Enum.sort_by(&severity_rank/1, :desc)
      |> List.first()
    else
      %Result{severity: :safe}
    end
  end

  defp severity_rank(%Result{severity: :safe}), do: 0
  defp severity_rank(%Result{severity: :suspicious}), do: 1
  defp severity_rank(%Result{severity: :blocked}), do: 2

  defp fire_on_violation(result, config) do
    case Map.get(config, :on_violation) do
      fun when is_function(fun, 1) -> fun.(result)
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("InputGuard: on_violation callback failed: #{Exception.message(e)}")
  end
end
