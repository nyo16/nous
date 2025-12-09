#!/usr/bin/env elixir
# Generate test fixtures from LM Studio
# Run with: mix run test/support/generate_fixtures.exs

defmodule FixtureGenerator do
  alias Nous.{Agent, Tool}

  def generate_all do
    IO.puts("Generating test fixtures from LM Studio...\n")

    fixtures = %{
      simple_response: generate_simple_response(),
      tool_call_response: generate_tool_call_response(),
      multi_tool_response: generate_multi_tool_response(),
      conversation: generate_conversation(),
      error_handling: generate_error_handling()
    }

    # Save to file
    fixture_path = "test/fixtures/llm_responses.exs"
    File.mkdir_p!("test/fixtures")

    content = """
    # Generated LLM response fixtures
    # Generated at: #{DateTime.utc_now() |> DateTime.to_string()}
    # Model: lmstudio:qwen/qwen3-30b-a3b-2507

    defmodule NousTest.Fixtures.LLMResponses do
      @moduledoc \"\"\"
      Real LLM responses captured for testing.
      Regenerate with: mix run test/support/generate_fixtures.exs
      \"\"\"

    #{inspect(fixtures, pretty: true, limit: :infinity, width: 100)}
    end
    """

    File.write!(fixture_path, content)
    IO.puts("\n✅ Fixtures saved to #{fixture_path}")
    IO.puts("\nGenerated #{map_size(fixtures)} fixture categories")
  end

  def generate_simple_response do
    IO.puts("📝 Generating simple response...")

    agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
      instructions: "You are a helpful assistant. Be concise.",
      model_settings: %{temperature: 0.7, max_tokens: 100}
    )

    {:ok, result} = Agent.run(agent, "What is Elixir?", max_iterations: 1)

    %{
      prompt: "What is Elixir?",
      output: result.output,
      usage: result.usage,
      message_count: length(result.all_messages)
    }
  end

  def generate_tool_call_response do
    IO.puts("🔧 Generating tool call response...")

    # Define a search tool
    search_tool = Tool.from_function(
      fn _ctx, %{"query" => query} ->
        "Found 3 results for '#{query}': Result 1, Result 2, Result 3"
      end,
      name: "search",
      description: "Search for information"
    )

    agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
      instructions: "You have access to a search tool. Use it to answer questions.",
      tools: [search_tool],
      model_settings: %{temperature: 0.5, max_tokens: 200}
    )

    {:ok, result} = Agent.run(agent, "Search for Elixir programming language", max_iterations: 5)

    %{
      prompt: "Search for Elixir programming language",
      output: result.output,
      usage: result.usage,
      tool_calls: result.usage.tool_calls,
      message_count: length(result.all_messages)
    }
  end

  def generate_multi_tool_response do
    IO.puts("🔧🔧 Generating multi-tool response...")

    # Define multiple tools
    calculator = Tool.from_function(
      fn _ctx, %{"expression" => expr} ->
        # Simple eval for testing
        case expr do
          "2 + 2" -> "4"
          "10 * 5" -> "50"
          _ -> "Error: cannot evaluate #{expr}"
        end
      end,
      name: "calculator",
      description: "Calculate mathematical expressions"
    )

    get_time = Tool.from_function(
      fn _ctx, %{} ->
        "Current time: 2025-10-20 15:30:00 UTC"
      end,
      name: "get_time",
      description: "Get current time"
    )

    agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
      instructions: "You have calculator and time tools. Use them when needed.",
      tools: [calculator, get_time],
      model_settings: %{temperature: 0.5, max_tokens: 200}
    )

    {:ok, result} = Agent.run(agent, "What time is it and what is 2 + 2?", max_iterations: 5)

    %{
      prompt: "What time is it and what is 2 + 2?",
      output: result.output,
      usage: result.usage,
      tool_calls: result.usage.tool_calls,
      iterations: result.usage.requests,
      message_count: length(result.all_messages)
    }
  end

  def generate_conversation do
    IO.puts("💬 Generating conversation...")

    agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
      instructions: "You are a helpful assistant. Remember context from previous messages.",
      model_settings: %{temperature: 0.7, max_tokens: 100}
    )

    # First message
    {:ok, result1} = Agent.run(agent, "My name is Alice", max_iterations: 1)

    # Second message with history
    {:ok, result2} = Agent.run(agent, "What is my name?",
      message_history: result1.new_messages,
      max_iterations: 1
    )

    %{
      messages: [
        %{prompt: "My name is Alice", response: result1.output},
        %{prompt: "What is my name?", response: result2.output}
      ],
      total_tokens: result1.usage.total_tokens + result2.usage.total_tokens
    }
  end

  def generate_error_handling do
    IO.puts("⚠️ Generating error handling scenarios...")

    # Tool that can fail
    flaky_tool = Tool.from_function(
      fn _ctx, %{"should_fail" => should_fail} ->
        if should_fail do
          raise "Tool error: something went wrong"
        else
          "Success"
        end
      end,
      name: "flaky_tool",
      description: "A tool that might fail"
    )

    agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
      instructions: "You have a tool. Try using it.",
      tools: [flaky_tool],
      model_settings: %{temperature: 0.5, max_tokens: 100}
    )

    # This will likely result in a tool error
    result = Agent.run(agent, "Use the flaky tool with should_fail=false", max_iterations: 3)

    case result do
      {:ok, r} ->
        %{
          scenario: "tool_success",
          output: r.output,
          usage: r.usage
        }

      {:error, error} ->
        %{
          scenario: "tool_error",
          error_type: error.__struct__,
          error_message: Exception.message(error)
        }
    end
  end
end

# Run the generator
FixtureGenerator.generate_all()
