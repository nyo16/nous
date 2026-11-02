defmodule Nous.Eval.Scorers.NotContains do
  @moduledoc """
  Passes when the output text contains none of the given substrings.

      {Nous.Eval.Scorers.NotContains, values: ["As an AI", "I cannot"], case_sensitive: false}

  ## Options

    * `:values` - non-empty list of non-empty strings (required)
    * `:case_sensitive` - default `true`

  `details.found` lists the indexes of the values present. A failed run
  fails with reason `"run_failed"` (no output proves nothing); non-text
  output is an `:invalid_config` error.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Scorers.{Contains, Options}

  @id "not_contains"
  @option_keys [:values, :case_sensitive]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys),
         {:ok, config} <-
           Options.parse(map, [
             {:values, nil, &Options.string_list(@id, :values, &1)},
             {:case_sensitive, true, &Options.boolean(@id, :case_sensitive, &1)}
           ]) do
      {:ok, Map.put(config, :needles, Contains.needles(config.values, config.case_sensitive))}
    end
  end

  @impl true
  def score(%ScoreInput{} = input, config) do
    case Options.text_output(@id, input) do
      {:result, result} ->
        result

      {:ok, text} ->
        haystack = Contains.haystack(text, config.case_sensitive)

        found =
          for {needle, index} <- Enum.with_index(config.needles),
              String.contains?(haystack, needle),
              do: index

        passed? = found == []

        {:ok,
         %Score{
           Options.pass_fail(
             @id,
             passed?,
             unless(passed?, do: "#{length(found)} forbidden value(s) found")
           )
           | details: %{found: found}
         }}
    end
  end

  @impl true
  def describe(config), do: Map.delete(config, :needles)
end
