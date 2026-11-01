defmodule Nous.Eval.Scorers.Similarity do
  @moduledoc """
  Scores the output's similarity to the expected text as a Levenshtein ratio
  over graphemes: `1 - distance / max(length)`, a float in `0.0..1.0`.

      {Nous.Eval.Scorers.Similarity, expected: "The capital is Paris", threshold: 0.9}

  ## Options

    * `:expected` - the expected text; when absent, the case's
      `expected["output"]`
    * `:threshold` - `passed?` when the ratio is at least this (default `0.8`)
    * `:max_len` - the longest text (in graphemes) compared, default `2_000`.
      Levenshtein is quadratic, so a longer output or expectation is an
      `:invalid_config` error instead of a long stall
    * `:case_sensitive` (default `true`), `:trim` (default `true`),
      `:collapse_whitespace` (default `false`) - as in
      `Nous.Eval.Scorers.Equals`

  A failed run fails with reason `"run_failed"`; non-text output is an
  `:invalid_config` error.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Scorers.Options

  @id "similarity"
  @option_keys [:expected, :threshold, :max_len, :case_sensitive, :trim, :collapse_whitespace]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys),
         {:ok, expected} <- expected_opt(Map.get(map, :expected)) do
      Options.parse(
        map,
        [
          {:threshold, 0.8, &Options.unit_float(@id, :threshold, &1)},
          {:max_len, 2_000, &max_len/1}
          | Options.text_parsers(@id)
        ],
        %{expected: expected}
      )
    end
  end

  defp expected_opt(value) when is_nil(value) or is_binary(value), do: {:ok, value}

  defp expected_opt(value),
    do: Options.invalid(@id, "expected must be a string, got #{inspect(value)}")

  defp max_len(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp max_len(n),
    do: Options.invalid(@id, "max_len must be a positive integer, got #{inspect(n)}")

  @impl true
  def score(%ScoreInput{} = input, config) do
    with false <- Options.run_failed?(input),
         {:ok, expected} when is_binary(expected) <- Options.expected(config, input),
         output when is_binary(output) <- input.output do
      a = output |> Options.normalize_text(config) |> String.graphemes()
      b = expected |> Options.normalize_text(config) |> String.graphemes()
      {len_a, len_b} = {length(a), length(b)}

      if max(len_a, len_b) > config.max_len do
        Options.scorer_error(@id, :invalid_config, "text longer than max_len #{config.max_len}")
      else
        ratio = ratio(a, b, len_a, len_b)

        {:ok,
         %Score{
           name: @id,
           value: ratio,
           passed?: ratio >= config.threshold,
           reason: if(ratio >= config.threshold, do: nil, else: "similarity below threshold"),
           details: %{threshold: config.threshold}
         }}
      end
    else
      true ->
        {:ok, Options.run_failed_score(@id)}

      {:ok, _not_text} ->
        Options.scorer_error(@id, :invalid_config, "expected value is not text")

      :error ->
        Options.scorer_error(
          @id,
          :invalid_config,
          "no expected value (option or case expected.output)"
        )

      _structured ->
        Options.scorer_error(@id, :invalid_config, "text expected but the output is structured")
    end
  end

  defp ratio(_a, _b, 0, 0), do: 1.0
  defp ratio(a, b, len_a, len_b), do: 1.0 - distance(a, b) / max(len_a, len_b)

  @doc false
  # Levenshtein distance between grapheme lists, one row at a time.
  def distance(a, b) do
    first_row = Enum.to_list(0..length(b))

    a
    |> Enum.with_index(1)
    |> Enum.reduce(first_row, fn {char, i}, prev -> next_row(char, b, prev, [i]) end)
    |> List.last()
  end

  defp next_row(_char, [], _prev, acc), do: Enum.reverse(acc)

  defp next_row(char, [other | rest], [diagonal, up | prev_rest], [left | _] = acc) do
    cost = if char == other, do: 0, else: 1
    next_row(char, rest, [up | prev_rest], [min(min(up + 1, left + 1), diagonal + cost) | acc])
  end

  @impl true
  def describe(config), do: config
end
