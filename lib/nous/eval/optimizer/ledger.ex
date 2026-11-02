defmodule Nous.Eval.Optimizer.Ledger do
  @moduledoc false
  # The spending ledger of one optimization (`Nous.Eval.Optimizer.run/2`'s
  # `:budget`): tokens, USD and metric calls (samples started), summed over
  # every evaluation and reflector call.
  #
  # Each evaluation and reflector call gets what is left as its own
  # `Nous.Eval.run/2` / `Nous.Eval.Budget` limits, so a call stops at the
  # optimization's limit rather than overshooting it by a whole batch; what
  # it spent is charged back here whatever its outcome.
  #
  # A `reserve` (the measured cost of the seed's test evaluation) is held
  # back from the search: the search phase sees `limit - reserve`, so the
  # acceptance evaluation of the best candidate can always run.
  #
  # Counters are `:atomics` so the strategy's context can charge without
  # threading the ledger through every return value. Cost is kept in
  # pico-dollars. A spend with no known price under a cost limit exhausts
  # the ledger: an unmeasured spend cannot be bounded.

  @pico 1_000_000_000_000

  @tokens 1
  @cost 2
  @calls 3
  @unpriced 4
  @reserve_tokens 5
  @reserve_cost 6
  @reserve_calls 7

  @type limits :: %{
          max_tokens: pos_integer() | nil,
          max_cost: number() | nil,
          max_metric_calls: pos_integer() | nil
        }

  @enforce_keys [:limits, :counters]
  defstruct [:limits, :counters]

  @type t :: %__MODULE__{limits: limits(), counters: :atomics.atomics_ref()}

  @spec limits(term()) :: {:ok, limits()} | {:error, term()}
  def limits(opts) when is_list(opts) do
    case Keyword.validate(opts, max_tokens: nil, max_cost: nil, max_metric_calls: nil) do
      {:ok, opts} ->
        limits = Map.new(opts)

        cond do
          Enum.all?(limits, fn {_key, value} -> is_nil(value) end) ->
            {:error, {:invalid_option, :budget, :no_limit}}

          not valid?(limits) ->
            {:error, {:invalid_option, :budget, opts}}

          true ->
            {:ok, limits}
        end

      {:error, unknown} ->
        {:error, {:invalid_option, :budget, unknown}}
    end
  end

  def limits(other), do: {:error, {:invalid_option, :budget, other}}

  defp valid?(limits) do
    Enum.all?(limits, fn
      {_key, nil} -> true
      {:max_cost, value} -> is_number(value) and value > 0
      {_key, value} -> is_integer(value) and value > 0
    end)
  end

  @spec new(limits()) :: t()
  def new(limits), do: %__MODULE__{limits: limits, counters: :atomics.new(7, signed: true)}

  @doc false
  # Charges a spend: `cost` is `nil` when some request had no price.
  @spec charge(t(), %{
          tokens: non_neg_integer(),
          cost: number() | nil,
          metric_calls: non_neg_integer()
        }) ::
          :ok
  def charge(%__MODULE__{counters: counters}, %{tokens: tokens, cost: cost, metric_calls: calls}) do
    :atomics.add(counters, @tokens, tokens || 0)
    :atomics.add(counters, @calls, calls || 0)

    case cost do
      nil -> :atomics.add(counters, @unpriced, 1)
      cost -> :atomics.add(counters, @cost, round(cost * @pico))
    end
  end

  @doc false
  # Holds `spend` back from the search phase.
  @spec reserve(t(), %{
          tokens: non_neg_integer(),
          cost: number() | nil,
          metric_calls: non_neg_integer()
        }) ::
          :ok
  def reserve(%__MODULE__{counters: counters}, spend) do
    :atomics.put(counters, @reserve_tokens, spend.tokens || 0)
    :atomics.put(counters, @reserve_cost, round((spend.cost || 0) * @pico))
    :atomics.put(counters, @reserve_calls, spend.metric_calls || 0)
  end

  @doc false
  # What is left in `phase` (`:search` subtracts the reserve, `:final` does
  # not) as `Nous.Eval.run/2` budget limits, or `:exhausted`.
  @spec remaining(t(), :search | :final) :: {:ok, keyword()} | :exhausted
  def remaining(%__MODULE__{limits: limits, counters: counters} = ledger, phase) do
    {reserve_tokens, reserve_cost, reserve_calls} =
      case phase do
        :search ->
          {:atomics.get(counters, @reserve_tokens), :atomics.get(counters, @reserve_cost),
           :atomics.get(counters, @reserve_calls)}

        :final ->
          {0, 0, 0}
      end

    tokens = left(limits.max_tokens, :atomics.get(counters, @tokens) + reserve_tokens)
    calls = left(limits.max_metric_calls, :atomics.get(counters, @calls) + reserve_calls)

    cost =
      case limits.max_cost do
        nil -> nil
        max -> (round(max * @pico) - :atomics.get(counters, @cost) - reserve_cost) / @pico
      end

    cond do
      limits.max_cost != nil and unpriced?(ledger) -> :exhausted
      Enum.any?([tokens, calls], &(&1 != nil and &1 <= 0)) -> :exhausted
      cost != nil and cost <= 0 -> :exhausted
      true -> {:ok, [max_tokens: tokens, max_cost: cost, max_samples: calls]}
    end
  end

  defp left(nil, _spent), do: nil
  defp left(max, spent), do: max - spent

  defp unpriced?(%__MODULE__{counters: counters}), do: :atomics.get(counters, @unpriced) > 0

  @spec exhausted?(t(), :search | :final) :: boolean()
  def exhausted?(ledger, phase), do: remaining(ledger, phase) == :exhausted

  @doc false
  # JSON-friendly report: limits, what was spent and what is reserved.
  @spec report(t()) :: map()
  def report(%__MODULE__{limits: limits, counters: counters}) do
    unpriced = :atomics.get(counters, @unpriced)

    %{
      limits: limits,
      spent: %{
        tokens: :atomics.get(counters, @tokens),
        cost: if(unpriced == 0, do: :atomics.get(counters, @cost) / @pico),
        metric_calls: :atomics.get(counters, @calls),
        unpriced_spends: unpriced
      },
      reserved: %{
        tokens: :atomics.get(counters, @reserve_tokens),
        cost: :atomics.get(counters, @reserve_cost) / @pico,
        metric_calls: :atomics.get(counters, @reserve_calls)
      }
    }
  end
end
