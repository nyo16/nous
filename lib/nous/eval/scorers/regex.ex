defmodule Nous.Eval.Scorers.Regex do
  @moduledoc """
  Passes when the output text matches regular expressions.

      {Nous.Eval.Scorers.Regex, patterns: ["order #\\\\d+", "refund"], mode: :all}

  ## Options

    * `:patterns` - non-empty list of regex sources (required). They are
      compiled once in `init/1`: an invalid pattern is a configuration
      error, never a "not found"
    * `:mode` - `:all` (default) or `:any`
    * `:case_sensitive` - default `true`

  `details.unmatched` lists the indexes of the patterns that did not match.
  A failed run fails with reason `"run_failed"`; non-text output is an
  `:invalid_config` error.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Scorers.Options

  @id "regex"
  @option_keys [:patterns, :mode, :case_sensitive]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys),
         {:ok, config} <-
           Options.parse(map, [
             {:patterns, nil, &Options.string_list(@id, :patterns, &1)},
             {:mode, :all, &Options.enum(@id, :mode, &1, [:all, :any])},
             {:case_sensitive, true, &Options.boolean(@id, :case_sensitive, &1)}
           ]),
         {:ok, compiled} <- compile(config.patterns, config.case_sensitive) do
      {:ok, Map.put(config, :compiled, compiled)}
    end
  end

  defp compile(patterns, case_sensitive) do
    flags = if case_sensitive, do: "u", else: "iu"

    patterns
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {pattern, index}, {:ok, acc} ->
      case Regex.compile(pattern, flags) do
        {:ok, regex} ->
          {:cont, {:ok, [regex | acc]}}

        {:error, reason} ->
          {:halt, Options.invalid(@id, "patterns[#{index}] is invalid: #{inspect(reason)}")}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  @impl true
  def score(%ScoreInput{} = input, config) do
    case Options.text_output(@id, input) do
      {:result, result} ->
        result

      {:ok, text} ->
        unmatched =
          for {regex, index} <- Enum.with_index(config.compiled),
              not Regex.match?(regex, text),
              do: index

        matched = length(config.compiled) - length(unmatched)
        passed? = if config.mode == :all, do: unmatched == [], else: matched > 0

        {:ok,
         %Score{
           Options.pass_fail(
             @id,
             passed?,
             unless(passed?,
               do: "#{length(unmatched)} of #{length(config.compiled)} patterns did not match"
             )
           )
           | details: %{unmatched: unmatched, mode: config.mode}
         }}
    end
  end

  @impl true
  def describe(config), do: Map.delete(config, :compiled)
end
