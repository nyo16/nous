defmodule Nous.StreamNormalizer.ToolCallAccumulatorTest do
  use ExUnit.Case, async: true

  alias Nous.StreamNormalizer.ToolCallAccumulator, as: Accumulator

  describe "OpenAI shape" do
    test "single tool call with arguments split across N chunks" do
      acc =
        Accumulator.new()
        |> Accumulator.feed([
          %{
            "index" => 0,
            "id" => "call_abc",
            "function" => %{"name" => "search", "arguments" => "{\"qu"}
          }
        ])
        |> Accumulator.feed([
          %{"index" => 0, "function" => %{"arguments" => "ery\":\"e"}}
        ])
        |> Accumulator.feed([
          %{"index" => 0, "function" => %{"arguments" => "lixir\"}"}}
        ])

      assert [%{"id" => "call_abc", "name" => "search", "arguments" => %{"query" => "elixir"}}] =
               Accumulator.finalize(acc)
    end

    test "multiple tool calls, non-monotonic chunk order, sorted by index" do
      acc =
        Accumulator.new()
        |> Accumulator.feed([
          %{"index" => 1, "id" => "call_b", "function" => %{"name" => "b", "arguments" => "{"}},
          %{"index" => 0, "id" => "call_a", "function" => %{"name" => "a", "arguments" => "{"}}
        ])
        |> Accumulator.feed([
          %{"index" => 1, "function" => %{"arguments" => "\"y\":2}"}},
          %{"index" => 0, "function" => %{"arguments" => "\"x\":1}"}}
        ])

      assert [
               %{"id" => "call_a", "name" => "a", "arguments" => %{"x" => 1}},
               %{"id" => "call_b", "name" => "b", "arguments" => %{"y" => 2}}
             ] = Accumulator.finalize(acc)
    end

    test "later chunks do not overwrite id/name set by first chunk" do
      acc =
        Accumulator.new()
        |> Accumulator.feed([
          %{"index" => 0, "id" => "call_first", "function" => %{"name" => "real_name"}}
        ])
        |> Accumulator.feed([
          %{"index" => 0, "function" => %{"arguments" => "{\"k\":1}"}}
        ])

      assert [%{"id" => "call_first", "name" => "real_name", "arguments" => %{"k" => 1}}] =
               Accumulator.finalize(acc)
    end

    test "empty arguments object yields empty map" do
      acc =
        Accumulator.feed(Accumulator.new(), [
          %{"index" => 0, "id" => "call_x", "function" => %{"name" => "n", "arguments" => "{}"}}
        ])

      assert [%{"arguments" => %{}}] = Accumulator.finalize(acc)
    end

    test "tool call with no arguments at all yields empty map" do
      # Some providers omit arguments entirely (e.g. an empty function call)
      acc =
        Accumulator.feed(Accumulator.new(), [
          %{"index" => 0, "id" => "c", "function" => %{"name" => "n"}}
        ])

      assert [%{"arguments" => %{}}] = Accumulator.finalize(acc)
    end

    test "malformed JSON falls back to error map with raw payload" do
      acc =
        Accumulator.feed(Accumulator.new(), [
          %{
            "index" => 0,
            "id" => "c",
            "function" => %{"name" => "n", "arguments" => "{invalid"}
          }
        ])

      assert [%{"arguments" => %{"error" => "Invalid JSON arguments", "raw" => "{invalid"}}] =
               Accumulator.finalize(acc)
    end

    test "atom-keyed fragments are accepted" do
      acc =
        Accumulator.feed(Accumulator.new(), [
          %{index: 0, id: "c", function: %{name: "n", arguments: "{\"k\":1}"}}
        ])

      assert [%{"id" => "c", "name" => "n", "arguments" => %{"k" => 1}}] =
               Accumulator.finalize(acc)
    end

    test "parity with non-streaming parse_tool_call/1" do
      # Build the same logical response two ways: streamed in fragments
      # vs the non-streaming parser path. They must agree byte-for-byte.
      streamed =
        Accumulator.new()
        |> Accumulator.feed([
          %{"index" => 0, "id" => "call_z", "function" => %{"name" => "f", "arguments" => "{\"a"}}
        ])
        |> Accumulator.feed([
          %{"index" => 0, "function" => %{"arguments" => "\":1,\"b\":[1,2]}"}}
        ])
        |> Accumulator.finalize()

      non_streamed_response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "call_z",
                  "type" => "function",
                  "function" => %{"name" => "f", "arguments" => "{\"a\":1,\"b\":[1,2]}"}
                }
              ]
            }
          }
        ]
      }

      msg = Nous.Messages.from_provider_response(non_streamed_response, :openai)
      assert streamed == msg.tool_calls
    end
  end

  describe "Anthropic shape" do
    test "start → partial × N → stop reconstructs the call" do
      acc =
        Accumulator.new()
        |> Accumulator.feed(%{
          "id" => "tu_a",
          "name" => "search",
          "_index" => 0,
          "_phase" => :start
        })
        |> Accumulator.feed(%{"_index" => 0, "_phase" => :partial, "partial_json" => "{\"q"})
        |> Accumulator.feed(%{
          "_index" => 0,
          "_phase" => :partial,
          "partial_json" => "uery\":\"hi\"}"
        })
        |> Accumulator.feed(%{"_index" => 0, "_phase" => :stop})

      assert [%{"id" => "tu_a", "name" => "search", "arguments" => %{"query" => "hi"}}] =
               Accumulator.finalize(acc)
    end

    test "two interleaved tool_use blocks, sorted by index" do
      acc =
        Accumulator.new()
        |> Accumulator.feed(%{"id" => "t0", "name" => "a", "_index" => 0, "_phase" => :start})
        |> Accumulator.feed(%{"id" => "t1", "name" => "b", "_index" => 1, "_phase" => :start})
        |> Accumulator.feed(%{"_index" => 1, "_phase" => :partial, "partial_json" => "{\"y\":2}"})
        |> Accumulator.feed(%{"_index" => 0, "_phase" => :partial, "partial_json" => "{\"x\":1}"})
        |> Accumulator.feed(%{"_index" => 0, "_phase" => :stop})
        |> Accumulator.feed(%{"_index" => 1, "_phase" => :stop})

      assert [
               %{"id" => "t0", "name" => "a", "arguments" => %{"x" => 1}},
               %{"id" => "t1", "name" => "b", "arguments" => %{"y" => 2}}
             ] = Accumulator.finalize(acc)
    end

    test "partial fragments before start are still accumulated" do
      # Defensive: even if the providers reorder the start, partials
      # land in the right slot
      acc =
        Accumulator.new()
        |> Accumulator.feed(%{
          "_index" => 0,
          "_phase" => :partial,
          "partial_json" => "{\"k\":1}"
        })
        |> Accumulator.feed(%{"id" => "tu", "name" => "n", "_index" => 0, "_phase" => :start})

      assert [%{"id" => "tu", "name" => "n", "arguments" => %{"k" => 1}}] =
               Accumulator.finalize(acc)
    end
  end

  describe "Gemini shape" do
    test "already-complete functionCall is passed through" do
      acc =
        Accumulator.feed(Accumulator.new(), %{
          "name" => "search",
          "arguments" => %{"query" => "elixir"}
        })

      assert [%{"id" => nil, "name" => "search", "arguments" => %{"query" => "elixir"}}] =
               Accumulator.finalize(acc)
    end

    test "multiple sequential calls preserve arrival order" do
      acc =
        Accumulator.new()
        |> Accumulator.feed(%{"name" => "a", "arguments" => %{"k" => 1}})
        |> Accumulator.feed(%{"name" => "b", "arguments" => %{"k" => 2}})

      assert [
               %{"name" => "a", "arguments" => %{"k" => 1}},
               %{"name" => "b", "arguments" => %{"k" => 2}}
             ] = Accumulator.finalize(acc)
    end

    test "calls with empty args yield empty map" do
      acc = Accumulator.feed(Accumulator.new(), %{"name" => "noargs", "arguments" => %{}})
      assert [%{"name" => "noargs", "arguments" => %{}}] = Accumulator.finalize(acc)
    end

    test "Anthropic complete-response fallback shape (input field) is accepted" do
      # When Anthropic streaming degenerates and emits a complete `tool_use`,
      # the normalizer hands us %{"id" => _, "name" => _, "input" => map} — we
      # treat that the same way as Gemini already-complete fragments.
      acc =
        Accumulator.feed(Accumulator.new(), %{
          "id" => "tu_x",
          "name" => "n",
          "input" => %{"k" => 1}
        })

      assert [%{"id" => "tu_x", "name" => "n", "arguments" => %{"k" => 1}}] =
               Accumulator.finalize(acc)
    end
  end

  describe "empty / mixed" do
    test "empty accumulator finalizes to empty list" do
      assert [] = Accumulator.finalize(Accumulator.new())
    end

    test "unknown fragment shapes are silently dropped" do
      acc =
        Accumulator.new()
        |> Accumulator.feed("garbage")
        |> Accumulator.feed(%{"unrelated" => true})

      assert [] = Accumulator.finalize(acc)
    end
  end
end
