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

  ## Cost

  `cost/2` prices a usage struct against `Nous.Usage.Pricing`. Cost is
  deliberately **not** a struct field: it is derived from a price table that
  changes independently of the run (vendors reprice, operators override rates),
  so a number computed once and persisted inside `%Usage{}` would silently
  become wrong while looking authoritative. Counters are facts about the run;
  money is a function of those facts and a rate card. Compute it on demand.

  """

  alias Nous.Model
  alias Nous.Usage.Pricing
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

  @typedoc """
  A cost breakdown in USD. `:total` is the sum of the four component costs.
  """
  @type cost :: %{
          input: float(),
          output: float(),
          cache_read: float(),
          cache_write: float(),
          total: float()
        }

  # Providers that report cache tokens *outside* of `input_tokens`, so the
  # counters are disjoint and can each be billed at their own rate. Every other
  # provider folds cache reads into the reported input count, so we subtract
  # them before billing. See `cost/2` for the evidence.
  @disjoint_cache_providers [:anthropic]

  # `Nous.Model.parse/2` refuses to build a model for the bring-your-own-endpoint
  # providers without a `:base_url`. Pricing never issues a request — it only
  # needs the provider atom — so hand it a placeholder.
  @pricing_base_url "http://pricing.invalid"

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

  @doc """
  Price a usage struct against `Nous.Usage.Pricing`, in USD.

  Accepts a `%Nous.Model{}` or a `"provider:model"` string (parsed with
  `Nous.Model.parse/2`). Returns `{:error, :unknown_model}` — never a guess,
  never a raise — when the model has no price entry, or when the string is not
  a valid `"provider:model"` spec.

  ## What gets billed at which rate

  Providers do not agree on whether the input count they report already
  includes cached tokens, and this matters: naively adding `input_tokens` and
  `cache_read_input_tokens` double-counts every cached token on most providers.
  What the code in this repo actually produces:

    * **Anthropic** (`Nous.Messages.Anthropic.parse_usage/1`,
      `lib/nous/messages/anthropic.ex:281-292`) copies Anthropic's
      `input_tokens`, `cache_creation_input_tokens` and
      `cache_read_input_tokens` through unchanged. Anthropic reports those
      three as **disjoint** counts — its docs define `input_tokens` as the
      tokens "not read from or used to create a cache" and give
      `total = cache_read + cache_creation + input_tokens` — so each counter is
      billed at its own rate and nothing is subtracted.
    * **Gemini / Vertex AI** (`Nous.Messages.Gemini.parse_usage/1`,
      `lib/nous/messages/gemini.ex:606-612`) maps `input_tokens` from
      `promptTokenCount` and `cache_read_input_tokens` from
      `cachedContentTokenCount`. Google documents `promptTokenCount` as "the
      total effective prompt size meaning this includes the number of tokens in
      the cached content", so cached tokens are subtracted from the input count
      before the input rate is applied.
    * **OpenAI and OpenAI-compatible providers**
      (`Nous.Messages.OpenAI.parse_usage/1`,
      `lib/nous/messages/openai.ex:265-269`, and `from_openai/1` above) map
      `input_tokens` from `prompt_tokens` and never populate either cache
      counter, so cached reads are invisible here and are billed at the full
      input rate. `prompt_tokens` likewise includes
      `prompt_tokens_details.cached_tokens`, so if you populate
      `cache_read_input_tokens` yourself, the same subtraction applies and
      stays correct.

  In short: cache reads are subtracted from `input_tokens` for every provider
  except Anthropic, which is the only one that reports them separately.
  Anthropic cache *writes* are also reported outside `input_tokens`, and no
  other provider populates `cache_creation_input_tokens`, so cache-write
  tokens are always billed on top.

  ## Examples

      iex> {:ok, cost} = Usage.cost(%Usage{input_tokens: 1_000}, "ollama:llama3.3")
      iex> cost.total
      0.0

      iex> Usage.cost(%Usage{}, "openai:no-such-model-exists")
      {:error, :unknown_model}

  """
  @spec cost(t(), Model.t() | String.t()) :: {:ok, cost()} | {:error, :unknown_model}
  def cost(usage, model)

  def cost(%Usage{} = usage, %Model{provider: provider, model: model_name}) do
    case Pricing.lookup(provider, model_name) do
      :unknown -> {:error, :unknown_model}
      price -> {:ok, breakdown(usage, provider, price)}
    end
  end

  def cost(%Usage{} = usage, model_string) when is_binary(model_string) do
    case parse_model(model_string) do
      {:ok, model} -> cost(usage, model)
      :error -> {:error, :unknown_model}
    end
  end

  defp breakdown(%Usage{} = usage, provider, price) do
    input_cost = per_million(billable_input_tokens(usage, provider), price.input)
    output_cost = per_million(usage.output_tokens, price.output)
    cache_read_cost = per_million(usage.cache_read_input_tokens, price.cache_read)
    cache_write_cost = per_million(usage.cache_creation_input_tokens, price.cache_write)

    %{
      input: input_cost,
      output: output_cost,
      cache_read: cache_read_cost,
      cache_write: cache_write_cost,
      total: input_cost + output_cost + cache_read_cost + cache_write_cost
    }
  end

  defp billable_input_tokens(%Usage{} = usage, provider)
       when provider in @disjoint_cache_providers,
       do: usage.input_tokens

  defp billable_input_tokens(%Usage{} = usage, _provider) do
    max(usage.input_tokens - usage.cache_read_input_tokens, 0)
  end

  defp per_million(tokens, rate_per_million), do: tokens * rate_per_million / 1_000_000

  defp parse_model(model_string) do
    {:ok, Model.parse(model_string, base_url: @pricing_base_url)}
  rescue
    ArgumentError -> :error
  end
end
