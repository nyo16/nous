defmodule Nous.Eval.Agents.StreamingTest do
  @moduledoc """
  Tests for streaming functionality.

  Run with: mix test test/eval/agents/streaming_test.exs --include llm
  OpenRouter: OPENROUTER_API_KEY=... mix test test/eval/agents/streaming_test.exs --include llm --include openrouter
  """

  use ExUnit.Case, async: false

  @moduletag :llm
  @moduletag :eval
  @moduletag :streaming
  @moduletag timeout: 120_000

  @default_model Nous.LLMTestHelper.test_model()

  setup_all do
    case Nous.LLMTestHelper.check_model_available() do
      :ok -> {:ok, model: @default_model}
      {:error, reason} -> {:ok, skip: "LLM not available: #{reason}"}
    end
  end

  describe "Basic Streaming" do
    test "3.1 streams text deltas and emits :complete", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model], instructions: "Be concise")

      {:ok, stream} = Nous.run_stream(agent, "Count from 1 to 5")

      chunks = collect_stream(stream)

      assert length(chunks) > 0, "Expected at least one chunk"

      # Find text deltas
      text_deltas =
        Enum.filter(chunks, fn
          {:text_delta, _} -> true
          _ -> false
        end)

      assert length(text_deltas) > 0, "Expected text deltas in stream"

      # Check for :complete event with aggregated output
      complete =
        Enum.find_value(chunks, fn
          {:complete, result} -> result
          _ -> nil
        end)

      assert complete != nil, "Expected {:complete, result} event"
      assert is_binary(complete.output), "Expected output to be a string"
      assert String.length(complete.output) > 0, "Expected non-empty output"
      assert complete.finish_reason != nil, "Expected finish_reason in result"
    end

    test "3.2 accumulated text in :complete matches concatenated deltas", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      {:ok, stream} = Nous.run_stream(agent, "Say hello world")

      chunks = collect_stream(stream)

      # Build text from deltas
      delta_text =
        Enum.reduce(chunks, "", fn
          {:text_delta, text}, acc -> acc <> text
          _, acc -> acc
        end)

      # Get text from :complete event
      complete_text =
        Enum.find_value(chunks, fn
          {:complete, result} -> result.output
          _ -> nil
        end)

      assert String.length(delta_text) > 0, "Expected accumulated text"
      assert delta_text == complete_text, "Delta text should match :complete output"
    end

    test "3.3 streaming with callbacks", context do
      skip_if_unavailable(context)

      test_pid = self()

      agent =
        Nous.new(context[:model],
          instructions: "Be brief"
        )

      callback_opts = [
        callbacks: %{
          on_llm_new_delta: fn _agent, text ->
            send(test_pid, {:delta, text})
          end
        }
      ]

      {:ok, stream} = Nous.run_stream(agent, "Say hi", callback_opts)

      # Consume stream
      _chunks = Enum.to_list(stream)

      # Check for callback messages
      receive do
        {:delta, _text} -> :ok
      after
        5000 -> flunk("Expected callback to fire")
      end
    end
  end

  describe "Streaming with Tools" do
    test "3.4 streams tool calls", context do
      skip_if_unavailable(context)

      weather_tool =
        Nous.Tool.from_function(
          fn _ctx, %{"city" => city} -> {:ok, "Weather in #{city}: Sunny, 72°F"} end,
          name: "get_weather",
          description: "Get weather for a city",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "city" => %{"type" => "string"}
            },
            "required" => ["city"]
          }
        )

      agent = Nous.new(context[:model], tools: [weather_tool])

      {:ok, stream} = Nous.run_stream(agent, "What's the weather in Tokyo?")

      chunks = collect_stream(stream)

      IO.puts("\n[Streaming Tools] Total chunks: #{length(chunks)}")

      assert length(chunks) > 0, "Expected at least some chunks"
    end
  end

  describe "Streaming Edge Cases" do
    test "3.5 handles long streaming output", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      {:ok, stream} = Nous.run_stream(agent, "Write a 100-word story about a robot")

      chunks = collect_stream(stream)
      text_chunks = Enum.filter(chunks, &match?({:text_delta, _}, &1))

      IO.puts("\n[Long Stream] Chunk count: #{length(text_chunks)}")

      # At least some text should stream back
      assert length(text_chunks) > 0, "Expected text chunks for long output"

      complete =
        Enum.find_value(chunks, fn
          {:complete, result} -> result
          _ -> nil
        end)

      if complete, do: assert(String.length(complete.output) > 20, "Expected substantial output")
    end

    test "3.6 streaming can be consumed partially", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      {:ok, stream} = Nous.run_stream(agent, "Count from 1 to 100")

      # Only take first 5 chunks
      first_chunks = stream |> Enum.take(5)

      assert length(first_chunks) >= 1, "Expected at least one chunk"
    end

    test "3.7 stream to unreachable host produces error", _context do
      # This test doesn't need LMStudio — it tests error propagation
      agent =
        Nous.new("custom:fake-model",
          base_url: "http://localhost:19999/v1",
          api_key: "not-needed"
        )

      case Nous.run_stream(agent, "Hello") do
        {:ok, stream} ->
          events = collect_stream(stream)
          errors = Enum.filter(events, &match?({:error, _}, &1))
          assert length(errors) > 0, "Expected error events for unreachable host"

        {:error, _reason} ->
          # Also acceptable - error at stream init time
          :ok
      end
    end
  end

  describe "Stream Result" do
    test "3.8 :complete event includes output and finish_reason", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      {:ok, stream} = Nous.run_stream(agent, "Say hello")

      chunks = collect_stream(stream)

      complete =
        Enum.find_value(chunks, fn
          {:complete, result} -> result
          _ -> nil
        end)

      assert complete != nil, "Expected :complete event"
      assert Map.has_key?(complete, :output), "Expected :output in result"
      assert Map.has_key?(complete, :finish_reason), "Expected :finish_reason in result"
      assert is_binary(complete.output)
    end
  end

  # ============================================================================
  # OpenRouter Integration Tests
  # ============================================================================

  describe "OpenRouter Streaming" do
    @describetag :openrouter

    setup do
      api_key = System.get_env("OPENROUTER_API_KEY")

      if api_key do
        model_name = System.get_env("OPENROUTER_MODEL", "google/gemini-2.0-flash-001")
        {:ok, openrouter_model: model_name, openrouter_key: api_key}
      else
        {:ok, skip: "OPENROUTER_API_KEY not set"}
      end
    end

    test "streams text end-to-end via OpenRouter", context do
      skip_if_unavailable(context)

      agent =
        Nous.new("custom:#{context[:openrouter_model]}",
          base_url: "https://openrouter.ai/api/v1",
          api_key: context[:openrouter_key],
          instructions: "Be concise. Reply in one sentence."
        )

      {:ok, stream} = Nous.run_stream(agent, "What is 2+2?")

      chunks = collect_stream(stream)

      # Check for auth errors — skip test gracefully if key is invalid
      errors = Enum.filter(chunks, &match?({:error, _}, &1))

      if Enum.any?(errors, fn
           {:error, %{status: s}} -> s in [401, 403]
           _ -> false
         end) do
        IO.puts("\n[OpenRouter] Skipping: API key returned auth error")
      else
        text_deltas = Enum.filter(chunks, &match?({:text_delta, _}, &1))
        assert length(text_deltas) > 0, "Expected text deltas from OpenRouter"

        complete =
          Enum.find_value(chunks, fn
            {:complete, result} -> result
            _ -> nil
          end)

        assert complete != nil, "Expected :complete event from OpenRouter"
        assert String.length(complete.output) > 0

        IO.puts("\n[OpenRouter] Model: #{context[:openrouter_model]}")

        IO.puts(
          "[OpenRouter] Chunks: #{length(text_deltas)}, Output: #{String.length(complete.output)} chars"
        )
      end
    end

    test "OpenRouter streaming with tools", context do
      skip_if_unavailable(context)

      weather_tool =
        Nous.Tool.from_function(
          fn _ctx, %{"city" => city} -> {:ok, "Sunny, 72°F in #{city}"} end,
          name: "get_weather",
          description: "Get current weather for a city",
          parameters: %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string", "description" => "City name"}},
            "required" => ["city"]
          }
        )

      agent =
        Nous.new("custom:#{context[:openrouter_model]}",
          base_url: "https://openrouter.ai/api/v1",
          api_key: context[:openrouter_key],
          tools: [weather_tool]
        )

      {:ok, stream} = Nous.run_stream(agent, "What's the weather in Paris?")

      chunks = collect_stream(stream)

      errors = Enum.filter(chunks, &match?({:error, _}, &1))

      if Enum.any?(errors, fn
           {:error, %{status: s}} -> s in [401, 403]
           _ -> false
         end) do
        IO.puts("\n[OpenRouter Tools] Skipping: API key returned auth error")
      else
        IO.puts("\n[OpenRouter Tools] Chunks: #{length(chunks)}")
        assert length(chunks) > 0, "Expected chunks from OpenRouter with tools"
      end
    end
  end

  # Helper functions

  defp collect_stream(stream) do
    Enum.to_list(stream)
  rescue
    _ -> []
  end

  defp skip_if_unavailable(ctx), do: Nous.LLMTestHelper.skip_if_unavailable(ctx)
end
