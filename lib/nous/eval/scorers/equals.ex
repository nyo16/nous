defmodule Nous.Eval.Scorers.Equals do
  @moduledoc """
  Passes when the agent's output equals the expected value.

      {Nous.Eval.Scorers.Equals, expected: "Paris", case_sensitive: false}

  Text is compared after normalization. A structured expected value (map or
  list) is compared by deep equality with the structured output (or a JSON
  text output, decoded): keys are compared as strings, numbers with `==`
  (`1` equals `1.0`), and extra keys fail.

  ## Options

    * `:expected` - the expected value; when absent, the case's
      `expected["output"]` is used, and a case without it is a scorer error
    * `:case_sensitive` - default `true`
    * `:trim` - trim surrounding whitespace, default `true`
    * `:collapse_whitespace` - collapse whitespace runs to one space, default
      `false`

  A failed run fails with reason `"run_failed"`. Structured output against a
  text expectation is an `:invalid_config` error, not a fail.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{ScoreInput, Score}
  alias Nous.Eval.Scorers.{Args, Options}

  @id "equals"
  @option_keys [:expected, :case_sensitive, :trim, :collapse_whitespace]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys) do
      Options.parse(map, Options.text_parsers(@id), %{expected: Map.get(map, :expected)})
    end
  end

  @impl true
  def score(%ScoreInput{} = input, config) do
    if Options.run_failed?(input) do
      {:ok, Options.run_failed_score(@id)}
    else
      case Options.expected(config, input) do
        {:ok, expected} ->
          compare(input.output, expected, config)

        :error ->
          Options.scorer_error(
            @id,
            :invalid_config,
            "no expected value (option or case expected.output)"
          )
      end
    end
  end

  defp compare(output, expected, config) when is_binary(expected) do
    if is_binary(output) do
      passed? = Options.normalize_text(output, config) == Options.normalize_text(expected, config)
      {:ok, Options.pass_fail(@id, passed?, if(passed?, do: nil, else: "output differs"))}
    else
      Options.scorer_error(@id, :invalid_config, "text expected but the output is structured")
    end
  end

  defp compare(output, expected, _config) when is_map(expected) or is_list(expected) do
    paths =
      Args.diff(
        nil,
        structured(output),
        Args.normalize_expected(expected),
        Args.config(%{args: :exact})
      )

    passed? = paths == []

    {:ok,
     %Score{
       Options.pass_fail(@id, passed?, if(passed?, do: nil, else: "output differs"))
       | details: if(passed?, do: %{}, else: %{paths: paths})
     }}
  end

  defp compare(output, expected, _config) do
    passed? = is_number(output) and is_number(expected) and output == expected
    passed? = passed? or output === expected
    {:ok, Options.pass_fail(@id, passed?, if(passed?, do: nil, else: "output differs"))}
  end

  defp structured(%{} = struct) when is_struct(struct),
    do: struct |> Map.from_struct() |> Map.delete(:__meta__)

  defp structured(other), do: other

  @impl true
  def describe(config), do: config
end
