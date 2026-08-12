defmodule Nous.Usage do
  @moduledoc """
  Tracks resource usage for agent runs.

  Usage tracking helps monitor costs and performance across agent executions.
  You can aggregate usage from multiple agent runs to track total consumption.

  ## Examples

      iex> usage = Usage.new()
      iex> usage = Usage.inc_requests(usage)
      iex> usage = Usage.add_tokens(usage, input: 100, output: 50)
      iex> {usage.requests, usage.total_tokens}
      {1, 150}

  Every counter is additive, so runs aggregate with `add/2`:

      iex> a = Usage.add_tokens(Usage.new(), input: 100, output: 50)
      iex> b = Usage.add_tokens(Usage.new(), input: 10, output: 5)
      iex> Usage.add(a, b).total_tokens
      165

  """

  alias __MODULE__

  @type t :: %Usage{
          requests: non_neg_integer(),
          tool_calls: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer()
        }

  @enforce_keys []
  defstruct requests: 0,
            tool_calls: 0,
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0

  @doc """
  Create a new empty usage tracker.

  ## Examples

      iex> Usage.new()
      %Usage{}

  """
  @spec new() :: t()
  def new, do: %Usage{}

  @doc """
  Add two usage trackers together.

  Useful for aggregating usage across multiple agent runs.

  ## Examples

      iex> usage1 = %Usage{requests: 1, total_tokens: 100}
      iex> usage2 = %Usage{requests: 2, total_tokens: 200}
      iex> total = Usage.add(usage1, usage2)
      iex> {total.requests, total.total_tokens}
      {3, 300}

  """
  @spec add(t(), t()) :: t()
  def add(%Usage{} = u1, %Usage{} = u2) do
    %Usage{
      requests: u1.requests + u2.requests,
      tool_calls: u1.tool_calls + u2.tool_calls,
      input_tokens: u1.input_tokens + u2.input_tokens,
      output_tokens: u1.output_tokens + u2.output_tokens,
      total_tokens: u1.total_tokens + u2.total_tokens,
      cache_creation_input_tokens:
        u1.cache_creation_input_tokens + u2.cache_creation_input_tokens,
      cache_read_input_tokens: u1.cache_read_input_tokens + u2.cache_read_input_tokens
    }
  end

  @doc """
  Increment request count by 1.

  ## Examples

      iex> usage = Usage.new() |> Usage.inc_requests()
      iex> usage.requests
      1

  """
  @spec inc_requests(t()) :: t()
  def inc_requests(%Usage{} = usage) do
    %{usage | requests: usage.requests + 1}
  end

  @doc """
  Increment tool call count.

  ## Examples

      iex> usage = Usage.new() |> Usage.inc_tool_calls(3)
      iex> usage.tool_calls
      3

      iex> usage = Usage.new() |> Usage.inc_tool_calls()
      iex> usage.tool_calls
      1

  """
  @spec inc_tool_calls(t(), non_neg_integer()) :: t()
  def inc_tool_calls(%Usage{} = usage, count \\ 1) do
    %{usage | tool_calls: usage.tool_calls + count}
  end

  @doc """
  Add token counts from options.

  ## Options

    * `:input` - Number of input tokens (default: 0)
    * `:output` - Number of output tokens (default: 0)

  ## Examples

      iex> usage = Usage.add_tokens(Usage.new(), input: 50, output: 30)
      iex> {usage.input_tokens, usage.output_tokens, usage.total_tokens}
      {50, 30, 80}

  Omitted counts default to zero, so partial updates are safe:

      iex> usage = Usage.add_tokens(Usage.new(), output: 12)
      iex> {usage.input_tokens, usage.total_tokens}
      {0, 12}

  """
  @spec add_tokens(t(), keyword()) :: t()
  def add_tokens(%Usage{} = usage, opts) do
    input = Keyword.get(opts, :input, 0)
    output = Keyword.get(opts, :output, 0)

    %{
      usage
      | input_tokens: usage.input_tokens + input,
        output_tokens: usage.output_tokens + output,
        total_tokens: usage.total_tokens + input + output
    }
  end

  @doc """
  Create usage from OpenAI API usage format.

  Converts the usage object from OpenAI responses to our format.

  ## Examples

  Keys are read as atoms. A JSON-decoded provider payload has string keys, so
  convert it before calling this, or build the map yourself:

      iex> usage = Usage.from_openai(%{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150})
      iex> {usage.requests, usage.input_tokens, usage.output_tokens, usage.total_tokens}
      {1, 100, 50, 150}

  Missing keys count as zero:

      iex> usage = Usage.from_openai(%{})
      iex> {usage.requests, usage.total_tokens}
      {1, 0}

  """
  @spec from_openai(map()) :: t()
  def from_openai(openai_usage) when is_map(openai_usage) do
    %Usage{
      requests: 1,
      input_tokens: Map.get(openai_usage, :prompt_tokens, 0),
      output_tokens: Map.get(openai_usage, :completion_tokens, 0),
      total_tokens: Map.get(openai_usage, :total_tokens, 0)
    }
  end
end
