# Generated LLM response fixtures
# Generated at: 2025-10-20 23:35:00.396838Z
# Model: lmstudio:qwen/qwen3-30b-a3b-2507

defmodule NousTest.Fixtures.LLMResponses do
  @moduledoc """
  Real LLM responses captured for testing.
  Regenerate with: mix run test/support/generate_fixtures.exs
  """

%{
  error_handling: %{
    output: "The flaky tool was successfully used with `should_fail=false`. The operation completed successfully.",
    usage: %Nous.Usage{
      requests: 2,
      tool_calls: 1,
      input_tokens: 344,
      output_tokens: 40,
      total_tokens: 384
    },
    scenario: "tool_success"
  },
  simple_response: %{
    output: "Elixir is a dynamic, functional programming language designed for building scalable and maintainable applications. It runs on the Erlang Virtual Machine (BEAM), which provides fault tolerance, concurrency, and distributed computing capabilities. Elixir is often used for web development, real-time systems, and distributed applications, particularly in domains like telecommunications, financial services, and IoT. Its syntax is influenced by Ruby, making it approachable for developers familiar with that language.",
    usage: %Nous.Usage{
      requests: 1,
      tool_calls: 0,
      input_tokens: 27,
      output_tokens: 90,
      total_tokens: 117
    },
    prompt: "What is Elixir?",
    message_count: 3
  },
  tool_call_response: %{
    output: "Elixir is a dynamic, functional programming language designed for building scalable and maintainable applications. It runs on the Erlang Virtual Machine (BEAM), which provides features like fault tolerance, hot code swapping, and distributed computing. Elixir is commonly used for web development, real-time systems, and distributed applications. Its syntax is influenced by Ruby, making it easy to learn for developers familiar with that language.",
    usage: %Nous.Usage{
      requests: 2,
      tool_calls: 1,
      input_tokens: 362,
      output_tokens: 104,
      total_tokens: 466
    },
    prompt: "Search for Elixir programming language",
    message_count: 5,
    tool_calls: 1
  },
  multi_tool_response: %{
    output: "The current time is 2025-10-20 15:30:00 UTC.  \n2 + 2 = 4.",
    usage: %Nous.Usage{
      requests: 2,
      tool_calls: 2,
      input_tokens: 497,
      output_tokens: 67,
      total_tokens: 564
    },
    prompt: "What time is it and what is 2 + 2?",
    message_count: 6,
    tool_calls: 2,
    iterations: 2
  },
  conversation: %{
    messages: [
      %{
        response: "Hi Alice! It's nice to meet you. How can I help you today?",
        prompt: "My name is Alice"
      },
      %{response: "", prompt: "What is my name?"}
    ],
    total_tokens: 95
  }
}
end
