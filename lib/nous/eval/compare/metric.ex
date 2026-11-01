defmodule Nous.Eval.Compare.Metric do
  @moduledoc """
  The per-case metrics `Nous.Eval.Compare` can gate on and break down by.

  Every metric is a value per case in `0.0..1.0`, so the unit of the paired
  bootstrap is the case:

    * `:pass_rate` - the share of the case's scored (`:pass`/`:fail`)
      samples that passed
    * `:case_score` - the mean of the samples' gated `case_score` (see
      `Nous.Eval.Scoring`)
    * `{:scorer, name}` - the share of the case's samples whose score named
      `name` (a `Nous.Eval.Score` name such as `"contains"` or
      `"judge.relevance"`) has `passed?: true`, regardless of how scores are
      composed into the verdict

  A metric is undefined for a case without the data it needs (no scored
  sample, no `case_score`, no score of that name); such cases are left out
  of that metric's comparison.

  Command-line and config values are strings: `"pass_rate"`,
  `"case_score"` and `"scorer:<name>"` parse through a closed table, never
  into new atoms.
  """

  @type t :: :pass_rate | :case_score | {:scorer, String.t()}

  @doc """
  Validates a metric given as a term or a string.

  ## Examples

      iex> Nous.Eval.Compare.Metric.parse("scorer:judge.relevance")
      {:ok, {:scorer, "judge.relevance"}}

      iex> Nous.Eval.Compare.Metric.parse("accuracy")
      {:error, {:invalid_metric, "accuracy"}}
  """
  @spec parse(term()) :: {:ok, t()} | {:error, {:invalid_metric, term()}}
  def parse(metric) when metric in [:pass_rate, :case_score], do: {:ok, metric}
  def parse("pass_rate"), do: {:ok, :pass_rate}
  def parse("case_score"), do: {:ok, :case_score}
  def parse("scorer:" <> name) when name != "", do: {:ok, {:scorer, name}}
  def parse({:scorer, name} = metric) when is_binary(name) and name != "", do: {:ok, metric}
  def parse(other), do: {:error, {:invalid_metric, other}}

  @doc """
  The string form of a metric (the inverse of `parse/1`).

  ## Examples

      iex> Nous.Eval.Compare.Metric.name({:scorer, "contains"})
      "scorer:contains"
  """
  @spec name(t()) :: String.t()
  def name(:pass_rate), do: "pass_rate"
  def name(:case_score), do: "case_score"
  def name({:scorer, name}), do: "scorer:" <> name

  @doc false
  # The metric's value for one case, from `Nous.Eval.Summary.case_stats/1`;
  # `nil` when undefined.
  @spec value(t(), map()) :: float() | nil
  def value(:pass_rate, %{pass_rate: rate}), do: rate

  def value(:case_score, %{case_scores: []}), do: nil
  def value(:case_score, %{case_scores: scores}), do: Enum.sum(scores) / length(scores)

  def value({:scorer, name}, %{scorers: scorers}) do
    case Map.get(scorers, name) do
      %{total: total, passed: passed} when total > 0 -> passed / total
      _ -> nil
    end
  end
end
