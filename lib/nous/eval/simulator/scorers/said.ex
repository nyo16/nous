defmodule Nous.Eval.Simulator.Scorers.Said do
  @moduledoc """
  Passes when every string of the case's `expected.said` appears in some
  agent message of the episode (`"sim.said"`): what the agent had to
  communicate, such as an amount or a confirmation number (τ-bench's
  output check).

  Matching ignores case and commas (`"1,054.04"` contains `"1054.04"`).
  Only the agent's replies count, never the simulated user's messages.

  Attached to simulated cases by `Nous.Eval.Simulator`; it takes no
  options. How the episode ended is decided first, as for every simulation
  scorer (see "Termination" in `Nous.Eval.Simulator`).
  `details["missing"]` lists the strings no reply contained.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Simulator.Scorers.Common

  @id "sim.said"

  @impl true
  def id, do: @id

  @impl true
  def init([]), do: {:ok, %{}}
  def init(opts), do: {:error, "#{@id}: takes no options, got #{inspect(opts)}"}

  @impl true
  def score(%ScoreInput{} = input, _config) do
    Common.score(input, @id, fn episode -> check(episode, input.case.expected["said"]) end)
  end

  defp check(_episode, nil),
    do: Common.scorer_error(@id, :invalid_config, "the case has no expected.said")

  defp check(episode, expected) do
    replies =
      for %{"role" => "agent", "text" => text} <- episode["transcript"] || [],
          is_binary(text),
          do: normalize(text)

    case Enum.reject(expected, fn s -> Enum.any?(replies, &String.contains?(&1, normalize(s))) end) do
      [] ->
        {:ok, %Score{name: @id, value: :pass, passed?: true, details: %{"missing" => []}}}

      missing ->
        {:ok,
         %Score{
           name: @id,
           value: :fail,
           passed?: false,
           reason:
             "the agent never said #{length(missing)} of #{length(expected)} expected string(s)",
           details: %{"missing" => missing}
         }}
    end
  end

  defp normalize(text), do: text |> String.downcase() |> String.replace(",", "")
end
