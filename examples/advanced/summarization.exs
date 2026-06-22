#!/usr/bin/env elixir

# Nous AI - Summarization Plugin
# Auto-compact long conversation history to stay within the context window.
#
# The `Nous.Plugins.Summarization` plugin hooks into the agent lifecycle:
#   - init/2          seeds `:summarization_config` into the run deps
#   - before_request/3 fires before each LLM request; when cumulative usage
#                      (ctx.usage.total_tokens) exceeds `:max_context_tokens`,
#                      it replaces the older messages with a single
#                      "[Conversation Summary]" system message and keeps the
#                      most recent `:keep_recent` messages intact.
#
# Config is a RUN-time concern: the plugin reads it from `deps` passed to
# `Nous.Agent.run/3`, NOT from a struct in `plugins:`. You add the plugin as a
# bare module (`plugins: [Nous.Plugins.Summarization]`) and tune it via
# `deps: %{summarization_config: %{...}}`.
#
# Run with: mix run examples/advanced/summarization.exs
# Requires (for the live LLM path): a running provider, e.g. OPENAI_API_KEY.

alias Nous.{Agent, Message}
alias Nous.Agent.Context
alias Nous.Plugins.Summarization

IO.puts("=== Nous AI - Summarization Plugin Demo ===\n")

# ============================================================================
# Part 1: Deterministic compaction (no provider needed for the trigger logic)
# ============================================================================
#
# We call the plugin's lifecycle callbacks directly with a hand-built context
# whose cumulative usage already exceeds the threshold. This shows the
# before/after message counts regardless of whether an LLM is reachable.
# (generate_summary/3 still needs a provider to produce real summary text; if
# none is available it returns {:error, _} and the plugin keeps all messages.)

IO.puts("--- Part 1: Trigger compaction directly ---")

# A long conversation: 1 system + 12 user/assistant turns.
history =
  [Message.system("You are a helpful assistant.")] ++
    Enum.flat_map(1..6, fn n ->
      [
        Message.user("Question #{n}: tell me fact number #{n}."),
        Message.assistant("Answer #{n}: here is fact number #{n}.")
      ]
    end)

# Low threshold + small keep_recent so compaction is guaranteed to engage.
config = %{
  max_context_tokens: 50,
  keep_recent: 4,
  summary_model: "openai:gpt-4o-mini"
}

agent =
  Agent.new("openai:gpt-4o-mini",
    instructions: "You are a helpful assistant.",
    plugins: [Summarization]
  )

# Build a context the way the runner would, then let the plugin seed its deps.
base_ctx =
  Context.new(
    messages: history,
    deps: %{summarization_config: config},
    # Pretend prior turns already burned tokens past the 50-token threshold.
    usage: %Nous.Usage{requests: 6, total_tokens: 500}
  )

ctx = Summarization.init(agent, base_ctx)

IO.puts(
  "Before: #{length(ctx.messages)} messages " <>
    "(usage #{ctx.usage.total_tokens} tokens > #{config.max_context_tokens} limit)"
)

{compacted_ctx, _tools} = Summarization.before_request(agent, ctx, [])

summary_msg =
  Enum.find(compacted_ctx.messages, fn m ->
    m.role == :system and String.starts_with?(m.content || "", "[Conversation Summary]")
  end)

cond do
  summary_msg ->
    new_count = get_in(compacted_ctx.deps, [:summarization_config, :summary_count])
    IO.puts("After:  #{length(compacted_ctx.messages)} messages (summary_count=#{new_count})")
    IO.puts("Summarized older turns into:")
    IO.puts("  " <> String.slice(summary_msg.content, 0, 200))

  length(compacted_ctx.messages) < length(ctx.messages) ->
    IO.puts("After:  #{length(compacted_ctx.messages)} messages (compacted)")

  true ->
    IO.puts(
      "After:  #{length(compacted_ctx.messages)} messages " <>
        "(no provider reachable; plugin kept all messages — fail-safe)"
    )
end

IO.puts("")

# ============================================================================
# Part 2: Live multi-turn run (degrades gracefully without a provider)
# ============================================================================
#
# Here the agent actually talks to an LLM. We thread the conversation forward
# by feeding `all_messages` from each result back into the next run via
# `messages:`. With a tight `:max_context_tokens`, accumulated usage trips the
# threshold on a later turn and the plugin compacts mid-conversation.

IO.puts("--- Part 2: Live multi-turn conversation ---")

prompts = [
  "Hi! My name is Dana and I'm planning a trip to Japan.",
  "I want to visit Kyoto and Osaka over five days.",
  "What's a good food to try there?",
  "Remind me: what was my name and where am I going?"
]

run_opts = [
  max_iterations: 5,
  deps: %{
    summarization_config: %{
      max_context_tokens: 200,
      keep_recent: 4,
      summary_model: "openai:gpt-4o-mini"
    }
  }
]

result =
  Enum.reduce_while(prompts, {[], 0}, fn prompt, {prior_messages, turn} ->
    IO.puts("\nTurn #{turn + 1} > #{prompt}")

    input =
      if prior_messages == [],
        do: prompt,
        else: [messages: prior_messages ++ [Message.user(prompt)]]

    case Agent.run(agent, input, run_opts) do
      {:ok, res} ->
        IO.puts("  assistant: #{String.slice(res.output, 0, 120)}")

        count = get_in(res.deps, [:summarization_config, :summary_count]) || 0

        IO.puts(
          "  context: #{length(res.all_messages)} messages, " <>
            "#{res.usage.total_tokens} tokens, compactions=#{count}"
        )

        {:cont, {res.all_messages, turn + 1}}

      {:error, reason} ->
        IO.puts("  (no provider reachable: #{inspect(reason)} — skipping live path)")
        {:halt, :no_provider}
    end
  end)

case result do
  :no_provider ->
    IO.puts("\nLive path skipped. Part 1 already demonstrated the compaction logic.")

  {final_messages, turns} ->
    IO.puts(
      "\nCompleted #{turns} turns; final transcript holds " <>
        "#{length(final_messages)} messages after auto-compaction."
    )
end

IO.puts("\nDone!")
