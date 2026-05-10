defmodule Nous.MessagesGeminiTest do
  use ExUnit.Case, async: true
  alias Nous.Messages.Gemini
  alias Nous.Message
  alias Nous.Usage
  alias Nous.StreamNormalizer.Gemini, as: GeminiStream

  describe "from_response/1" do
    test "extracts thought block into reasoning_content" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "Thinking process", "thought" => true},
                %{"text" => "Final answer"}
              ]
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "Final answer"
      assert msg.reasoning_content == "Thinking process"
    end

    test "parses a real Gemini API response" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "Elixir is a functional programming language.",
                  "thoughtSignature" => "EjQKMgG+Pvb7FjrlsiLUH2M4hqMc3WbSE9Q3Pqw+"
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "index" => 0
          }
        ],
        "modelVersion" => "gemini-3.1-flash-lite-preview",
        "responseId" => "S4KoabjaAtTskdUPh_rm-AM",
        "usageMetadata" => %{
          "candidatesTokenCount" => 740,
          "promptTokenCount" => 6,
          "promptTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => 6}],
          "totalTokenCount" => 746
        }
      }

      msg = Gemini.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "Elixir is a functional programming language."
      # thoughtSignature is not thinking content - no reasoning present
      assert msg.reasoning_content == nil or msg.reasoning_content == ""
    end

    test "extracts modelVersion into metadata" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hello"}]}}
        ],
        "modelVersion" => "gemini-3.1-flash-lite-preview"
      }

      msg = Gemini.from_response(response)
      assert msg.metadata.model_name == "gemini-3.1-flash-lite-preview"
    end

    test "falls back to default model_name when modelVersion is absent" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hello"}]}}
        ]
      }

      msg = Gemini.from_response(response)
      assert msg.metadata.model_name == "gemini-model"
    end

    test "parses usage metadata" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hi"}]}}
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        }
      }

      msg = Gemini.from_response(response)
      assert %Usage{} = msg.metadata.usage
      assert msg.metadata.usage.input_tokens == 10
      assert msg.metadata.usage.output_tokens == 20
      assert msg.metadata.usage.total_tokens == 30
    end

    test "handles missing usage metadata" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hi"}]}}
        ]
      }

      msg = Gemini.from_response(response)
      assert %Usage{} = msg.metadata.usage
      assert msg.metadata.usage.input_tokens == 0
      assert msg.metadata.usage.output_tokens == 0
    end

    test "parses function calls" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "get_weather",
                    "args" => %{"location" => "Paris"}
                  }
                }
              ]
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      assert length(msg.tool_calls) == 1
      [call] = msg.tool_calls
      assert call["name"] == "get_weather"
      assert call["arguments"] == %{"location" => "Paris"}
      assert String.starts_with?(call["id"], "gemini_")
    end

    test "handles empty candidates" do
      response = %{"candidates" => []}
      msg = Gemini.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "" or msg.content == nil
    end

    test "joins multiple text parts in a single candidate" do
      # Long Gemini responses are sometimes split across multiple `text`
      # parts. Without consolidation, Message.new!/1 raises because content
      # is :string, not a list of ContentParts.
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "First chunk. "},
                %{"text" => "Second chunk. "},
                %{"text" => "Third chunk."}
              ]
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "First chunk. Second chunk. Third chunk."
    end

    test "skips whitespace-only text parts (regression: Vertex \"\\n\\n\\n\")" do
      # Vertex/Gemini sometimes emits text parts that are pure whitespace,
      # particularly between tool calls or after blocked generations. They
      # should not crash ContentPart.text/1 and should not pollute content.
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "\n\n\n"},
                %{"text" => "real content"}
              ]
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      assert msg.content == "real content"
    end

    test "skips text part that is only whitespace with no other content" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "\n\n\n"}]}}
        ]
      }

      msg = Gemini.from_response(response)
      # Message's own changeset trims "" → nil; either result is fine here.
      assert msg.content in [nil, ""]
    end

    test "captures finishReason in metadata" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hi"}]}, "finishReason" => "STOP"}
        ]
      }

      msg = Gemini.from_response(response)
      assert msg.metadata.finish_reason == "STOP"
    end

    test "captures promptFeedback when present" do
      response = %{
        "candidates" => [%{"content" => %{"parts" => []}, "finishReason" => "SAFETY"}],
        "promptFeedback" => %{"blockReason" => "SAFETY"}
      }

      msg = Gemini.from_response(response)
      assert msg.metadata.finish_reason == "SAFETY"
      assert msg.metadata.prompt_feedback == %{"blockReason" => "SAFETY"}
    end

    test "parses functionCall without args (nullary tool)" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"functionCall" => %{"name" => "get_time"}}]
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      assert [%{"name" => "get_time", "arguments" => %{}}] = msg.tool_calls
    end

    test "joins multiple thought parts into reasoning_content" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "Thinking step 1. ", "thought" => true},
                %{"text" => "Thinking step 2.", "thought" => true},
                %{"text" => "Final answer."}
              ]
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      assert msg.content == "Final answer."
      assert msg.reasoning_content == "Thinking step 1. Thinking step 2."
    end
  end

  describe "to_format/1" do
    test "includes reasoning_content as a thought part" do
      msg = Message.new!(%{role: :assistant, content: "Answer", reasoning_content: "Thoughts"})

      {_sys, formatted} = Gemini.to_format([msg])
      gemini_msg = List.first(formatted)

      assert gemini_msg["role"] == "model"

      parts = gemini_msg["parts"]

      assert Enum.any?(parts, fn part ->
               part["thought"] == true and part["text"] == "Thoughts"
             end)

      assert Enum.any?(parts, fn part -> part["text"] == "Answer" end)
    end

    test "extracts system messages into system prompt" do
      messages = [
        Message.new!(%{role: :system, content: "Be helpful"}),
        Message.new!(%{role: :user, content: "Hello"})
      ]

      {system_prompt, contents} = Gemini.to_format(messages)
      assert system_prompt == "Be helpful"
      assert length(contents) == 1
      assert hd(contents)["role"] == "user"
    end

    test "returns nil system prompt when no system messages" do
      messages = [Message.new!(%{role: :user, content: "Hello"})]

      {system_prompt, _contents} = Gemini.to_format(messages)
      assert system_prompt == nil
    end

    test "converts user messages" do
      messages = [Message.new!(%{role: :user, content: "What is Elixir?"})]

      {_sys, [msg]} = Gemini.to_format(messages)
      assert msg == %{"role" => "user", "parts" => [%{"text" => "What is Elixir?"}]}
    end

    test "converts assistant messages to model role" do
      messages = [Message.new!(%{role: :assistant, content: "Hello!"})]

      {_sys, [msg]} = Gemini.to_format(messages)
      assert msg["role"] == "model"
      assert Enum.any?(msg["parts"], &(&1["text"] == "Hello!"))
    end

    test "converts tool result messages to functionResponse" do
      messages = [
        Message.new!(%{
          role: :tool,
          content: ~s({"temp": 22}),
          tool_call_id: "get_weather"
        })
      ]

      {_sys, [msg]} = Gemini.to_format(messages)
      assert msg["role"] == "user"
      [part] = msg["parts"]
      assert part["functionResponse"]["name"] == "get_weather"
      assert part["functionResponse"]["response"] == %{"temp" => 22}
    end

    test "wraps plain text tool result" do
      messages = [
        Message.new!(%{
          role: :tool,
          content: "some plain result",
          tool_call_id: "my_tool"
        })
      ]

      {_sys, [msg]} = Gemini.to_format(messages)
      [part] = msg["parts"]
      assert part["functionResponse"]["response"] == %{"result" => "some plain result"}
    end

    test "concatenates multiple system messages" do
      messages = [
        Message.new!(%{role: :system, content: "First instruction"}),
        Message.new!(%{role: :system, content: "Second instruction"}),
        Message.new!(%{role: :user, content: "Hi"})
      ]

      {system_prompt, contents} = Gemini.to_format(messages)
      assert system_prompt == "First instruction\n\nSecond instruction"
      assert length(contents) == 1
    end

    test "echoes thoughtSignature on assistant tool call when present in metadata" do
      tool_call = %{
        "id" => "call_1",
        "name" => "search",
        "arguments" => %{"q" => "elixir"},
        "metadata" => %{"thought_signature" => "EjQK...sig"}
      }

      msg = Message.new!(%{role: :assistant, content: nil, tool_calls: [tool_call]})

      {_sys, [encoded]} = Gemini.to_format([msg])

      assert [%{"functionCall" => %{"name" => "search"}, "thoughtSignature" => "EjQK...sig"}] =
               encoded["parts"]
    end

    test "omits thoughtSignature when metadata absent" do
      tool_call = %{"id" => "call_1", "name" => "search", "arguments" => %{}}
      msg = Message.new!(%{role: :assistant, content: nil, tool_calls: [tool_call]})

      {_sys, [encoded]} = Gemini.to_format([msg])

      [part] = encoded["parts"]
      refute Map.has_key?(part, "thoughtSignature")
    end
  end

  describe "thoughtSignature round-trip" do
    test "parse_content captures thoughtSignature on tool call" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{"name" => "search", "args" => %{"q" => "elixir"}},
                  "thoughtSignature" => "EjQK...sig"
                }
              ],
              "role" => "model"
            }
          }
        ]
      }

      msg = Gemini.from_response(response)

      assert [%{"name" => "search", "metadata" => %{"thought_signature" => "EjQK...sig"}}] =
               msg.tool_calls
    end

    test "from_response → to_format preserves the signature" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{"name" => "search", "args" => %{"q" => "elixir"}},
                  "thoughtSignature" => "EjQK...sig"
                }
              ],
              "role" => "model"
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      {_sys, [encoded]} = Gemini.to_format([msg])

      assert Enum.any?(encoded["parts"], fn part ->
               part["thoughtSignature"] == "EjQK...sig" and
                 get_in(part, ["functionCall", "name"]) == "search"
             end)
    end
  end

  describe "build_tools/2" do
    test "returns nil when no function declarations and no native tools" do
      assert Gemini.build_tools([], nil) == nil
      assert Gemini.build_tools([], []) == nil
    end

    test "wraps function declarations in functionDeclarations entry" do
      decls = [%{"name" => "search", "description" => "x", "parameters" => %{}}]

      assert Gemini.build_tools(decls, nil) == [%{"functionDeclarations" => decls}]
    end

    test "emits native tools as separate entries" do
      assert Gemini.build_tools([], [:google_search]) == [%{"googleSearch" => %{}}]
      assert Gemini.build_tools([], [:url_context]) == [%{"urlContext" => %{}}]
      assert Gemini.build_tools([], [:code_execution]) == [%{"codeExecution" => %{}}]
    end

    test "combines function declarations with native tools" do
      decls = [%{"name" => "x"}]

      assert Gemini.build_tools(decls, [:google_search]) == [
               %{"functionDeclarations" => decls},
               %{"googleSearch" => %{}}
             ]
    end

    test "supports {tool, config} tuple form" do
      assert Gemini.build_tools([], [{:google_search, %{"some" => "config"}}]) == [
               %{"googleSearch" => %{"some" => "config"}}
             ]
    end

    test "passes raw map entries through" do
      assert Gemini.build_tools([], [%{"customTool" => %{}}]) == [%{"customTool" => %{}}]
    end
  end

  describe "normalize_safety_settings/1" do
    test "returns nil for nil" do
      assert Gemini.normalize_safety_settings(nil) == nil
    end

    test "stringifies atom keys" do
      assert Gemini.normalize_safety_settings([
               %{category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_LOW_AND_ABOVE"}
             ]) == [
               %{
                 "category" => "HARM_CATEGORY_DANGEROUS_CONTENT",
                 "threshold" => "BLOCK_LOW_AND_ABOVE"
               }
             ]
    end

    test "passes string-keyed entries through" do
      input = [%{"category" => "HARM_CATEGORY_HARASSMENT", "threshold" => "BLOCK_NONE"}]
      assert Gemini.normalize_safety_settings(input) == input
    end
  end

  describe "normalize_tool_choice/1" do
    test ":auto produces AUTO mode" do
      assert Gemini.normalize_tool_choice(:auto) == %{
               "functionCallingConfig" => %{"mode" => "AUTO"}
             }
    end

    test ":any and :required produce ANY mode" do
      expected = %{"functionCallingConfig" => %{"mode" => "ANY"}}
      assert Gemini.normalize_tool_choice(:any) == expected
      assert Gemini.normalize_tool_choice(:required) == expected
    end

    test ":none produces NONE mode" do
      assert Gemini.normalize_tool_choice(:none) == %{
               "functionCallingConfig" => %{"mode" => "NONE"}
             }
    end

    test "{:any, names} restricts to allowed function names" do
      assert Gemini.normalize_tool_choice({:any, ["a", "b"]}) == %{
               "functionCallingConfig" => %{
                 "mode" => "ANY",
                 "allowedFunctionNames" => ["a", "b"]
               }
             }
    end

    test "raw map passes through" do
      raw = %{"functionCallingConfig" => %{"mode" => "AUTO"}}
      assert Gemini.normalize_tool_choice(raw) == raw
    end

    test "nil returns nil" do
      assert Gemini.normalize_tool_choice(nil) == nil
    end
  end

  describe "json_config_for_settings/1" do
    test "returns empty map when no JSON keys are set" do
      assert Gemini.json_config_for_settings(%{}) == %{}
    end

    test ":json_response true forces application/json mime type" do
      assert Gemini.json_config_for_settings(%{json_response: true}) == %{
               "responseMimeType" => "application/json"
             }
    end

    test ":json_schema sets schema and forces mime type" do
      schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "number"}}}

      assert Gemini.json_config_for_settings(%{json_schema: schema}) == %{
               "responseMimeType" => "application/json",
               "responseSchema" => schema
             }
    end

    test ":json_schema wins over :json_response" do
      schema = %{"type" => "object"}

      assert %{"responseSchema" => ^schema} =
               Gemini.json_config_for_settings(%{json_schema: schema, json_response: true})
    end

    test ":response_format json_schema shape maps through" do
      schema = %{"type" => "object"}

      assert Gemini.json_config_for_settings(%{
               response_format: %{type: :json_schema, schema: schema}
             }) == %{
               "responseMimeType" => "application/json",
               "responseSchema" => schema
             }
    end

    test ":response_format json_object shape forces mime type only" do
      assert Gemini.json_config_for_settings(%{response_format: %{type: :json_object}}) == %{
               "responseMimeType" => "application/json"
             }
    end
  end

  describe "normalize_thinking_config/1" do
    test "converts Elixir snake_case keys to Vertex camelCase" do
      assert Gemini.normalize_thinking_config(%{
               thinking_budget: 1024,
               include_thoughts: true
             }) == %{"thinkingBudget" => 1024, "includeThoughts" => true}
    end

    test "passes through native Vertex shape unchanged" do
      assert Gemini.normalize_thinking_config(%{
               "thinkingBudget" => 2048,
               "includeThoughts" => false
             }) == %{"thinkingBudget" => 2048, "includeThoughts" => false}
    end

    test "passes through unknown atom keys as strings" do
      assert Gemini.normalize_thinking_config(%{custom_field: "x"}) == %{"custom_field" => "x"}
    end

    test "returns nil for nil input" do
      assert Gemini.normalize_thinking_config(nil) == nil
    end
  end

  describe "from_messages/1" do
    test "converts user messages" do
      gemini_msgs = [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]

      [msg] = Gemini.from_messages(gemini_msgs)
      assert msg.role == :user
      assert msg.content == "Hello"
    end

    test "converts model messages to assistant role" do
      gemini_msgs = [%{"role" => "model", "parts" => [%{"text" => "Hi there"}]}]

      [msg] = Gemini.from_messages(gemini_msgs)
      assert msg.role == :assistant
      assert msg.content == "Hi there"
    end

    test "separates thought parts into reasoning_content" do
      gemini_msgs = [
        %{
          "role" => "model",
          "parts" => [
            %{"text" => "Let me think...", "thought" => true},
            %{"text" => "The answer is 42"}
          ]
        }
      ]

      [msg] = Gemini.from_messages(gemini_msgs)
      assert msg.content == "The answer is 42"
      assert msg.reasoning_content == "Let me think..."
    end

    test "parses function calls from messages" do
      gemini_msgs = [
        %{
          "role" => "model",
          "parts" => [
            %{"functionCall" => %{"name" => "search", "args" => %{"q" => "elixir"}}}
          ]
        }
      ]

      [msg] = Gemini.from_messages(gemini_msgs)
      assert length(msg.tool_calls) == 1
      [call] = msg.tool_calls
      assert call["name"] == "search"
      assert call["arguments"] == %{"q" => "elixir"}
    end
  end

  describe "StreamNormalizer" do
    test "emits thinking delta when thought is true" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "Thinking step", "thought" => true}
              ]
            }
          }
        ]
      }

      events = GeminiStream.normalize_chunk(chunk)
      assert [{:thinking_delta, "Thinking step"}] = events
    end
  end

  describe "multimodal message formatting" do
    alias Nous.Message.ContentPart

    test "formats user message with data URL image as inlineData" do
      msg =
        Message.user([
          ContentPart.text("Describe this image"),
          ContentPart.image_url("data:image/jpeg;base64,/9j/4AAQSkZJRg==")
        ])

      {_sys, [formatted]} = Gemini.to_format([msg])
      assert formatted["role"] == "user"

      [text_part, image_part] = formatted["parts"]
      assert text_part == %{"text" => "Describe this image"}
      assert image_part["inlineData"]["mimeType"] == "image/jpeg"
      assert image_part["inlineData"]["data"] == "/9j/4AAQSkZJRg=="
    end

    test "extracts correct mimeType from PNG data URL" do
      msg =
        Message.user([
          ContentPart.text("What is this?"),
          ContentPart.image_url("data:image/png;base64,iVBORw0KGgo=")
        ])

      {_sys, [formatted]} = Gemini.to_format([msg])

      image_part =
        Enum.find(formatted["parts"], &Map.has_key?(&1, "inlineData"))

      assert image_part["inlineData"]["mimeType"] == "image/png"
      assert image_part["inlineData"]["data"] == "iVBORw0KGgo="
    end

    test "formats HTTP URL as fileData" do
      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image_url("https://example.com/photo.jpg")
        ])

      {_sys, [formatted]} = Gemini.to_format([msg])

      file_part =
        Enum.find(formatted["parts"], &Map.has_key?(&1, "fileData"))

      assert file_part["fileData"]["fileUri"] == "https://example.com/photo.jpg"
      assert file_part["fileData"]["mimeType"] == "image/jpeg"
    end

    test "formats :image content part as inlineData" do
      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image("raw_base64_data", media_type: "image/webp")
        ])

      {_sys, [formatted]} = Gemini.to_format([msg])

      image_part =
        Enum.find(formatted["parts"], &Map.has_key?(&1, "inlineData"))

      assert image_part["inlineData"]["mimeType"] == "image/webp"
      assert image_part["inlineData"]["data"] == "raw_base64_data"
    end

    test "formats multiple images in one message" do
      msg =
        Message.user([
          ContentPart.text("Compare"),
          ContentPart.image_url("data:image/jpeg;base64,abc123"),
          ContentPart.image_url("data:image/png;base64,def456")
        ])

      {_sys, [formatted]} = Gemini.to_format([msg])

      image_parts =
        Enum.filter(formatted["parts"], &Map.has_key?(&1, "inlineData"))

      assert length(image_parts) == 2
      assert Enum.at(image_parts, 0)["inlineData"]["mimeType"] == "image/jpeg"
      assert Enum.at(image_parts, 1)["inlineData"]["mimeType"] == "image/png"
    end

    test "detects MIME type from HTTP URL extension" do
      msg =
        Message.user([
          ContentPart.image_url("https://example.com/image.png")
        ])

      {_sys, [formatted]} = Gemini.to_format([msg])

      file_part =
        Enum.find(formatted["parts"], &Map.has_key?(&1, "fileData"))

      assert file_part["fileData"]["mimeType"] == "image/png"
    end
  end
end
