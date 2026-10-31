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
    * `:fail_closed` — How to treat strategies that error or time out ("dropped"
      strategies). When `true`, a dropped strategy upgrades an otherwise-`:safe`
      verdict to `:suspicious`, so a crashed/timed-out detector can't silently
      let input through. Defaults to `true` when `aggregation: :any` (where a
      single surviving detector decides), `false` for `:majority`/`:all` (which
      already count dropped strategies against the configured denominator).
      Dropped strategies always emit a `Logger` warning and a
      `[:nous, :input_guard, :strategy_dropped]` telemetry event.
    * `:strategy_timeout` — Per-strategy timeout in ms for the parallel
      (non-short-circuit) path; a strategy exceeding it is killed and counts
      as dropped. Default: `30_000`
    * `:on_violation` — Optional callback function `fn result -> ... end` called when
      input is flagged.
    * `:skip_empty` — Skip checking empty or whitespace-only messages. Default: `true`

  ## Streaming Limitation

  InputGuard operates via the `before_request` plugin hook, which is not invoked
  during `run_stream` in AgentRunner. When using streaming, InputGuard will not
  apply — validate input before calling `run_stream` if needed.

  """

  @behaviour Nous.Plugin

  alias Nous.Agent.Context
  alias Nous.Plugins.InputGuard.{Engine, Policy}

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

    case Engine.unchecked_user_input(ctx, :input_guard_last_checked) do
      nil ->
        {ctx, tools}

      {input, index} ->
        # Update the checked index
        ctx = Context.merge_deps(ctx, %{input_guard_last_checked: index})

        # Skip empty input if configured
        if skip_empty?(config) && blank?(input) do
          {ctx, tools}
        else
          input
          |> Engine.run(ctx, config, telemetry_prefix: [:nous, :input_guard], label: "InputGuard")
          |> Policy.apply(ctx, tools, config)
        end
    end
  end

  # --- Private ---

  defp get_config(ctx) do
    Map.get(ctx.deps, :input_guard_config, %{})
  end

  defp skip_empty?(config), do: Map.get(config, :skip_empty, true)

  defp blank?(str), do: String.trim(str) == ""
end
