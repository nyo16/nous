defmodule Nous.Eval.Scorers.MaxCost do
  @moduledoc """
  Passes when the sample's model spend is at most `:max_usd`.

      {Nous.Eval.Scorers.MaxCost, max_usd: 0.02, required: false, weight: 0}

  Cost is priced with `Nous.Usage.cost/2` (rates from `Nous.Usage.Pricing`).
  By default every completed model request in the trace (the whole run tree,
  including sub-agents) is priced with the model that actually answered it,
  so fallbacks and sub-agents on other models are billed correctly. With
  `:model`, the sample's summed `usage` is priced at that one model's rates
  instead.

  A model without a known price is a scorer error, never a pass: a wrong
  price is worse than none. Declare it track-only (`required: false,
  weight: 0`) unless the budget is a hard requirement.

  ## Options

    * `:max_usd` - the limit in US dollars (required)
    * `:model` - `"provider:model"` (or a `Nous.Model`) to price the summed
      usage with; must have a known price (checked in `init/1`)

  On a truncated trace a cost within budget is a `:missing_trace` error (the
  missing requests would add to it). `details` holds `cost_usd` and, when
  priced from the trace, `by_model` (`"provider:model" => usd`).
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput, Trace}
  alias Nous.Eval.Scorers.Options
  alias Nous.Eval.Trace.ModelCall

  @id "max_cost"
  @option_keys [:max_usd, :model]

  @impl true
  def id, do: @id

  @impl true
  def content, do: :none

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys),
         {:ok, config} <-
           Options.parse(map, [{:max_usd, nil, &Options.non_neg_number(@id, :max_usd, &1)}]),
         {:ok, model} <- model(Map.get(map, :model)) do
      {:ok, Map.put(config, :model, model)}
    end
  end

  defp model(nil), do: {:ok, nil}

  defp model(model) when is_binary(model) or is_struct(model, Nous.Model) do
    case Nous.Usage.cost(%Nous.Usage{}, model) do
      {:ok, _cost} ->
        {:ok, model}

      {:error, :unknown_model} ->
        Options.invalid(@id, "no known price for model #{describe_model(model)}")
    end
  end

  defp model(other),
    do: Options.invalid(@id, "model must be \"provider:model\", got #{inspect(other)}")

  @impl true
  def score(%ScoreInput{} = input, %{model: model} = config) when model != nil do
    {:ok, cost} = Nous.Usage.cost(input.usage, model)
    verdict(config, cost.total, %{cost_usd: cost.total})
  end

  def score(%ScoreInput{trace: %Trace{} = trace} = input, config) do
    calls = trace |> Trace.model_calls() |> Enum.filter(&(&1.outcome == :ok))

    with {:calls, false} <- {:calls, calls == [] and input.usage.total_tokens > 0},
         {:ok, by_model} <- price(calls),
         total = Enum.reduce(Map.values(by_model), 0.0, &+/2),
         {:truncated, false} <- {:truncated, trace.truncated? and total <= config.max_usd} do
      verdict(config, total, %{cost_usd: total, by_model: by_model})
    else
      {:calls, true} ->
        Options.missing_trace(@id, "usage reported but the trace holds no model requests")

      {:truncated, true} ->
        Options.missing_trace(@id, "trace truncated; missing requests would add cost")

      {:error, reason} ->
        Options.scorer_error(@id, :invalid_config, reason)
    end
  end

  def score(%ScoreInput{}, _config), do: Options.missing_trace(@id, "no trace")

  defp price(calls) do
    Enum.reduce_while(calls, {:ok, %{}}, fn %ModelCall{} = call, {:ok, acc} ->
      provider = call.active_model_provider || call.model_provider
      name = call.active_model_name || call.model_name

      with true <- is_atom(provider) and provider != nil and is_binary(name),
           {:ok, cost} <-
             Nous.Usage.cost(call.usage, %Nous.Model{provider: provider, model: name}) do
        {:cont, {:ok, Map.update(acc, "#{provider}:#{name}", cost.total, &(&1 + cost.total))}}
      else
        false ->
          {:halt, {:error, "a model request in the trace has no model id"}}

        {:error, :unknown_model} ->
          {:halt, {:error, "no known price for model #{provider}:#{name}"}}
      end
    end)
  end

  defp verdict(config, total, details) do
    passed? = total <= config.max_usd
    reason = unless passed?, do: "cost $#{Float.round(total / 1, 6)} above $#{config.max_usd}"
    {:ok, %Score{Options.pass_fail(@id, passed?, reason) | details: details}}
  end

  @impl true
  def describe(config), do: %{config | model: config.model && describe_model(config.model)}

  defp describe_model(%Nous.Model{provider: provider, model: model}), do: "#{provider}:#{model}"
  defp describe_model(model), do: model
end
