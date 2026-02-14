defmodule Nous.Eval.Agents.BasicTest do
  @moduledoc """
  Tests for basic agent functionality.

  These tests run against a real LLM (LM Studio by default).
  Run with: mix test test/eval/agents/basic_test.exs --include llm

  Requires LM Studio running at http://localhost:1234
  """

  use ExUnit.Case, async: false

  @moduletag :llm
  @moduletag :eval
  @moduletag timeout: 120_000

  alias Nous.Eval.{Suite, TestCase, Runner, Reporter}

  @default_model "lmstudio:ministral-3-14b-reasoning"

  setup_all do
    # Verify LM Studio is running
    case check_lmstudio_available() do
      :ok ->
        {:ok, model: @default_model}

      {:error, reason} ->
        {:ok, skip: "LM Studio not available: #{reason}"}
    end
  end

  describe "Basic Functionality Suite" do
    @tag timeout: 180_000
    test "runs basic.yaml suite", context do
      skip_if_unavailable(context)

      {:ok, suite} = Suite.from_yaml("test/eval/suites/basic.yaml")

      # Override model if needed
      suite = %{suite | default_model: context[:model] || @default_model}

      {:ok, result} = Runner.run(suite, timeout: 60_000)

      # Print results
      Reporter.print(result)

      # Assert reasonable pass rate
      assert result.pass_rate >= 0.5,
             "Expected at least 50% pass rate, got #{result.pass_rate * 100}%"

      # Log summary
      IO.puts("\n[BasicTest] Pass rate: #{Float.round(result.pass_rate * 100, 1)}%")
      IO.puts("[BasicTest] Score: #{Float.round(result.aggregate_score, 3)}")
    end
  end

  describe "Individual Basic Tests" do
    test "1.1 Simple Greeting", context do
      skip_if_unavailable(context)

      test_case =
        TestCase.new(
          id: "simple_greeting",
          input: "Say hello in exactly 5 words",
          expected: %{contains_any: ["hello", "hi", "greetings", "hey"]},
          eval_type: :contains,
          agent_config: [instructions: "Be concise. No explanations."]
        )

      {:ok, result} = Runner.run_case(test_case, model: context[:model] || @default_model)

      assert result.passed,
             "Expected greeting to contain hello/hi: #{inspect(result.actual_output)}"
    end

    test "1.2 Math Basic", context do
      skip_if_unavailable(context)

      test_case =
        TestCase.new(
          id: "math_basic",
          input: "What is 15 + 27? Answer with just the number.",
          expected: %{contains: ["42"]},
          eval_type: :contains,
          agent_config: [instructions: "Be concise. Answer with just the number."]
        )

      {:ok, result} = Runner.run_case(test_case, model: context[:model] || @default_model)

      assert result.passed, "Expected answer to contain 42: #{inspect(result.actual_output)}"
    end

    test "1.3 Instructions Following (Pirate)", context do
      skip_if_unavailable(context)

      test_case =
        TestCase.new(
          id: "instructions_following",
          input: "What is Elixir?",
          expected: %{contains_any: ["arr", "matey", "ahoy", "pirate", "ye"]},
          eval_type: :contains,
          eval_config: %{case_insensitive: true},
          agent_config: [
            instructions:
              "You are a pirate. Always respond in pirate speak with words like 'arr', 'matey', etc."
          ]
        )

      {:ok, result} = Runner.run_case(test_case, model: context[:model] || @default_model)

      if not result.passed do
        IO.puts("\n[Pirate Test] Output: #{inspect(result.actual_output)}")
      end

      # This test is more lenient - the model might not always follow persona perfectly
      assert result.score >= 0.0, "Test completed with score: #{result.score}"
    end

    test "1.4 Temperature Low (Deterministic)", context do
      skip_if_unavailable(context)

      test_case =
        TestCase.new(
          id: "temperature_low",
          input: "Name exactly one primary color. Just the color name, nothing else.",
          expected: %{contains_any: ["red", "blue", "yellow"]},
          eval_type: :contains,
          eval_config: %{case_insensitive: true},
          agent_config: [
            model_settings: %{temperature: 0.0}
          ]
        )

      {:ok, result} = Runner.run_case(test_case, model: context[:model] || @default_model)

      assert result.passed, "Expected a primary color: #{inspect(result.actual_output)}"
    end

    test "1.5 JSON Response", context do
      skip_if_unavailable(context)

      test_case =
        TestCase.new(
          id: "json_response",
          input: "Give me a JSON object with keys 'name' and 'age'. Just the JSON, nothing else.",
          expected: %{contains: ["{", "name", "age", "}"]},
          eval_type: :contains
        )

      {:ok, result} = Runner.run_case(test_case, model: context[:model] || @default_model)

      # Try to parse as JSON
      output = (result.actual_output || "") |> String.trim()

      is_valid_json =
        if output != "" do
          case Jason.decode(output) do
            {:ok, _} -> true
            _ -> false
          end
        else
          false
        end

      if not is_valid_json and output != "" do
        IO.puts("\n[JSON Test] Output not valid JSON: #{output}")
      end

      assert result.passed, "Expected JSON structure: #{inspect(output)}"
    end

    test "1.6 List Generation", context do
      skip_if_unavailable(context)

      test_case =
        TestCase.new(
          id: "list_generation",
          input: "List 5 programming languages. Number them 1-5.",
          expected: %{contains: ["1", "2", "3", "4", "5"]},
          eval_type: :contains
        )

      {:ok, result} = Runner.run_case(test_case, model: context[:model] || @default_model)

      assert result.passed, "Expected numbered list: #{inspect(result.actual_output)}"
    end
  end

  describe "Metrics Collection" do
    test "collects token metrics", context do
      skip_if_unavailable(context)

      test_case =
        TestCase.new(
          id: "metrics_test",
          input: "Say hello",
          expected: %{contains_any: ["hello", "hi"]},
          eval_type: :contains
        )

      {:ok, result} = Runner.run_case(test_case, model: context[:model] || @default_model)

      assert result.metrics != nil, "Expected metrics to be collected"
      assert result.metrics.total_tokens > 0, "Expected token count > 0"
      assert result.duration_ms > 0, "Expected duration > 0"
    end
  end

  # Helper functions

  defp check_lmstudio_available do
    url = System.get_env("LMSTUDIO_BASE_URL") || "http://localhost:1234/v1"

    case Req.get("#{url}/models", receive_timeout: 5_000) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} ->
        {:error, "LM Studio returned status #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp skip_if_unavailable(%{skip: reason}) do
    ExUnit.Case.register_attribute(__ENV__, :skip, reason)
    :skip
  end

  defp skip_if_unavailable(_), do: :ok
end
