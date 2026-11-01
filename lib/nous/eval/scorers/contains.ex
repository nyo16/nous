defmodule Nous.Eval.Scorers.Contains do
  @moduledoc """
  Passes when the output text contains the given substrings.

      {Nous.Eval.Scorers.Contains, values: ["refund", "order 123"], mode: :all}

  ## Options

    * `:values` - non-empty list of non-empty strings (required; an empty
      list is a configuration error, never a vacuous pass)
    * `:mode` - `:all` (default) or `:any`
    * `:case_sensitive` - default `true`

  `details.missing` lists the indexes of the values not found. A failed run
  fails with reason `"run_failed"`; non-text output is an `:invalid_config`
  error.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Scorers.Options

  @id "contains"
  @option_keys [:values, :mode, :case_sensitive]

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
             {:mode, :all, &Options.enum(@id, :mode, &1, [:all, :any])},
             {:case_sensitive, true, &Options.boolean(@id, :case_sensitive, &1)}
           ]) do
      {:ok, Map.put(config, :needles, needles(config.values, config.case_sensitive))}
    end
  end

  @doc false
  def needles(values, true), do: values
  def needles(values, false), do: Enum.map(values, &String.downcase/1)

  @doc false
  def haystack(text, true), do: text
  def haystack(text, false), do: String.downcase(text)

  @impl true
  def score(%ScoreInput{} = input, config) do
    case Options.text_output(@id, input) do
      {:result, result} ->
        result

      {:ok, text} ->
        haystack = haystack(text, config.case_sensitive)

        missing =
          for {needle, index} <- Enum.with_index(config.needles),
              not String.contains?(haystack, needle),
              do: index

        found = length(config.needles) - length(missing)
        passed? = if config.mode == :all, do: missing == [], else: found > 0

        {:ok,
         %Score{
           Options.pass_fail(
             @id,
             passed?,
             unless(passed?,
               do: "#{length(missing)} of #{length(config.needles)} values not found"
             )
           )
           | details: %{missing: missing, mode: config.mode}
         }}
    end
  end

  @impl true
  def describe(config), do: Map.delete(config, :needles)
end
