defmodule Nous.Eval.Simulator.Scorers.State do
  @moduledoc """
  Passes when the episode's end state holds every `{path, equals}` of the
  case's `expected.state` (`"sim.state"`).

  The end state is what the task's `c:Nous.Eval.episode_state/1` returned
  after the conversation, read with string keys (`path` segments are
  strings, or integers for list positions). Values compare with `==`, so
  `1` equals `1.0`.

  Attached to simulated cases by `Nous.Eval.Simulator`; it takes no
  options. How the episode ended is decided first, as for every simulation
  scorer (see "Termination" in `Nous.Eval.Simulator`); an end state that
  could not be read is an `:unscoreable` error. `details["mismatches"]`
  lists the entries that failed with the actual value.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Simulator.Scorers.Common

  @id "sim.state"

  @impl true
  def id, do: @id

  @impl true
  def init([]), do: {:ok, %{}}
  def init(opts), do: {:error, "#{@id}: takes no options, got #{inspect(opts)}"}

  @impl true
  def score(%ScoreInput{} = input, _config) do
    Common.score(input, @id, fn episode -> check(episode, input.case.expected["state"]) end)
  end

  defp check(_episode, nil),
    do: Common.scorer_error(@id, :invalid_config, "the case has no expected.state")

  defp check(%{"end_state" => %{} = state}, entries) do
    case Common.state_mismatches(state, entries) do
      [] ->
        {:ok, %Score{name: @id, value: :pass, passed?: true, details: %{"mismatches" => []}}}

      mismatches ->
        {:ok,
         %Score{
           name: @id,
           value: :fail,
           passed?: false,
           reason: "#{length(mismatches)} of #{length(entries)} end-state check(s) failed",
           details: %{"mismatches" => mismatches}
         }}
    end
  end

  defp check(episode, _entries) do
    Common.unscoreable(@id, "an unreadable end state", episode["end_state_error"])
  end
end
