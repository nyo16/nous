#!/usr/bin/env elixir

# Nous AI - Fallback Chains
# Built-in automatic provider/model failover via the :fallback option

IO.puts("=== Nous AI - Fallback Chains ===\n")

# ============================================================================
# Declaring a Fallback Chain
# ============================================================================

IO.puts("--- Declaring a Fallback Chain ---")

IO.puts("""
Pass :fallback to Nous.new/2 (also works on Nous.LLM helpers). It takes an
ordered list of "provider:model" strings and/or %Nous.Model{} structs:

  agent =
    Nous.new("openai:gpt-4o",
      instructions: "You are a helpful assistant.",
      fallback: [
        "anthropic:claude-sonnet-4-5-20250929",
        "lmstudio:qwen3"
      ]
    )

Then just run normally. If the primary fails with a ProviderError or
ModelError (outage, rate limit, 5xx, auth, timeout), Nous transparently
retries the request against the next model in the chain. The first model
that succeeds wins; if all fail, the last error is returned.
""")

# ============================================================================
# Runnable Demo
# ============================================================================
#
# To keep this runnable offline-ish, the primary points at an unreachable
# local server (port 1 never has anything listening), so its request fails
# with a ProviderError. Nous then falls back to a local LM Studio model.
#
# Run a model in LM Studio (http://localhost:1234) to see the fallback
# actually succeed; otherwise both legs fail and you'll see the last error.

IO.puts("--- Runnable Demo ---\n")

primary = "openai:gpt-4o@http://localhost:1"
fallback_model = "lmstudio:qwen3"

IO.puts("Primary (intentionally unreachable): #{primary}")
IO.puts("Fallback (local):                    #{fallback_model}\n")

agent =
  Nous.new(primary,
    instructions: "Be concise.",
    # api_key required so the unreachable primary is attempted at the
    # provider layer (a missing key surfaces as a terminal ConfigurationError,
    # which is NOT fallback-eligible).
    api_key: "sk-not-a-real-key",
    fallback: [fallback_model]
  )

case Nous.run(agent, "What is 2+2? Answer with just the number.") do
  {:ok, result} ->
    IO.puts("Output: #{result.output}")
    # The model that actually served the run is recorded in the run context as
    # `deps[:active_model]` (set when a fallback takes over). It differs from
    # `primary` only when failover happened. You can also observe failover via
    # the `[:nous, :agent, :fallback, :used]` telemetry event.
    served = result.deps[:active_model] || primary
    if served != primary, do: IO.puts("(served by fallback model: #{inspect(served)})")

  {:error, %Nous.Errors.ProviderError{} = err} ->
    # Every model in the chain failed at the provider layer.
    IO.puts("All providers unavailable: #{Exception.message(err)}")

  {:error, reason} ->
    # A non-eligible error short-circuited the chain (e.g. ValidationError).
    IO.inspect(reason, label: "non-fallback error")
end

IO.puts("")

# ============================================================================
# Observing Failover with Telemetry
# ============================================================================
#
# Two distinct events let you watch failover:
#
#   [:nous, :fallback, :activated]
#     Emitted by Nous.Fallback.with_fallback/3 on EACH hop from one model to
#     the next (one event per step in the chain). Metadata: failed_provider,
#     failed_model, next_provider, next_model, reason.
#
#   [:nous, :agent, :fallback, :used]
#     Emitted ONCE by the agent runner when a run actually completed on a
#     non-primary model ("sticky fallback" - the promoted model is reused for
#     the rest of that run). Metadata: agent_name, original_provider,
#     original_model, active_provider, active_model.

IO.puts("--- Telemetry ---")

:telemetry.attach_many(
  "nous-fallback-demo-logger",
  [
    [:nous, :fallback, :activated],
    [:nous, :agent, :fallback, :used]
  ],
  fn event, _measurements, metadata, _config ->
    IO.inspect({event, metadata}, label: "fallback telemetry")
  end,
  nil
)

# Re-run so the attached handlers fire on the hop above.
case Nous.run(agent, "Say hello.") do
  {:ok, result} -> IO.puts("Output: #{String.slice(result.output, 0, 60)}")
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end

:telemetry.detach("nous-fallback-demo-logger")

IO.puts("")

# ============================================================================
# Built-in :fallback vs. the Manual Loop in error_handling.exs
# ============================================================================
#
# examples/advanced/error_handling.exs hand-rolls failover: it loops over a
# list of provider configs and calls Nous.run/2 on each in turn. That manual
# approach falls over on ANY {:error, _} (including tool and validation
# errors), re-runs the whole agent each time, and needs you to instrument
# telemetry yourself.
#
# The built-in :fallback chain only fails over on ProviderError/ModelError
# (transport/provider-layer failures), is sticky within a run, threads stream
# init through the chain, and emits the telemetry events shown above for free.
# Reach for the manual loop only when you need per-provider options (distinct
# API keys, instructions, base URLs) or failover on errors the built-in path
# intentionally treats as terminal.

IO.puts("""
--- :fallback vs. manual loop (error_handling.exs) ---

Aspect           | Manual loop                 | :fallback chain
-----------------|-----------------------------|---------------------------
Error filtering  | Any {:error, _}             | ProviderError/ModelError
Telemetry        | You instrument it           | Built-in activated + used
Sticky in a run  | No (re-runs whole agent)    | Yes (promoted model reused)
Streaming        | Manual                      | Stream init uses the chain

Prefer :fallback for resilience against provider outages.
""")
