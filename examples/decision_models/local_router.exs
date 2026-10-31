#!/usr/bin/env elixir

# Nous AI - Local model routing with a decision model
#
# Clef-Flash (a non-generative decision model) picks, for every turn, which of
# two local Qwen chat models answers: the 0.8B model for easy turns, the 4B
# model for hard ones. Everything runs in-process through llama_cpp_ex: no
# server, no API key.
#
# Needs {:llama_cpp_ex, "~> 0.8.63"} (a dev dependency of Nous) and three GGUF
# files, given through the same env vars as the llama test suite:
#
#   NOUS_LLAMACPP_TEST_MODEL        small chat model  (e.g. Qwen3.5-0.8B-UD-Q4_K_XL.gguf)
#   NOUS_LLAMACPP_TEST_MODEL_LARGE  large chat model  (e.g. Qwen3.5-4B-UD-Q4_K_XL.gguf)
#   NOUS_DECISION_TEST_MODEL        decision model    (e.g. Clef-Flash Q8_0, ggml-org/Clef-Flash-GGUF)
#
# Run:
#
#   NOUS_LLAMACPP_TEST_MODEL=~/Downloads/Qwen3.5-0.8B-UD-Q4_K_XL.gguf \
#   NOUS_LLAMACPP_TEST_MODEL_LARGE=~/Downloads/Qwen3.5-4B-UD-Q4_K_XL.gguf \
#   NOUS_DECISION_TEST_MODEL=~/Downloads/Cloudflare_clef-flash-Q8_0.gguf \
#     mix run examples/decision_models/local_router.exs 2>/dev/null
#
# llama.cpp logs model loading to stderr; `2>/dev/null` hides it.
#
# Clef-Flash Q8_0 is ~9.7 GB; expect ~10 GB of RSS plus the chat models. A
# routing decision takes ~0.5-1 s on an M1 Max.

alias Nous.DecisionModel
alias Nous.DecisionModel.Backend.LlamaCpp

Logger.configure(level: :warning)

defmodule LocalRouterExample do
  # Prints every routing decision ([:nous, :router, :route]).
  def print_route(_event, %{duration: duration}, meta, _config) do
    ms = System.convert_time_unit(duration, :native, :millisecond)

    probs =
      Enum.map_join(meta.probabilities || [], ", ", fn {tier, p} ->
        "#{tier}=#{Float.round(p, 3)}"
      end)

    IO.puts(
      "  route: #{meta.cause} -> #{meta.model_name} " <>
        "(tier #{inspect(meta.tier)}, #{probs}; #{ms} ms)"
    )
  end
end

IO.puts("=== Nous AI - Local Router (Clef-Flash + two Qwen tiers) ===\n")

unless Code.ensure_loaded?(LlamaCppEx.Decision) do
  IO.puts("llama_cpp_ex >= 0.8.63 is not available; add {:llama_cpp_ex, \"~> 0.8.63\"}.")
  System.halt(1)
end

paths =
  for var <- ~w(NOUS_LLAMACPP_TEST_MODEL NOUS_LLAMACPP_TEST_MODEL_LARGE NOUS_DECISION_TEST_MODEL) do
    path = System.get_env(var)

    unless path && File.exists?(Path.expand(path)) do
      IO.puts("Set #{var} to an existing GGUF file (see the header of this script).")
      System.halt(1)
    end

    Path.expand(path)
  end

[small_path, large_path, clef_path] = paths

# ============================================================================
# 1. Load the models
# ============================================================================

# The chat models are plain LlamaCppEx models, passed to the `llamacpp:`
# provider through `llamacpp_model:`.
:ok = LlamaCppEx.init()
IO.puts("Loading chat models...")
{:ok, small} = LlamaCppEx.load_model(small_path, n_gpu_layers: -1)
{:ok, large} = LlamaCppEx.load_model(large_path, n_gpu_layers: -1)

# The decision model lives in its own process, which serialises calls. In an
# application, put this child in your supervision tree.
IO.puts("Starting the Clef-Flash decision process...")

{:ok, _sup} =
  Supervisor.start_link(
    [{LlamaCpp, name: :clef, source: {:path, clef_path}, n_batch: 4096}],
    strategy: :one_for_one
  )

dm = DecisionModel.parse("llamacpp:clef")

# The model loads in the background; the first call waits for it. A warm-up
# call keeps the load time out of the first routed turn.
{t_us, {:ok, _}} =
  :timer.tc(fn ->
    DecisionModel.decide(dm, "warm up", [ok: [type: :noul, instructions: "ok?"]],
      timeout: 600_000
    )
  end)

IO.puts("Clef-Flash ready (load + first call: #{div(t_us, 1000)} ms)\n")

# ============================================================================
# 2. An agent with two routed tiers
# ============================================================================

# `agent.model` (the small model) answers whenever the router has no route:
# a decision below `min_confidence`, a decision-model error or timeout.
agent =
  Nous.new("llamacpp:qwen-0.8b",
    llamacpp_model: small,
    instructions: "You are a concise assistant.",
    model_settings: %{max_tokens: 200, enable_thinking: false},
    router:
      {Nous.Router.DecisionModel,
       model: dm,
       granularity: :per_turn,
       min_confidence: 0.6,
       timeout: 30_000,
       tiers: [
         simple: [
           model: "llamacpp:qwen-0.8b",
           llamacpp_model: small,
           description:
             "Trivial requests: greetings, single-step arithmetic such as 2+2, one-line facts."
         ],
         complex: [
           model: "llamacpp:qwen-4b",
           llamacpp_model: large,
           description:
             "Hard requests: multi-step mathematical proofs, long chains of reasoning, code."
         ]
       ]}
  )

:telemetry.attach(
  "local-router-example",
  [:nous, :router, :route],
  &LocalRouterExample.print_route/4,
  nil
)

# ============================================================================
# 3. Run a few turns
# ============================================================================

prompts = [
  "Hi! What is 2+2?",
  "Prove step by step that there are infinitely many prime numbers, " <>
    "then prove that the square root of 2 is irrational.",
  "Thanks. What is the capital of France?"
]

Enum.reduce(prompts, nil, fn prompt, context ->
  IO.puts("> #{prompt}")
  opts = if context, do: [context: context], else: []
  {:ok, result} = Nous.run(agent, prompt, opts)
  IO.puts("  answer: #{result.output |> String.trim() |> String.slice(0, 300)}\n")
  result.context
end)

# `router: nil` turns routing off for one run: the agent's own model answers
# and no decision is made.
IO.puts("> (router: nil) What is 3+3?")
{:ok, result} = Nous.run(agent, "What is 3+3?", router: nil)
IO.puts("  answer: #{String.trim(result.output)}")
