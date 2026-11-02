defmodule Nous.Eval.Scorers.MaxTokens do
  @moduledoc """
  Passes when the sample's token use (summed over the whole run tree) is at
  most `:max`.

      {Nous.Eval.Scorers.MaxTokens, max: 20_000, required: false, weight: 0}

  Declare it track-only (`required: false, weight: 0`) unless the budget is
  a hard requirement: the result is then recorded for every sample without
  deciding the verdict.

  ## Options

    * `:max` - the token limit (required)
    * `:field` - `:total` (default), `:input` or `:output`

  Reads `Nous.Eval.ScoreInput.usage`. `details.tokens` holds the count.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Scorers.Options

  @id "max_tokens"
  @option_keys [:max, :field]
  @fields %{total: :total_tokens, input: :input_tokens, output: :output_tokens}

  @impl true
  def id, do: @id

  @impl true
  def content, do: :none

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys) do
      Options.parse(map, [
        {:max, nil, &Options.non_neg_integer(@id, :max, &1)},
        {:field, :total, &Options.enum(@id, :field, &1, Map.keys(@fields))}
      ])
    end
  end

  @impl true
  def score(%ScoreInput{usage: %Nous.Usage{} = usage}, config) do
    tokens = Map.fetch!(usage, Map.fetch!(@fields, config.field))
    passed? = tokens <= config.max
    reason = unless passed?, do: "#{tokens} #{config.field} tokens, limit #{config.max}"
    {:ok, %Score{Options.pass_fail(@id, passed?, reason) | details: %{tokens: tokens}}}
  end

  def score(%ScoreInput{}, _config), do: Options.scorer_error(@id, :invalid_config, "no usage")

  @impl true
  def describe(config), do: config
end
