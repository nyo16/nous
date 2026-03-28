defmodule Nous.Plugins.Decisions do
  @moduledoc """
  Plugin for agent decision tracking with a directed graph.

  Provides tools for agents to record goals, decisions, and outcomes,
  and injects decision context into the system prompt.

  ## Usage

      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.Decisions],
        deps: %{decisions_config: %{store: Nous.Decisions.Store.ETS}}
      )

  ## Configuration (via `deps[:decisions_config]`)

  **Required:**
    * `:store` - Store backend module (e.g., `Nous.Decisions.Store.ETS`)

  **Optional:**
    * `:store_opts` - Options passed to `store.init/1`
    * `:decision_limit` - Max recent decisions in context (default: 5)
    * `:auto_inject` - Inject decision context into system prompt (default: true)
    * `:inject_strategy` - `:first_only` (default) or `:every_iteration`
  """

  @behaviour Nous.Plugin

  require Logger

  alias Nous.Decisions.ContextBuilder

  @impl true
  def init(_agent, ctx) do
    config = ctx.deps[:decisions_config] || %{}
    store_mod = config[:store]

    unless store_mod do
      Logger.warning(
        "Nous.Plugins.Decisions: No :store configured in deps[:decisions_config]. " <>
          "Decision tools will not function."
      )

      ctx
    else
      store_opts = Map.get(config, :store_opts, [])
      store_opts = if is_map(store_opts), do: Map.to_list(store_opts), else: store_opts

      case store_mod.init(store_opts) do
        {:ok, store_state} ->
          updated_config =
            config
            |> Map.put(:store_state, store_state)
            |> Map.put_new(:auto_inject, true)
            |> Map.put_new(:inject_strategy, :first_only)
            |> Map.put_new(:decision_limit, 5)
            |> Map.put(:_inject_done, false)

          %{ctx | deps: Map.put(ctx.deps, :decisions_config, updated_config)}

        {:error, reason} ->
          Logger.error("Nous.Plugins.Decisions: Store init failed: #{inspect(reason)}")
          ctx
      end
    end
  end

  @impl true
  def tools(_agent, _ctx) do
    []
  end

  @impl true
  def system_prompt(_agent, ctx) do
    config = ctx.deps[:decisions_config] || %{}

    if config[:store_state] do
      store_mod = config[:store]
      state = config[:store_state]
      decision_limit = config[:decision_limit] || 5

      context_text = ContextBuilder.build(store_mod, state, decision_limit: decision_limit)

      base = """
      ## Decisions

      You have access to a decision tracking system. Use these tools:
      - `add_goal` -- Record a new goal or objective.
      - `record_decision` -- Record a decision and optionally link it to a goal.
      - `record_outcome` -- Record the outcome of a decision or action.
      - `query_decisions` -- Query active goals, recent decisions, or graph paths.

      When working on complex tasks, proactively use these tools to track your \
      reasoning process. Record goals at the start, decisions as you make them, \
      and outcomes when you observe results.\
      """

      if context_text do
        base <> "\n\n" <> context_text
      else
        base
      end
    end
  end

  @impl true
  def before_request(_agent, ctx, tools) do
    config = ctx.deps[:decisions_config] || %{}

    should_inject? =
      config[:auto_inject] == true &&
        config[:store_state] != nil &&
        should_inject_this_iteration?(config)

    if should_inject? do
      updated_config = Map.put(config, :_inject_done, true)
      ctx = %{ctx | deps: Map.put(ctx.deps, :decisions_config, updated_config)}
      {ctx, tools}
    else
      {ctx, tools}
    end
  end

  defp should_inject_this_iteration?(config) do
    case config[:inject_strategy] do
      :every_iteration -> true
      _ -> config[:_inject_done] != true
    end
  end
end
