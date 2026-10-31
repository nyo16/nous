defmodule Nous.Router.DecisionModelLlamaTest do
  @moduledoc """
  Local routing smoke: Clef-Flash routes between two local Qwen chat tiers,
  all in-process through llama_cpp_ex.

  Excluded from the default suite (`@moduletag :llama`). Run with:

      NOUS_LLAMACPP_TEST_MODEL=~/Downloads/Qwen3.5-0.8B-UD-Q4_K_XL.gguf \\
      NOUS_LLAMACPP_TEST_MODEL_LARGE=~/Downloads/Qwen3.5-4B-UD-Q4_K_XL.gguf \\
      NOUS_DECISION_TEST_MODEL=~/Downloads/Cloudflare_clef-flash-Q8_0.gguf \\
        mix test --only llama test/nous/router/decision_model_llama_test.exs

  Compiles only when all three env vars point at existing files and
  `LlamaCppEx.Decision` is available (env read at compile time); otherwise a
  skipped placeholder runs.
  """
  use ExUnit.Case, async: false

  @moduletag :llama
  # Clef-Flash Q8_0 is ~9.7 GB; loading it is slow on a cold cache.
  @moduletag timeout: 900_000
  @moduletag :capture_log

  @small_path System.get_env("NOUS_LLAMACPP_TEST_MODEL")
  @large_path System.get_env("NOUS_LLAMACPP_TEST_MODEL_LARGE")
  @clef_path System.get_env("NOUS_DECISION_TEST_MODEL")
  @runnable Code.ensure_loaded?(LlamaCppEx.Decision) and
              Enum.all?([@small_path, @large_path, @clef_path], fn path ->
                path != nil and File.exists?(Path.expand(path))
              end)

  if @runnable do
    alias Nous.DecisionModel
    alias Nous.DecisionModel.Backend.LlamaCpp

    @load_timeout 600_000

    setup_all do
      :ok = LlamaCppEx.init()
      {:ok, small} = LlamaCppEx.load_model(Path.expand(@small_path), n_gpu_layers: -1)
      {:ok, large} = LlamaCppEx.load_model(Path.expand(@large_path), n_gpu_layers: -1)

      start_supervised!({LlamaCpp, name: :nous_router_clef, source: {:path, @clef_path}})
      dm = DecisionModel.parse("llamacpp:nous_router_clef")
      # Waits for the model load.
      {:ok, _} =
        DecisionModel.decide(dm, "warm up", [ok: [type: :noul, instructions: "ok?"]],
          timeout: @load_timeout
        )

      {:ok, small: small, large: large, dm: dm}
    end

    defp agent(%{small: small, large: large, dm: dm}) do
      Nous.new("llamacpp:qwen-0.8b",
        llamacpp_model: small,
        instructions: "You are terse.",
        model_settings: %{max_tokens: 48, enable_thinking: false},
        router:
          {Nous.Router.DecisionModel,
           model: dm,
           granularity: :per_turn,
           timeout: @load_timeout,
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
    end

    defp drain(ref) do
      receive do
        {event, ^ref, _measurements, meta} -> [{event, meta} | drain(ref)]
      after
        0 -> []
      end
    end

    test "routes each turn to the tier it needs, and that tier serves it", context do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nous, :router, :route],
          [:nous, :provider, :request, :stop]
        ])

      a = agent(context)

      assert {:ok, r1} = Nous.run(a, "What is 2+2?")
      turn1 = drain(ref)

      assert {:ok, _r2} =
               Nous.run(
                 a,
                 "Prove step by step that there are infinitely many prime numbers, " <>
                   "then prove that the square root of 2 is irrational.",
                 context: r1.context
               )

      turn2 = drain(ref)

      for {turn, tier, served} <- [{turn1, :simple, "qwen-0.8b"}, {turn2, :complex, "qwen-4b"}] do
        assert [%{cause: :routed, tier: ^tier, granularity: :per_turn, probabilities: probs}] =
                 for({[:nous, :router, :route], meta} <- turn, do: meta)

        assert [{:simple, _}, {:complex, _}] = probs

        assert [%{provider: :llamacpp, model_name: ^served}] =
                 for({[:nous, :provider, :request, :stop], meta} <- turn, do: meta)
      end
    end
  else
    @tag :skip
    test "router llama smoke (set NOUS_LLAMACPP_TEST_MODEL, NOUS_LLAMACPP_TEST_MODEL_LARGE and NOUS_DECISION_TEST_MODEL)" do
      :ok
    end
  end
end
