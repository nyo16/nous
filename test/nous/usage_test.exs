defmodule Nous.UsageTest do
  use ExUnit.Case, async: true

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
end
