defmodule Nous.Tools.SummarizeTest do
  use ExUnit.Case, async: true

  alias Nous.{Message, ModelDispatcher, RunContext, Usage}
  alias Nous.Tools.Summarize

  # Reports the prompt and model it was asked for, then replies with whatever
  # the test parked in the process dictionary. Summarize runs `Nous.Agent.run/2`
  # in the caller process, so `self()` here is the test process.
  defmodule CapturingDispatcher do
    @moduledoc false

    def request(model, messages, _settings) do
      prompt =
        Enum.find_value(messages, fn
          %Message{role: :user, content: content} -> content
          _ -> nil
        end)

      send(self(), {:summarize_request, model, prompt})

      case Process.get(:summarize_reply, {:text, "SUMMARY: fallback"}) do
        {:text, text} ->
          {:ok,
           Message.from_legacy(%{
             parts: [{:text, text}],
             usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
             model_name: "test-model",
             timestamp: DateTime.utc_now()
           })}

        {:error, reason} ->
          {:error, reason}

        :raise ->
          raise "provider exploded"
      end
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0
  end

  # Long enough to clear the 50-character short-circuit.
  @long_text String.duplicate("the quick brown fox jumps over the lazy dog. ", 4)

  setup do
    ModelDispatcher.put_dispatcher(CapturingDispatcher)
    :ok
  end

  defp reply(value), do: Process.put(:summarize_reply, value)

  defp summarize(args, deps \\ %{}) do
    Summarize.summarize(RunContext.new(deps), args)
  end

  describe "short-circuit for trivial text" do
    test "text under 50 characters is returned verbatim without an LLM call" do
      result = summarize(%{"text" => "too short to be worth a round trip"})

      assert result.summary == "too short to be worth a round trip"
      assert result.key_points == ["too short to be worth a round trip"]
      assert result.relevance_score == 1.0

      # The whole point of the branch: no request left the tool.
      refute_received {:summarize_request, _, _}
    end

    test "missing text short-circuits as the empty string" do
      assert %{summary: "", relevance_score: 1.0} = summarize(%{})
      refute_received {:summarize_request, _, _}
    end

    test "text at 50 characters and above does reach the model" do
      summarize(%{"text" => String.duplicate("x", 50)})

      assert_received {:summarize_request, _model, _prompt}
    end
  end

  describe "prompt construction" do
    test "a focus becomes a focus instruction and its absence a general one" do
      summarize(%{"text" => @long_text, "focus" => "battery life"})
      assert_received {:summarize_request, _model, prompt}
      assert prompt =~ "Focus the summary on information relevant to: battery life"
      refute prompt =~ "Provide a general summary."

      summarize(%{"text" => @long_text})
      assert_received {:summarize_request, _model, general_prompt}
      assert general_prompt =~ "Provide a general summary."
    end

    test "max_points is carried into the prompt and defaults to five" do
      summarize(%{"text" => @long_text, "max_points" => 3})
      assert_received {:summarize_request, _model, prompt}
      assert prompt =~ "up to 3 key points"

      summarize(%{"text" => @long_text})
      assert_received {:summarize_request, _model, default_prompt}
      assert default_prompt =~ "up to 5 key points"
    end

    test "text past 15_000 characters is truncated before it is sent" do
      # The only bound on what this tool feeds a provider.
      summarize(%{"text" => String.duplicate("a", 20_000)})

      assert_received {:summarize_request, _model, prompt}
      assert prompt =~ "[...truncated]"
      # Exactly 15_000 of the body survives: bracketing the run of `a`s pins
      # the ceiling without counting the `a`s in the surrounding instructions.
      assert prompt =~ String.duplicate("a", 15_000)
      refute prompt =~ String.duplicate("a", 15_001)
    end

    test "a text under the ceiling is sent whole" do
      summarize(%{"text" => @long_text})

      assert_received {:summarize_request, _model, prompt}
      refute prompt =~ "[...truncated]"
      assert prompt =~ @long_text
    end
  end

  describe "model selection" do
    test "ctx.deps[:summary_model] chooses the model" do
      summarize(%{"text" => @long_text}, %{summary_model: "anthropic:claude-haiku-4"})

      assert_received {:summarize_request, model, _prompt}
      assert model.provider == :anthropic
      assert model.model == "claude-haiku-4"
    end

    test "the default is a cheap OpenAI model, not the caller's own" do
      summarize(%{"text" => @long_text})

      assert_received {:summarize_request, model, _prompt}
      assert model.provider == :openai
      assert model.model == "gpt-4o-mini"
    end
  end

  describe "response parsing" do
    test "splits the three labelled sections" do
      reply(
        {:text,
         """
         SUMMARY: The device lasts a day.
         Battery is the headline.
         KEY POINTS:
         - 24 hour battery
         - fast charging
         RELEVANCE: 0.8
         """}
      )

      result = summarize(%{"text" => @long_text, "focus" => "battery"})

      assert result.summary == "The device lasts a day.\nBattery is the headline."
      # The leading bullet's own "- " survives the split — a real parser wart
      # (the delimiter is `\n-`, so the first bullet has no preceding newline).
      # Pinned as-is so fixing it is a deliberate, visible change.
      assert result.key_points == ["- 24 hour battery", "fast charging"]
      assert result.relevance_score == 0.8
    end

    test "an out-of-range relevance is clamped into 0.0..1.0" do
      for {emitted, expected} <- [{"5.0", 1.0}, {"0.0", 0.0}, {"0.5", 0.5}] do
        reply({:text, "SUMMARY: s\nKEY POINTS:\n- p\nRELEVANCE: #{emitted}"})

        assert summarize(%{"text" => @long_text}).relevance_score == expected
      end
    end

    test "a missing relevance line defaults to the midpoint" do
      reply({:text, "SUMMARY: s\nKEY POINTS:\n- p\n"})

      assert summarize(%{"text" => @long_text}).relevance_score == 0.5
    end

    test "an unlabelled response degrades to the leading text as the summary" do
      reply({:text, "I could not follow the format at all."})

      result = summarize(%{"text" => @long_text})

      assert result.summary == "I could not follow the format at all."
      assert result.key_points == ["I could not follow the format at all."]
      assert result.relevance_score == 0.5
    end
  end

  describe "failure fallbacks" do
    test "a model error yields a truncation-based summary instead of an error tuple" do
      reply({:error, :upstream_down})

      result = summarize(%{"text" => @long_text})

      # A tool result goes back to the model as text; an {:error, _} here would
      # abort the surrounding scrape instead of degrading it.
      assert result.summary == String.slice(@long_text, 0, 500)
      assert result.key_points == [String.slice(@long_text, 0, 200)]
      assert result.relevance_score == 0.5
    end

    test "a raising provider is rescued into the same fallback" do
      reply(:raise)

      result = summarize(%{"text" => @long_text})

      assert result.summary == String.slice(@long_text, 0, 500)
      assert result.relevance_score == 0.5
    end
  end
end
