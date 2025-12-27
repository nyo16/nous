defmodule Nous.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Nous.{Agent, AgentRunner, Message, Tool, Usage}
  alias Nous.Errors

  import ExUnit.CaptureLog

  # Test helper modules
  defmodule MockModelDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      # Find the user prompt content to determine test behavior
      user_content = messages
        |> Enum.find_value(fn
          %Message{role: :user, content: content} -> content
          _ -> nil
        end)

      # Check if there are tool results in messages (indicates subsequent iteration)
      has_tool_results = Enum.any?(messages, fn
        %Message{role: :tool} -> true
        _ -> false
      end)

      case {user_content, has_tool_results} do
        {"error_test", _} ->
          {:error, %Errors.ModelError{message: "Test model error", provider: :test}}

        {"tool_call_test", false} ->
          # First call - return tool call
          legacy_response = %{
            parts: [
              {:tool_call, %{
                id: "call_123",
                name: "test_tool",
                arguments: %{"input" => "test"}
              }}
            ],
            usage: %Usage{
              input_tokens: 10,
              output_tokens: 5,
              total_tokens: 15,
              tool_calls: 0,  # AgentRunner tracks tool calls separately
              requests: 1
            },
            model_name: "test-model",
            timestamp: DateTime.utc_now()
          }
          response = Message.from_legacy(legacy_response)
          {:ok, response}

        {"tool_call_test", true} ->
          # After tool execution - return final response mentioning tool result
          legacy_response = %{
            parts: [{:text, "Tool received: test and processed successfully"}],
            usage: %Usage{
              input_tokens: 10,
              output_tokens: 5,
              total_tokens: 15,
              tool_calls: 0,  # No tool calls in this response
              requests: 1
            },
            model_name: "test-model",
            timestamp: DateTime.utc_now()
          }
          response = Message.from_legacy(legacy_response)
          {:ok, response}

        _ ->
          legacy_response = %{
            parts: [{:text, "This is a test response"}],
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
    end

    def request_stream(_model, _messages, _settings) do
      # Return a simple stream
      stream = [
        {:text_delta, "This "},
        {:text_delta, "is "},
        {:text_delta, "streaming"},
        {:finish, "stop"}
      ]
      {:ok, stream}
    end

    def count_tokens(_messages) do
      50
    end
  end

  defmodule TestTool do
    @moduledoc false

    def test_function(_ctx, %{"input" => input}) do
      %{
        success: true,
        result: "Tool received: #{input}",
        processed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    end

    def failing_tool(_ctx, _args) do
      raise "Tool execution failed"
    end
  end

  setup do
    # Mock the model dispatcher for tests
    Application.put_env(:nous, :model_dispatcher, MockModelDispatcher)

    on_exit(fn ->
      Application.delete_env(:nous, :model_dispatcher)
    end)

    test_tool = Tool.from_function(&TestTool.test_function/2,
      name: "test_tool",
      description: "A test tool"
    )

    failing_tool = Tool.from_function(&TestTool.failing_tool/2,
      name: "failing_tool",
      description: "A tool that fails"
    )

    # Use a simple model string for testing
    model_string = "openai:test-model"

    %{
      model: model_string,
      test_tool: test_tool,
      failing_tool: failing_tool
    }
  end

  describe "run/3" do
    test "executes simple agent with text response", %{model: model} do
      agent = Agent.new(model, instructions: "Be helpful")

      # Temporarily override ModelDispatcher
      with_mock_dispatcher(fn ->
        assert {:ok, result} = AgentRunner.run(agent, "Hello")

        assert result.output == "This is a test response"
        assert result.iterations == 1
        assert result.usage.total_tokens == 15
        assert result.usage.requests == 1
        assert result.usage.tool_calls == 0
      end)
    end

    test "handles model errors gracefully", %{model: model} do
      agent = Agent.new(model, instructions: "Be helpful")

      with_mock_dispatcher(fn ->
        logs = capture_log(fn ->
          assert {:error, error} = AgentRunner.run(agent, "error_test")
          assert %Errors.ModelError{} = error
          assert error.message == "Test model error"
        end)

        assert logs =~ "Model request failed"
      end)
    end

    test "executes tool calls correctly", %{model: model, test_tool: test_tool} do
      agent = Agent.new(model,
        instructions: "Use tools when needed",
        tools: [test_tool]
      )

      with_mock_dispatcher(fn ->
        assert {:ok, result} = AgentRunner.run(agent, "tool_call_test")

        # Should have both the tool call and final response
        assert result.output =~ "Tool received: test"
        assert result.usage.tool_calls == 1
        assert result.iterations >= 2  # Tool call + response
      end)
    end

    test "handles tool execution failures", %{model: model, failing_tool: failing_tool} do
      agent = Agent.new(model,
        instructions: "Use tools when needed",
        tools: [failing_tool]
      )

      # Create a custom mock that returns a tool call for the failing tool
      mock_dispatcher = fn
        (_model, messages, _settings) ->
          user_content = Enum.find_value(messages, fn
            %Message{role: :user, content: content} -> content
            _ -> nil
          end)

          # Check if there are tool results in messages (indicates subsequent iteration after tool failure)
          has_tool_results = Enum.any?(messages, fn
            %Message{role: :tool} -> true
            _ -> false
          end)

          case {user_content, has_tool_results} do
            {"use_failing_tool", false} ->
              # First call - return tool call that will fail
              legacy_response = %{
                parts: [
                  {:tool_call, %{
                    id: "call_fail",
                    name: "failing_tool",
                    arguments: %{}
                  }}
                ],
                usage: %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, tool_calls: 0, requests: 1},
                model_name: "test-model",
                timestamp: DateTime.utc_now()
              }
              response = Message.from_legacy(legacy_response)
              {:ok, response}

            {"use_failing_tool", true} ->
              # After tool failure - return final response
              legacy_response = %{
                parts: [{:text, "Final response after tool failure"}],
                usage: %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, tool_calls: 0, requests: 1},
                model_name: "test-model",
                timestamp: DateTime.utc_now()
              }
              response = Message.from_legacy(legacy_response)
              {:ok, response}

            _ ->
              legacy_response = %{
                parts: [{:text, "This is a test response"}],
                usage: %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, tool_calls: 0, requests: 1},
                model_name: "test-model",
                timestamp: DateTime.utc_now()
              }
              response = Message.from_legacy(legacy_response)
              {:ok, response}
          end
      end

      with_mock_dispatcher(mock_dispatcher, fn ->
        logs = capture_log(fn ->
          assert {:ok, result} = AgentRunner.run(agent, "use_failing_tool")

          # Tool should fail but agent should continue
          assert result.output == "Final response after tool failure"
        end)

        assert logs =~ "Tool 'failing_tool' execution failed"
        assert logs =~ "Tool 'failing_tool' failed after all"
      end)
    end

    test "respects max_iterations limit", %{model: model, test_tool: test_tool} do
      agent = Agent.new(model,
        instructions: "Keep using tools",
        tools: [test_tool]
      )

      # Mock that always returns tool calls to trigger max iterations
      mock_dispatcher = fn(_model, _messages, _settings) ->
        legacy_response = %{
          parts: [
            {:tool_call, %{
              id: "call_#{:rand.uniform(1000)}",
              name: "test_tool",
              arguments: %{"input" => "endless"}
            }}
          ],
          usage: %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, tool_calls: 1, requests: 1},
          model_name: "test-model",
          timestamp: DateTime.utc_now()
        }
        response = Message.from_legacy(legacy_response)
        {:ok, response}
      end

      with_mock_dispatcher(mock_dispatcher, fn ->
        assert {:error, error} = AgentRunner.run(agent, "Keep going", max_iterations: 2)
        assert %Errors.MaxIterationsExceeded{} = error
        assert error.max_iterations == 2
      end)
    end

    test "handles empty tool list when tool calls are made", %{model: model} do
      agent = Agent.new(model,
        instructions: "Be helpful",
        tools: []  # No tools available
      )

      with_mock_dispatcher(fn ->
        logs = capture_log(fn ->
          assert {:ok, result} = AgentRunner.run(agent, "tool_call_test")

          # Should get final response after tool call fails due to missing tool
          assert result.output == "Tool received: test and processed successfully"
        end)

        assert logs =~ "Tool not found: test_tool"
      end)
    end
  end

  describe "run_stream/3" do
    test "returns streaming response", %{model: model} do
      agent = Agent.new(model, instructions: "Be helpful")

      with_mock_dispatcher(fn ->
        assert {:ok, stream} = AgentRunner.run_stream(agent, "Hello")

        events = Enum.to_list(stream)

        assert {:text_delta, "This "} in events
        assert {:text_delta, "is "} in events
        assert {:text_delta, "streaming"} in events
        assert {:finish, "stop"} in events
      end)
    end

    test "handles model errors in streaming", %{model: model} do
      # For this test, let's just test the error path directly

      # Override request_stream to return error
      defmodule FailingMockDispatcher do
        def request_stream(_model, _messages, _settings) do
          {:error, "Stream initialization failed"}
        end

        def request(_model, _messages, _settings), do: {:error, "Not used"}
        def count_tokens(_messages), do: 50
      end

      Application.put_env(:nous, :model_dispatcher, FailingMockDispatcher)

      agent = Agent.new(model, instructions: "Be helpful")

      # Since we're testing the real AgentRunner.run_stream, we need to use the actual module structure
      # Let's test that the function exists and handles errors appropriately
      assert {:error, _error} = AgentRunner.run_stream(agent, "Hello")

      Application.put_env(:nous, :model_dispatcher, MockModelDispatcher)
    end
  end

  defmodule CustomMockDispatcher do
    @moduledoc false

    def request(model, messages, settings) do
      mock_fn = :persistent_term.get({Nous.AgentRunnerTest, :mock_fn})
      mock_fn.(model, messages, settings)
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  # Helper function to temporarily replace the model dispatcher
  defp with_mock_dispatcher(test_fn) when is_function(test_fn, 0) do
    test_fn.()
  end

  defp with_mock_dispatcher(mock_fn, test_fn) when is_function(mock_fn) and is_function(test_fn, 0) do
    original_dispatcher = Application.get_env(:nous, :model_dispatcher, MockModelDispatcher)

    # Store the mock function temporarily
    :persistent_term.put({__MODULE__, :mock_fn}, mock_fn)
    Application.put_env(:nous, :model_dispatcher, __MODULE__.CustomMockDispatcher)

    try do
      test_fn.()
    after
      Application.put_env(:nous, :model_dispatcher, original_dispatcher)
      :persistent_term.erase({__MODULE__, :mock_fn})
    end
  end
end