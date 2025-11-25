defmodule Yggdrasil.Usage do
  @moduledoc """
  Tracks resource usage for agent runs.

  Usage tracking helps monitor costs and performance across agent executions.
  You can aggregate usage from multiple agent runs to track total consumption.

  ## Example

      usage = Usage.new()
      usage = Usage.inc_requests(usage)
      usage = Usage.add_tokens(usage, input: 100, output: 50)
      IO.inspect(usage.total_tokens) # 150

  """

  @type t :: %__MODULE__{
          requests: non_neg_integer(),
          tool_calls: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @enforce_keys []
  defstruct requests: 0,
            tool_calls: 0,
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0

  @doc """
  Create a new empty usage tracker.

  ## Example

      usage = Usage.new()
      # %Usage{requests: 0, total_tokens: 0, ...}

  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Add two usage trackers together.

  Useful for aggregating usage across multiple agent runs.

  ## Example

      usage1 = %Usage{requests: 1, total_tokens: 100}
      usage2 = %Usage{requests: 2, total_tokens: 200}
      total = Usage.add(usage1, usage2)
      # %Usage{requests: 3, total_tokens: 300}

  """
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = u1, %__MODULE__{} = u2) do
    %__MODULE__{
      requests: u1.requests + u2.requests,
      tool_calls: u1.tool_calls + u2.tool_calls,
      input_tokens: u1.input_tokens + u2.input_tokens,
      output_tokens: u1.output_tokens + u2.output_tokens,
      total_tokens: u1.total_tokens + u2.total_tokens
    }
  end

  @doc """
  Increment request count by 1.

  ## Example

      usage = Usage.new() |> Usage.inc_requests()
      # %Usage{requests: 1, ...}

  """
  @spec inc_requests(t()) :: t()
  def inc_requests(%__MODULE__{} = usage) do
    %{usage | requests: usage.requests + 1}
  end

  @doc """
  Increment tool call count.

  ## Example

      usage = Usage.new() |> Usage.inc_tool_calls(3)
      # %Usage{tool_calls: 3, ...}

  """
  @spec inc_tool_calls(t(), non_neg_integer()) :: t()
  def inc_tool_calls(%__MODULE__{} = usage, count \\ 1) do
    %{usage | tool_calls: usage.tool_calls + count}
  end

  @doc """
  Add token counts from options.

  ## Options

    * `:input` - Number of input tokens (default: 0)
    * `:output` - Number of output tokens (default: 0)

  ## Example

      usage = Usage.new()
      usage = Usage.add_tokens(usage, input: 50, output: 30)
      # %Usage{input_tokens: 50, output_tokens: 30, total_tokens: 80}

  """
  @spec add_tokens(t(), keyword()) :: t()
  def add_tokens(%__MODULE__{} = usage, opts) do
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

  ## Example

      openai_usage = %{
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150
      }
      usage = Usage.from_openai(openai_usage)
      # %Usage{input_tokens: 100, output_tokens: 50, total_tokens: 150}

  """
  @spec from_openai(map()) :: t()
  def from_openai(openai_usage) when is_map(openai_usage) do
    %__MODULE__{
      requests: 1,
      input_tokens: Map.get(openai_usage, :prompt_tokens, 0),
      output_tokens: Map.get(openai_usage, :completion_tokens, 0),
      total_tokens: Map.get(openai_usage, :total_tokens, 0)
    }
  end
end
