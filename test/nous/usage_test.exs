defmodule Nous.UsageTest do
  use ExUnit.Case, async: true

  alias Nous.Model
  alias Nous.Usage

  doctest Usage

  describe "new/0" do
    test "creates empty usage tracker" do
      usage = Usage.new()

      assert usage.requests == 0
      assert usage.tool_calls == 0
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.total_tokens == 0
    end
  end

  describe "add/2" do
    test "adds two usage trackers together" do
      u1 = %Usage{requests: 1, input_tokens: 100, output_tokens: 50, total_tokens: 150}
      u2 = %Usage{requests: 2, input_tokens: 200, output_tokens: 100, total_tokens: 300}

      result = Usage.add(u1, u2)

      assert result.requests == 3
      assert result.input_tokens == 300
      assert result.output_tokens == 150
      assert result.total_tokens == 450
    end

    test "handles empty usage" do
      u1 = Usage.new()
      u2 = %Usage{requests: 1, total_tokens: 100}

      result = Usage.add(u1, u2)

      assert result.requests == 1
      assert result.total_tokens == 100
    end
  end

  describe "inc_requests/1" do
    test "increments request count" do
      usage = Usage.new()

      result = Usage.inc_requests(usage)

      assert result.requests == 1
    end

    test "increments multiple times" do
      usage =
        Usage.new()
        |> Usage.inc_requests()
        |> Usage.inc_requests()
        |> Usage.inc_requests()

      assert usage.requests == 3
    end
  end

  describe "inc_tool_calls/2" do
    test "increments tool call count by default 1" do
      usage = Usage.new()

      result = Usage.inc_tool_calls(usage)

      assert result.tool_calls == 1
    end

    test "increments by specified count" do
      usage = Usage.new()

      result = Usage.inc_tool_calls(usage, 5)

      assert result.tool_calls == 5
    end
  end

  describe "add_tokens/2" do
    test "adds input and output tokens" do
      usage = Usage.new()

      result = Usage.add_tokens(usage, input: 50, output: 30)

      assert result.input_tokens == 50
      assert result.output_tokens == 30
      assert result.total_tokens == 80
    end

    test "accumulates tokens across multiple calls" do
      usage =
        Usage.new()
        |> Usage.add_tokens(input: 50, output: 30)
        |> Usage.add_tokens(input: 25, output: 15)

      assert usage.input_tokens == 75
      assert usage.output_tokens == 45
      assert usage.total_tokens == 120
    end

    test "handles missing options with defaults" do
      usage = Usage.new()

      result = Usage.add_tokens(usage, input: 100)

      assert result.input_tokens == 100
      assert result.output_tokens == 0
      assert result.total_tokens == 100
    end
  end

  describe "from_openai/1" do
    test "converts OpenAI usage format" do
      openai_usage = %{
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150
      }

      usage = Usage.from_openai(openai_usage)

      assert usage.requests == 1
      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
      assert usage.total_tokens == 150
    end

    test "handles missing fields with defaults" do
      openai_usage = %{
        prompt_tokens: 100
      }

      usage = Usage.from_openai(openai_usage)

      assert usage.input_tokens == 100
      assert usage.output_tokens == 0
      assert usage.total_tokens == 0
    end
  end

  describe "cost/2" do
    # Rates below come from the Nous.Usage.Pricing snapshot table (recorded
    # 2026-08-14). If that table is refreshed, these expectations move with it.
    test "prices all four token kinds for a provider that reports them disjointly" do
      usage = %Usage{
        input_tokens: 10_000,
        output_tokens: 2_000,
        cache_read_input_tokens: 50_000,
        cache_creation_input_tokens: 8_000
      }

      # claude-sonnet-4-5: $3.00 input, $15.00 output, $0.30 cache read,
      # $3.75 cache write, all per 1M tokens.
      assert {:ok, cost} = Usage.cost(usage, "anthropic:claude-sonnet-4-5")

      assert_in_delta cost.input, 0.03, 1.0e-9
      assert_in_delta cost.output, 0.03, 1.0e-9
      assert_in_delta cost.cache_read, 0.015, 1.0e-9
      assert_in_delta cost.cache_write, 0.03, 1.0e-9
      assert_in_delta cost.total, 0.105, 1.0e-9
    end

    test "does not double-count cached tokens when the provider folds them into input" do
      # Gemini's promptTokenCount includes cachedContentTokenCount, so only
      # 6_000 of the 10_000 input tokens are billed at the input rate.
      usage = %Usage{
        input_tokens: 10_000,
        output_tokens: 1_000,
        cache_read_input_tokens: 4_000
      }

      # gemini-2.5-flash: $0.30 input, $2.50 output, $0.03 cache read.
      assert {:ok, cost} = Usage.cost(usage, "gemini:gemini-2.5-flash")

      assert_in_delta cost.input, 0.0018, 1.0e-9
      assert_in_delta cost.output, 0.0025, 1.0e-9
      assert_in_delta cost.cache_read, 0.000_12, 1.0e-9
      assert_in_delta cost.total, 0.004_42, 1.0e-9
    end

    test "bills the full input count for Anthropic, which reports cache reads separately" do
      usage = %Usage{input_tokens: 10_000, cache_read_input_tokens: 4_000}

      assert {:ok, cost} = Usage.cost(usage, "anthropic:claude-sonnet-4-5")

      # 10_000 * $3.00 / 1M, not 6_000 * $3.00 / 1M.
      assert_in_delta cost.input, 0.03, 1.0e-9
    end

    test "a zeroed usage costs exactly zero for a known model" do
      assert {:ok, cost} = Usage.cost(Usage.new(), "openai:gpt-4o")

      assert cost.input === 0.0
      assert cost.output === 0.0
      assert cost.cache_read === 0.0
      assert cost.cache_write === 0.0
      assert cost.total === 0.0
    end

    test "a local provider is free" do
      usage = %Usage{input_tokens: 500_000, output_tokens: 100_000}

      assert {:ok, cost} = Usage.cost(usage, "ollama:llama3.3:70b")
      assert cost.total === 0.0
    end

    test "accepts a %Model{} and a \"provider:model\" string interchangeably" do
      usage = %Usage{input_tokens: 1_234, output_tokens: 567}

      assert Usage.cost(usage, Model.new(:openai, "gpt-4o")) ==
               Usage.cost(usage, "openai:gpt-4o")

      assert {:ok, %{total: total}} = Usage.cost(usage, "openai:gpt-4o")
      assert total > 0.0
    end

    test "returns an error instead of raising for an unpriced model" do
      usage = %Usage{input_tokens: 10, output_tokens: 10}

      assert Usage.cost(usage, "openai:model-nobody-has-heard-of") ==
               {:error, :unknown_model}

      assert Usage.cost(usage, Model.new(:groq, "llama-3.3-70b-versatile")) ==
               {:error, :unknown_model}
    end

    test "returns an error instead of raising for a malformed model string" do
      assert Usage.cost(Usage.new(), "not-a-provider-spec") == {:error, :unknown_model}
      assert Usage.cost(Usage.new(), "nosuchprovider:some-model") == {:error, :unknown_model}
    end
  end
end
