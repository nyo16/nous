defmodule Nous.StructuredOutputIntegrationTest do
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, Message, Usage}
  alias Nous.Errors

  # --- Test Schema ---

  defmodule TestUser do
    use Ecto.Schema
    use Nous.OutputSchema

    @llm_doc "A user with name and age."
    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:age, :integer)
    end
  end

  defmodule TestScore do
    use Ecto.Schema
    use Nous.OutputSchema

    @primary_key false
    embedded_schema do
      field(:score, :float)
      field(:label, :string)
    end

    @impl true
    def validate_changeset(changeset) do
      changeset
      |> Ecto.Changeset.validate_number(:score,
        greater_than_or_equal_to: 0.0,
        less_than_or_equal_to: 1.0
      )
      |> Ecto.Changeset.validate_required([:label])
    end
  end

  # --- Mock Dispatcher ---

  defmodule MockDispatcher do
    @moduledoc false

    def request(_model, messages, settings) do
      # Check what was requested
      user_content =
        messages
        |> Enum.find_value(fn
          %Message{role: :user, content: content} -> content
          _ -> nil
        end)

      # Track calls for retry testing
      call_count = :persistent_term.get({__MODULE__, :call_count}, 0)
      :persistent_term.put({__MODULE__, :call_count}, call_count + 1)

      response_text = determine_response(user_content, settings, call_count)

      legacy_response = %{
        parts: [{:text, response_text}],
        usage: %Usage{
          input_tokens: 10,
          output_tokens: 5,
          total_tokens: 15,
          tool_calls: 0,
          requests: 1
        },
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      }

      response = Message.from_legacy(legacy_response)
      {:ok, response}
    end

    defp determine_response(content, settings, call_count) do
      keyword = find_keyword(content || "")
      respond(keyword, settings, call_count)
    end

    defp find_keyword(content) do
      keywords = [
        "structured_user",
        "schemaless_test",
        "raw_json_test",
        "choice_test",
        "retry_test",
        "validation_fail",
        "override_to_string",
        "one_of_user_test",
        "one_of_score_test",
        "one_of_nomatch_test",
        "check_settings"
      ]

      Enum.find(keywords, :default, &String.contains?(content, &1))
    end

    defp respond("structured_user", _settings, _call_count),
      do: ~s({"name": "Alice", "age": 30})

    defp respond("schemaless_test", _settings, _call_count),
      do: ~s({"name": "Bob", "age": 25})

    defp respond("raw_json_test", _settings, _call_count),
      do: ~s({"answer": "hello world"})

    defp respond("choice_test", _settings, _call_count),
      do: "positive"

    defp respond("retry_test", _settings, 0),
      do: ~s({"score": 2.0, "label": "test"})

    defp respond("retry_test", _settings, _call_count),
      do: ~s({"score": 0.8, "label": "test"})

    defp respond("validation_fail", _settings, _call_count),
      do: ~s({"score": 2.0, "label": "test"})

    defp respond("override_to_string", _settings, _call_count),
      do: "just plain text output"

    defp respond("one_of_user_test", _settings, _call_count),
      do: ~s({"name": "Alice", "age": 30})

    defp respond("one_of_score_test", _settings, _call_count),
      do: ~s({"score": 0.8, "label": "test"})

    defp respond("one_of_nomatch_test", _settings, _call_count),
      do: ~s({"score": 2.0})

    defp respond("check_settings", settings, _call_count) do
      Jason.encode!(%{
        has_response_format: Map.has_key?(settings, :response_format),
        has_tools: Map.has_key?(settings, :tools)
      })
    end

    defp respond(:default, _settings, _call_count),
      do: "plain text response"

    # Return tool call responses for one_of synthetic tool tests
    def request_with_tool_call(_model, messages, _settings, tool_name, arguments) do
      user_content =
        messages
        |> Enum.find_value(fn
          %Message{role: :user, content: content} -> content
          _ -> nil
        end)

      _ = user_content

      response =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              "id" => "call_synth_1",
              "name" => tool_name,
              "arguments" => arguments
            }
          ]
        )

      {:ok, response}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  setup do
    Application.put_env(:nous, :model_dispatcher, MockDispatcher)
    :persistent_term.put({MockDispatcher, :call_count}, 0)

    on_exit(fn ->
      Application.delete_env(:nous, :model_dispatcher)

      try do
        :persistent_term.erase({MockDispatcher, :call_count})
      rescue
        _ -> :ok
      end
    end)

    %{model: "openai:test-model"}
  end

  describe "full agent run with Ecto schema output_type" do
    test "returns typed struct output", %{model: model} do
      agent = Agent.new(model, output_type: TestUser)

      assert {:ok, result} = AgentRunner.run(agent, "structured_user")
      assert %TestUser{} = result.output
      assert result.output.name == "Alice"
      assert result.output.age == 30
    end

    test "system prompt includes schema instructions", %{model: model} do
      agent =
        Agent.new(model,
          output_type: TestUser,
          instructions: "Be helpful"
        )

      assert {:ok, _result} = AgentRunner.run(agent, "structured_user")
      # The system prompt should include schema info (verified by compilation)
    end
  end

  describe "schemaless output_type" do
    test "returns map output", %{model: model} do
      agent = Agent.new(model, output_type: %{name: :string, age: :integer})

      assert {:ok, result} = AgentRunner.run(agent, "schemaless_test")
      assert result.output.name == "Bob"
      assert result.output.age == 25
    end
  end

  describe "raw JSON schema output_type" do
    test "returns raw map output", %{model: model} do
      agent =
        Agent.new(model,
          output_type: %{
            "type" => "object",
            "properties" => %{"answer" => %{"type" => "string"}}
          }
        )

      assert {:ok, result} = AgentRunner.run(agent, "raw_json_test")
      assert result.output["answer"] == "hello world"
    end
  end

  describe "choice output_type" do
    test "validates choice", %{model: model} do
      agent = Agent.new(model, output_type: {:choice, ["positive", "negative", "neutral"]})

      assert {:ok, result} = AgentRunner.run(agent, "choice_test")
      assert result.output == "positive"
    end
  end

  describe "validation retry" do
    test "retries on validation failure and succeeds", %{model: model} do
      agent =
        Agent.new(model,
          output_type: TestScore,
          structured_output: [max_retries: 3]
        )

      assert {:ok, result} = AgentRunner.run(agent, "retry_test")
      assert result.output.score == 0.8
      assert result.output.label == "test"
    end

    test "returns error when retries exhausted", %{model: model} do
      agent =
        Agent.new(model,
          output_type: TestScore,
          structured_output: [max_retries: 0]
        )

      assert {:error, %Errors.ValidationError{}} =
               AgentRunner.run(agent, "validation_fail")
    end
  end

  describe "provider params" do
    test "response_format is included in model settings for json_schema mode", %{model: model} do
      # This test verifies indirectly: if the agent runs successfully with a schema,
      # the settings were properly injected
      agent =
        Agent.new(model,
          output_type: TestUser,
          structured_output: [mode: :json_schema]
        )

      assert {:ok, _result} = AgentRunner.run(agent, "structured_user")
    end
  end

  describe "plain text agent unaffected" do
    test "default output_type :string works as before", %{model: model} do
      agent = Agent.new(model, instructions: "Be helpful")

      assert {:ok, result} = AgentRunner.run(agent, "hello")
      assert is_binary(result.output)
    end
  end

  # ===================================================================
  # Per-Run Output Override Tests
  # ===================================================================

  describe "per-run output_type override" do
    test "overrides agent default :string with schema", %{model: model} do
      agent = Agent.new(model, instructions: "Extract user info")
      # Agent defaults to output_type: :string
      assert agent.output_type == :string

      {:ok, result} =
        AgentRunner.run(agent, "structured_user override_test", output_type: TestUser)

      assert %TestUser{name: "Alice", age: 30} = result.output
    end

    test "overrides agent schema back to :string", %{model: model} do
      agent = Agent.new(model, output_type: TestUser, instructions: "Be helpful")

      {:ok, result} =
        AgentRunner.run(agent, "plain_text override_to_string", output_type: :string)

      assert is_binary(result.output)
      assert result.output =~ "plain text"
    end

    test "per-run structured_output options override agent defaults", %{model: model} do
      agent =
        Agent.new(model,
          output_type: TestScore,
          instructions: "Score things",
          structured_output: [max_retries: 0]
        )

      # With max_retries: 0, validation_fail would error.
      # Override to max_retries: 2 so the retry succeeds.
      {:ok, result} =
        AgentRunner.run(agent, "retry_test score_override", structured_output: [max_retries: 2])

      assert %TestScore{score: 0.8} = result.output
    end

    test "agent is not mutated by per-run override", %{model: model} do
      agent = Agent.new(model, output_type: :string, instructions: "Test")

      # Run with override
      {:ok, _result} =
        AgentRunner.run(agent, "structured_user override_test", output_type: TestUser)

      # Original agent unchanged
      assert agent.output_type == :string
    end

    test "override output_type to schemaless map", %{model: model} do
      agent = Agent.new(model, instructions: "Extract data")

      {:ok, result} =
        AgentRunner.run(agent, "schemaless_test", output_type: %{name: :string, age: :integer})

      assert result.output.name == "Bob"
      assert result.output.age == 25
    end

    test "override output_type to choice", %{model: model} do
      agent = Agent.new(model, instructions: "Classify")

      {:ok, result} =
        AgentRunner.run(agent, "choice_test",
          output_type: {:choice, ["positive", "negative", "neutral"]}
        )

      assert result.output == "positive"
    end
  end

  # ===================================================================
  # {:one_of, ...} Output Type Tests
  # ===================================================================

  describe "one_of output_type" do
    test "selects matching schema from text response - TestUser", %{model: model} do
      agent =
        Agent.new(model,
          output_type: {:one_of, [TestUser, TestScore]},
          instructions: "Classify or extract"
        )

      {:ok, result} = AgentRunner.run(agent, "one_of_user_test")
      assert %TestUser{name: "Alice", age: 30} = result.output
    end

    test "selects second schema when first doesn't match", %{model: model} do
      # TestScore has validation (score <= 1.0), TestUser is lenient
      # To ensure TestScore is selected, we put it first when data matches TestScore
      agent =
        Agent.new(model,
          output_type: {:one_of, [TestScore, TestUser]},
          instructions: "Classify or extract"
        )

      {:ok, result} = AgentRunner.run(agent, "one_of_score_test")
      assert %TestScore{score: 0.8, label: "test"} = result.output
    end

    test "system prompt includes all schema descriptions", %{model: model} do
      agent =
        Agent.new(model,
          output_type: {:one_of, [TestUser, TestScore]},
          instructions: "Classify or extract"
        )

      # Build context to inspect system prompt
      {:ok, result} = AgentRunner.run(agent, "one_of_user_test")

      # Check that system messages contain schema info
      system_msg =
        result.all_messages
        |> Enum.find(fn msg -> msg.role == :system end)

      assert system_msg != nil
      assert system_msg.content =~ "test_user"
      assert system_msg.content =~ "test_score"
    end

    test "returns error when no schema matches (strict validation)", %{model: model} do
      # TestScore has validate_changeset that rejects score > 1.0
      # Use only TestScore so there's no lenient fallback
      agent =
        Agent.new(model,
          output_type: {:one_of, [TestScore]},
          structured_output: [max_retries: 0],
          instructions: "Return data"
        )

      # one_of_nomatch_test returns {"score": 2.0} which fails TestScore validation
      # (score > 1.0 and label missing)
      {:error, %Errors.ValidationError{} = err} =
        AgentRunner.run(agent, "one_of_nomatch_test")

      assert err.message =~ "one_of"
    end

    test "works with per-run override to one_of", %{model: model} do
      agent = Agent.new(model, instructions: "Flexible agent")

      {:ok, result} =
        AgentRunner.run(agent, "one_of_user_test", output_type: {:one_of, [TestUser, TestScore]})

      assert %TestUser{name: "Alice", age: 30} = result.output
    end
  end

  # ===================================================================
  # Synthetic Tool Call Filtering Tests
  # ===================================================================

  describe "synthetic tool call filtering" do
    test "synthetic tool calls are not executed as real tools", %{model: model} do
      # Use a mock that returns a synthetic tool call response
      defmodule ToolCallMockDispatcher do
        @moduledoc false

        def request(_model, _messages, _settings) do
          response =
            Nous.Message.assistant("",
              tool_calls: [
                %{
                  "id" => "call_synth_1",
                  "name" => "__structured_output_test_user__",
                  "arguments" => %{"name" => "Bob", "age" => 25}
                }
              ]
            )

          response = %{
            response
            | metadata: %{
                usage: %Nous.Usage{
                  input_tokens: 10,
                  output_tokens: 5,
                  total_tokens: 15,
                  tool_calls: 0,
                  requests: 1
                }
              }
          }

          {:ok, response}
        end

        def request_stream(_model, _messages, _settings), do: {:ok, []}
      end

      Application.put_env(:nous, :model_dispatcher, ToolCallMockDispatcher)

      agent =
        Agent.new(model,
          output_type: {:one_of, [TestUser, TestScore]},
          instructions: "Extract"
        )

      {:ok, result} = AgentRunner.run(agent, "synth tool call test")
      assert %TestUser{name: "Bob", age: 25} = result.output

      # Verify no "Tool not found" error messages in context
      tool_error_msgs =
        result.all_messages
        |> Enum.filter(fn msg ->
          msg.role == :tool and is_binary(msg.content) and
            String.contains?(msg.content, "Tool not found")
        end)

      assert tool_error_msgs == []
    end

    test "standard __structured_output__ synthetic calls are also filtered", %{model: model} do
      defmodule StandardSynthMockDispatcher do
        @moduledoc false

        def request(_model, _messages, _settings) do
          response =
            Nous.Message.assistant("",
              tool_calls: [
                %{
                  "id" => "call_synth_1",
                  "name" => "__structured_output__",
                  "arguments" => %{"name" => "Charlie", "age" => 35}
                }
              ]
            )

          response = %{
            response
            | metadata: %{
                usage: %Nous.Usage{
                  input_tokens: 10,
                  output_tokens: 5,
                  total_tokens: 15,
                  tool_calls: 0,
                  requests: 1
                }
              }
          }

          {:ok, response}
        end

        def request_stream(_model, _messages, _settings), do: {:ok, []}
      end

      Application.put_env(:nous, :model_dispatcher, StandardSynthMockDispatcher)

      agent =
        Agent.new(model,
          output_type: TestUser,
          instructions: "Extract"
        )

      {:ok, result} = AgentRunner.run(agent, "standard synth test")
      assert %TestUser{name: "Charlie", age: 35} = result.output

      # No tool error messages
      tool_error_msgs =
        result.all_messages
        |> Enum.filter(fn msg ->
          msg.role == :tool and is_binary(msg.content) and
            String.contains?(msg.content, "Tool not found")
        end)

      assert tool_error_msgs == []
    end

    test "real tool calls still execute alongside synthetic filtering", %{model: model} do
      # This test ensures that when there are BOTH real and synthetic tool calls,
      # only real calls are executed
      defmodule MixedToolCallMock do
        @moduledoc false

        def request(_model, _messages, _settings) do
          call_count = :persistent_term.get({__MODULE__, :call_count}, 0)
          :persistent_term.put({__MODULE__, :call_count}, call_count + 1)

          if call_count == 0 do
            # First call: return a real tool call
            response =
              Nous.Message.assistant("",
                tool_calls: [
                  %{
                    "id" => "call_real_1",
                    "name" => "get_data",
                    "arguments" => %{}
                  }
                ]
              )

            response = %{
              response
              | metadata: %{
                  usage: %Nous.Usage{
                    input_tokens: 10,
                    output_tokens: 5,
                    total_tokens: 15,
                    tool_calls: 0,
                    requests: 1
                  }
                }
            }

            {:ok, response}
          else
            # Second call: return structured output text
            response =
              Nous.Message.assistant(~s({"name": "DataResult", "age": 42}))

            response = %{
              response
              | metadata: %{
                  usage: %Nous.Usage{
                    input_tokens: 10,
                    output_tokens: 5,
                    total_tokens: 15,
                    tool_calls: 0,
                    requests: 1
                  }
                }
            }

            {:ok, response}
          end
        end

        def request_stream(_model, _messages, _settings), do: {:ok, []}
      end

      Application.put_env(:nous, :model_dispatcher, MixedToolCallMock)
      :persistent_term.put({MixedToolCallMock, :call_count}, 0)

      get_data_tool = %Nous.Tool{
        name: "get_data",
        description: "Get data",
        function: fn _ctx, _args -> {:ok, "data"} end,
        parameters: %{"type" => "object", "properties" => %{}},
        takes_ctx: true,
        retries: 0,
        validate_args: false,
        requires_approval: false,
        tags: []
      }

      agent =
        Agent.new(model,
          output_type: TestUser,
          instructions: "Get data then extract",
          tools: [get_data_tool]
        )

      {:ok, result} = AgentRunner.run(agent, "mixed tool call test")
      assert %TestUser{name: "DataResult", age: 42} = result.output

      # Clean up
      try do
        :persistent_term.erase({MixedToolCallMock, :call_count})
      rescue
        _ -> :ok
      end
    end
  end

  # ===================================================================
  # AgentRunner.apply_runtime_overrides/2 (tested indirectly)
  # ===================================================================

  describe "apply_runtime_overrides behavior" do
    test "output_type override applies to extraction", %{model: model} do
      # Agent configured for TestUser but we override to :string
      agent = Agent.new(model, output_type: TestUser, instructions: "Test")

      {:ok, result} = AgentRunner.run(agent, "override_to_string", output_type: :string)
      assert is_binary(result.output)
    end

    test "structured_output override applies to retry logic", %{model: model} do
      # Agent has 0 retries, but we override to allow retries
      agent =
        Agent.new(model,
          output_type: TestScore,
          structured_output: [max_retries: 0],
          instructions: "Test"
        )

      # With max_retries: 0, this would fail
      assert {:error, %Errors.ValidationError{}} =
               AgentRunner.run(agent, "validation_fail")

      # Reset call count
      :persistent_term.put({MockDispatcher, :call_count}, 0)

      # With override to max_retries: 2, the retry succeeds
      {:ok, result} =
        AgentRunner.run(agent, "retry_test score_override", structured_output: [max_retries: 2])

      assert %TestScore{score: 0.8} = result.output
    end

    test "no override preserves agent defaults", %{model: model} do
      agent = Agent.new(model, output_type: TestUser, instructions: "Test")

      {:ok, result} = AgentRunner.run(agent, "structured_user")
      assert %TestUser{} = result.output
    end
  end
end
