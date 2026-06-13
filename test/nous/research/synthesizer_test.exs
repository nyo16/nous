defmodule Nous.Research.SynthesizerTest do
  # async: false — swaps the global :model_dispatcher.
  use ExUnit.Case, async: false

  alias Nous.Research.{Finding, Synthesizer}
  alias Nous.Usage

  defmodule ScriptedDispatcher do
    @key {__MODULE__, :output}

    def set_output(text), do: :persistent_term.put(@key, text)
    def set_error(reason), do: :persistent_term.put(@key, {:error, reason})

    def request(_model, _messages, _settings) do
      case :persistent_term.get(@key, "") do
        {:error, reason} ->
          {:error, reason}

        text ->
          {:ok,
           Nous.Message.from_legacy(%{
             parts: [{:text, text}],
             usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
             model_name: "test-model",
             timestamp: DateTime.utc_now()
           })}
      end
    end

    def request_stream(_m, _ms, _s), do: {:ok, []}
    def count_tokens(_), do: 0
  end

  setup do
    Application.put_env(:nous, :model_dispatcher, ScriptedDispatcher)
    on_exit(fn -> Application.delete_env(:nous, :model_dispatcher) end)
    :ok
  end

  defp finding(claim, opts \\ []) do
    Finding.new(%{
      claim: claim,
      source_url: Keyword.get(opts, :source_url, "https://example.com"),
      confidence: Keyword.get(opts, :confidence, 0.7)
    })
  end

  describe "synthesize/2 with no findings" do
    test "returns an empty synthesis without calling the LLM" do
      assert {:ok, synthesis} =
               Synthesizer.synthesize([], gaps: ["what about X?"], contradictions: [])

      assert synthesis.claims == []
      assert synthesis.gaps == ["what about X?"]
      assert synthesis.total_findings == 0
    end
  end

  describe "synthesize/2 parsing the LLM synthesis" do
    test "parses CLAIMS, REMAINING GAPS, and CONTRADICTIONS sections" do
      ScriptedDispatcher.set_output("""
      CLAIMS:
      - France's population is about 68 million (confidence: 0.9) [sources: 1,2]
      - Paris is the capital (confidence: 0.95) [sources: 1]

      REMAINING GAPS:
      - What is the current inflation rate?

      CONTRADICTIONS:
      - Source A says 67M vs Source B says 68M [sources: 1 vs 2]
      """)

      findings = [finding("pop 68M", confidence: 0.9), finding("capital Paris", confidence: 0.95)]

      assert {:ok, s} = Synthesizer.synthesize(findings)
      assert s.total_findings == 2
      assert length(s.claims) == 2
      assert Enum.any?(s.claims, &(&1.text =~ "population"))
      assert Enum.any?(s.gaps, &(&1 =~ "inflation"))
      assert length(s.contradictions) == 1
    end

    test "merges existing contradictions with newly parsed ones" do
      ScriptedDispatcher.set_output("""
      CLAIMS:
      - A claim (confidence: 0.8) [sources: 1]

      CONTRADICTIONS:
      - X vs Y [sources: 1 vs 2]
      """)

      assert {:ok, s} =
               Synthesizer.synthesize([finding("c")], contradictions: ["pre-existing conflict"])

      assert "pre-existing conflict" in s.contradictions
      assert length(s.contradictions) == 2
    end
  end

  describe "synthesize/2 LLM-failure fallback" do
    test "falls back to raw findings as claims when the LLM errors" do
      ScriptedDispatcher.set_error(:provider_down)

      findings = [finding("raw claim one"), finding("raw claim two")]

      assert {:ok, s} = Synthesizer.synthesize(findings)
      assert s.total_findings == 2
      assert length(s.claims) == 2
      assert Enum.any?(s.claims, &(&1.text == "raw claim one"))
    end
  end
end
