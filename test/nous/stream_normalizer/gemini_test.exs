defmodule Nous.StreamNormalizer.GeminiTest do
  use ExUnit.Case, async: true

  alias Nous.StreamNormalizer.Gemini

  describe "normalize_chunk/1 - text deltas" do
    test "candidate with text part" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Hello"}],
              "role" => "model"
            }
          }
        ]
      }

      assert [{:text_delta, "Hello"}] = Gemini.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - tool call deltas" do
    test "candidate with functionCall part" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "search",
                    "args" => %{"query" => "weather"}
                  }
                }
              ],
              "role" => "model"
            }
          }
        ]
      }

      assert [{:tool_call_delta, %{"name" => "search", "arguments" => %{"query" => "weather"}}}] =
               Gemini.normalize_chunk(chunk)
    end

    test "functionCall without args defaults to empty map" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"functionCall" => %{"name" => "get_time"}}],
              "role" => "model"
            }
          }
        ]
      }

      assert [{:tool_call_delta, %{"name" => "get_time", "arguments" => %{}}}] =
               Gemini.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - finish" do
    test "candidate with finishReason STOP" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Done."}], "role" => "model"},
            "finishReason" => "STOP"
          }
        ]
      }

      assert [{:text_delta, "Done."}, {:finish, "stop"}] = Gemini.normalize_chunk(chunk)
    end

    test "candidate with finishReason MAX_TOKENS" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "truncated"}], "role" => "model"},
            "finishReason" => "MAX_TOKENS"
          }
        ]
      }

      assert [{:text_delta, "truncated"}, {:finish, "length"}] = Gemini.normalize_chunk(chunk)
    end

    test "candidate with finishReason SAFETY" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [], "role" => "model"},
            "finishReason" => "SAFETY"
          }
        ]
      }

      assert [{:finish, "safety"}] = Gemini.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - stream_done" do
    test "stream_done tuple produces finish" do
      assert [{:finish, "stop"}] = Gemini.normalize_chunk({:stream_done, "stop"})
    end
  end

  describe "normalize_chunk/1 - errors" do
    test "error response" do
      chunk = %{
        "error" => %{
          "code" => 429,
          "message" => "Resource exhausted",
          "status" => "RESOURCE_EXHAUSTED"
        }
      }

      assert [{:error, "Resource exhausted"}] = Gemini.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - unknown events" do
    test "empty candidates returns unknown" do
      chunk = %{"candidates" => []}

      assert [{:unknown, _}] = Gemini.normalize_chunk(chunk)
    end

    test "candidate with no parts and no finishReason returns unknown" do
      chunk = %{
        "candidates" => [
          %{"content" => %{"parts" => [], "role" => "model"}}
        ]
      }

      assert [{:unknown, _}] = Gemini.normalize_chunk(chunk)
    end

    test "non-map chunk returns unknown" do
      assert [{:unknown, "garbage"}] = Gemini.normalize_chunk("garbage")
    end
  end

  describe "complete_response?/1" do
    test "true when candidate has finishReason" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Hi"}], "role" => "model"},
            "finishReason" => "STOP"
          }
        ]
      }

      assert Gemini.complete_response?(chunk)
    end

    test "false when no finishReason" do
      chunk = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "partial"}], "role" => "model"}}
        ]
      }

      refute Gemini.complete_response?(chunk)
    end

    test "false for non-candidate data" do
      refute Gemini.complete_response?(%{"usageMetadata" => %{}})
    end

    test "false for non-map" do
      refute Gemini.complete_response?({:stream_done, "stop"})
    end
  end

  describe "convert_complete_response/1" do
    test "converts text response" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Hello world"}], "role" => "model"},
            "finishReason" => "STOP"
          }
        ]
      }

      assert [{:text_delta, "Hello world"}, {:finish, "stop"}] =
               Gemini.convert_complete_response(chunk)
    end

    test "converts tool call response" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "search",
                    "args" => %{"q" => "test"}
                  }
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ]
      }

      assert [
               {:tool_call_delta, %{"name" => "search", "arguments" => %{"q" => "test"}}},
               {:finish, "stop"}
             ] = Gemini.convert_complete_response(chunk)
    end

    test "converts mixed text and tool call response" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "I'll search for that."},
                %{"functionCall" => %{"name" => "search", "args" => %{"q" => "test"}}}
              ],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ]
      }

      assert [
               {:text_delta, "I'll search for that."},
               {:tool_call_delta, %{"name" => "search", "arguments" => %{"q" => "test"}}},
               {:finish, "stop"}
             ] = Gemini.convert_complete_response(chunk)
    end

    test "returns unknown for invalid chunk" do
      assert [{:unknown, %{}}] = Gemini.convert_complete_response(%{})
    end
  end
end
