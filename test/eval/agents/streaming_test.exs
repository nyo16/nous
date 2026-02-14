defmodule Nous.Eval.Agents.StreamingTest do
  @moduledoc """
  Tests for streaming functionality.

  Run with: mix test test/eval/agents/streaming_test.exs --include llm
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
    test "3.1 streams text deltas", context do
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

      # Check for complete event
      complete =
        Enum.find(chunks, fn
          {:complete, _} -> true
          _ -> false
        end)

      assert complete != nil, "Expected complete event"
    end

    test "3.2 accumulates full response", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      {:ok, stream} = Nous.run_stream(agent, "Say hello world")

      # Collect and combine text
      full_text =
        stream
        |> Enum.reduce("", fn
          {:text_delta, text}, acc -> acc <> text
          _, acc -> acc
        end)

      assert String.length(full_text) > 0, "Expected accumulated text"
      assert String.contains?(String.downcase(full_text), "hello"), "Expected 'hello' in response"
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

      # Check for tool-related events
      tool_events =
        Enum.filter(chunks, fn
          {:tool_call, _} -> true
          {:tool_result, _} -> true
          _ -> false
        end)

      IO.puts("\n[Streaming Tools] Total chunks: #{length(chunks)}")
      IO.puts("[Streaming Tools] Tool events: #{length(tool_events)}")

      # Complete event should exist
      complete = Enum.find(chunks, &match?({:complete, _}, &1))
      assert complete != nil, "Expected complete event"
    end
  end

  describe "Streaming Edge Cases" do
    test "3.5 handles long streaming output", context do
      skip_if_unavailable(context)

      agent =
        Nous.new(context[:model],
          model_settings: %{max_tokens: 300}
        )

      {:ok, stream} = Nous.run_stream(agent, "Write a 100-word story about a robot")

      chunks = collect_stream(stream)
      text_chunks = Enum.filter(chunks, &match?({:text_delta, _}, &1))

      IO.puts("\n[Long Stream] Chunk count: #{length(text_chunks)}")

      assert length(text_chunks) > 5, "Expected multiple chunks for long output"
    end

    test "3.6 streaming can be consumed partially", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      {:ok, stream} = Nous.run_stream(agent, "Count from 1 to 100")

      # Only take first 5 chunks
      first_chunks = stream |> Enum.take(5)

      assert length(first_chunks) >= 1, "Expected at least one chunk"
    end
  end

  describe "Stream Metrics" do
    test "3.7 complete event includes metrics", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      {:ok, stream} = Nous.run_stream(agent, "Say hello")

      chunks = collect_stream(stream)

      complete =
        Enum.find_value(chunks, fn
          {:complete, result} -> result
          _ -> nil
        end)

      assert complete != nil, "Expected complete result"
      assert Map.has_key?(complete, :output), "Expected output in result"
      assert Map.has_key?(complete, :usage), "Expected usage in result"
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
