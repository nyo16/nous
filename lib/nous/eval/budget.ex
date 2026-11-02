defmodule Nous.Eval.Budget do
  @moduledoc false
  # The spending ledger of one eval run (`Nous.Eval.run/2`'s `:budget`).
  #
  # Internal: the only way in is the `budget:` option, whose semantics are
  # documented on `Nous.Eval.run/2`; nothing here is a user-facing operation,
  # and keeping it private leaves the ledger free to change.
  #
  # Counting. A telemetry handler attached for the run's lifetime receives
  # every `[:nous, :agent, :model, :stop]` and charges the ones whose
  # `trace_id` the runner registered (`track/2`) for this run. The event
  # fires for every answered model request, including turns whose output
  # later failed validation or whose run then crashed, so failed turns are
  # paid for. It runs in the emitting process, before the run's next
  # cancellation check, and the counters are `:atomics`, so the ledger is
  # exact under parallel samples. Model-graded scorers run under their own
  # trace ids, which they register with `track/2` before their first call,
  # so every judge request (answered, retried after unparseable output, or
  # cut off by a scorer timeout) is charged exactly once, the same way.
  #
  # Pricing. Each request is priced with `Nous.Usage.cost/2` against the
  # model that answered (`active_model_*`, which differs from the configured
  # model on a fallback or a route). Cost is kept in pico-dollars, so the
  # integer counter loses nothing a price table can express.
  #
  # Exhaustion. Spend limits and the sample limit are recorded in separate
  # slots, each once (first reason wins within a slot). `:max_tokens` /
  # `:max_cost` stop spending: no sample is admitted, a running agent is
  # cancelled at its next step (`cancellation_check/1`), and model-graded
  # scorers are not called. `:max_samples` only refuses admission; samples
  # already running finish. With `:max_cost` set, a request whose model has
  # no price exhausts the budget (`:unknown_price`): a spend that cannot be
  # measured cannot be bounded. A spend limit reached after `:max_samples`
  # still stops spending, and `exhausted/1` then reports the spend reason
  # (spend outranks samples).
  #
  # The handler is total (a raising handler would be detached and stop
  # counting, failing open).

  alias Nous.Usage

  @model_stop [:nous, :agent, :model, :stop]
  @pico 1_000_000_000_000

  # atomics slots
  @tokens 1
  @cost 2
  @samples 3
  @unpriced 4
  @spend_reason 5
  @samples_reason 6

  @reasons %{1 => :max_tokens, 2 => :max_cost, 3 => :max_samples, 4 => :unknown_price}
  @codes Map.new(@reasons, fn {code, reason} -> {reason, code} end)

  @type limits :: %{
          max_tokens: pos_integer() | nil,
          max_cost: number() | nil,
          max_samples: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          limits: limits(),
          counters: :atomics.atomics_ref(),
          traces: :ets.tid(),
          handler_id: term()
        }

  @enforce_keys [:limits, :counters, :traces, :handler_id]
  defstruct [:limits, :counters, :traces, :handler_id]

  @doc false
  # Validates the `budget:` option (`nil` or a keyword list of
  # `:max_tokens`, `:max_cost`, `:max_samples`).
  @spec limits(term()) :: {:ok, limits()} | {:error, term()}
  def limits(nil), do: limits([])

  def limits(opts) when is_list(opts) do
    case Keyword.validate(opts, max_tokens: nil, max_cost: nil, max_samples: nil) do
      {:ok, opts} ->
        Enum.reduce_while(opts, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          if valid_limit?(key, value),
            do: {:cont, {:ok, Map.put(acc, key, value)}},
            else: {:halt, {:error, {:invalid_option, :budget, [{key, value}]}}}
        end)

      {:error, unknown} ->
        {:error, {:invalid_option, :budget, unknown}}
    end
  end

  def limits(other), do: {:error, {:invalid_option, :budget, other}}

  defp valid_limit?(_key, nil), do: true
  defp valid_limit?(:max_cost, value), do: is_number(value) and value > 0
  defp valid_limit?(_key, value), do: is_integer(value) and value > 0

  @doc false
  # Checks, before any model call, that every model the run may pay for has
  # a price when `:max_cost` is set. `models` are `%Nous.Model{}`s or
  # `"provider:model"` strings.
  @spec preflight(limits(), [Nous.Model.t() | String.t()]) ::
          :ok | {:error, {:unknown_price, String.t()}}
  def preflight(%{max_cost: nil}, _models), do: :ok

  def preflight(%{max_cost: _}, models) do
    Enum.find_value(models, :ok, fn model ->
      case Usage.cost(%Usage{}, model) do
        {:ok, _} -> nil
        {:error, :unknown_model} -> {:error, {:unknown_price, model_name(model)}}
      end
    end)
  end

  defp model_name(%Nous.Model{provider: provider, model: model}), do: "#{provider}:#{model}"
  defp model_name(model) when is_binary(model), do: model

  @doc false
  # Creates the ledger and attaches its handler. Pair with `stop/1`.
  @spec start(limits()) :: t()
  def start(limits) do
    budget = %__MODULE__{
      limits: limits,
      counters: :atomics.new(6, signed: true),
      traces: :ets.new(__MODULE__, [:set, :public, read_concurrency: true]),
      handler_id: {__MODULE__, make_ref()}
    }

    :ok = :telemetry.attach(budget.handler_id, @model_stop, &__MODULE__.handle_event/4, budget)
    budget
  end

  @doc false
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = budget) do
    :telemetry.detach(budget.handler_id)
    :ets.delete(budget.traces)
    :ok
  end

  @doc false
  # Charges the model requests of `trace_id` to this run.
  @spec track(t(), String.t()) :: :ok
  def track(%__MODULE__{traces: traces}, trace_id) when is_binary(trace_id) do
    :ets.insert(traces, {trace_id})
    :ok
  end

  @doc false
  def handle_event(@model_stop, measurements, %{trace_id: trace_id} = meta, budget)
      when is_binary(trace_id) do
    if :ets.member(budget.traces, trace_id) do
      provider = meta[:active_model_provider] || meta[:model_provider]
      name = meta[:active_model_name] || meta[:model_name]
      charge(budget, usage(measurements), model(provider, name))
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_event(_name, _measurements, _meta, _budget), do: :ok

  defp usage(measurements) do
    input = count(measurements[:input_tokens])
    output = count(measurements[:output_tokens])
    total = count(measurements[:total_tokens])

    %Usage{
      requests: 1,
      input_tokens: input,
      output_tokens: output,
      total_tokens: if(total == 0, do: input + output, else: total),
      cache_creation_input_tokens: count(measurements[:cache_creation_input_tokens]),
      cache_read_input_tokens: count(measurements[:cache_read_input_tokens])
    }
  end

  defp count(n) when is_integer(n) and n > 0, do: n
  defp count(_), do: 0

  defp model(provider, name) when is_atom(provider) and is_binary(name),
    do: %Nous.Model{provider: provider, model: name}

  defp model(_provider, _name), do: nil

  @doc false
  # Charges `usage` priced against `model` (a `%Nous.Model{}`, a
  # `"provider:model"` string, or `nil` when unknown).
  @spec charge(t(), Usage.t(), Nous.Model.t() | String.t() | nil) :: :ok
  def charge(%__MODULE__{counters: counters, limits: limits} = budget, %Usage{} = usage, model) do
    tokens = :atomics.add_get(counters, @tokens, usage.total_tokens)

    cost =
      case model && Usage.cost(usage, model) do
        {:ok, %{total: total}} ->
          :atomics.add_get(counters, @cost, round(total * @pico))

        _unknown ->
          :atomics.add(counters, @unpriced, 1)
          if limits.max_cost, do: exhaust(budget, :unknown_price)
          :atomics.get(counters, @cost)
      end

    cond do
      limits.max_tokens && tokens >= limits.max_tokens -> exhaust(budget, :max_tokens)
      limits.max_cost && cost >= round(limits.max_cost * @pico) -> exhaust(budget, :max_cost)
      true -> :ok
    end

    :ok
  end

  defp exhaust(%__MODULE__{counters: counters}, :max_samples) do
    :atomics.compare_exchange(counters, @samples_reason, 0, Map.fetch!(@codes, :max_samples))
    :ok
  end

  defp exhaust(%__MODULE__{counters: counters}, reason) do
    :atomics.compare_exchange(counters, @spend_reason, 0, Map.fetch!(@codes, reason))
    :ok
  end

  @doc false
  # Admits one more sample, or refuses (and records why) when a limit has
  # been reached.
  @spec admit(t()) :: :ok | :exhausted
  def admit(%__MODULE__{counters: counters, limits: limits} = budget) do
    if exhausted(budget) != nil do
      :exhausted
    else
      admitted = :atomics.add_get(counters, @samples, 1)

      if limits.max_samples && admitted > limits.max_samples do
        :atomics.sub(counters, @samples, 1)
        exhaust(budget, :max_samples)
        :exhausted
      else
        :ok
      end
    end
  end

  @doc false
  # The limit that ended the run, or `nil`: the spend reason when spending
  # stopped, else `:max_samples` when admission was refused.
  @spec exhausted(t()) :: :max_tokens | :max_cost | :max_samples | :unknown_price | nil
  def exhausted(%__MODULE__{counters: counters}) do
    case :atomics.get(counters, @spend_reason) do
      0 -> Map.get(@reasons, :atomics.get(counters, @samples_reason))
      code -> Map.fetch!(@reasons, code)
    end
  end

  @doc false
  # True once a token or cost limit stopped spending (`:max_samples` does
  # not stop work already admitted).
  @spec spend_exhausted?(t()) :: boolean()
  def spend_exhausted?(%__MODULE__{counters: counters}),
    do: :atomics.get(counters, @spend_reason) != 0

  @doc false
  # The agent's `:cancellation_check`: throws `{:cancelled,
  # :budget_exhausted}` at the next step once spending must stop.
  @spec cancellation_check(t()) :: (-> :ok)
  def cancellation_check(%__MODULE__{} = budget) do
    fn ->
      if spend_exhausted?(budget), do: throw({:cancelled, :budget_exhausted})
      :ok
    end
  end

  @doc false
  # The limits and what was spent, for `Nous.Eval.Run`'s `:budget`. `cost` is
  # `nil` when some request had no price (`unpriced_requests`).
  @spec report(t()) :: map()
  def report(%__MODULE__{counters: counters, limits: limits} = budget) do
    unpriced = :atomics.get(counters, @unpriced)

    %{
      limits: limits,
      spent: %{
        tokens: :atomics.get(counters, @tokens),
        cost: if(unpriced == 0, do: :atomics.get(counters, @cost) / @pico),
        samples: :atomics.get(counters, @samples),
        unpriced_requests: unpriced
      },
      exhausted: exhausted(budget)
    }
  end
end
