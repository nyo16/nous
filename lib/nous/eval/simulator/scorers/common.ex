defmodule Nous.Eval.Simulator.Scorers.Common do
  @moduledoc false
  # What every simulation scorer decides the same way: how the episode
  # ended (research simulator.md §4.4).
  #
  #   * `stop` / `transfer` / `out_of_scope` - scoreable, when the case's
  #     `expected.terminations` accepts the termination (else a fail)
  #   * `max_turns`, `agent_error`, a killed sample (timeout) or a failed
  #     run - a fail: the agent did not finish the job
  #   * `user_error`, `setup_error`, `budget` - an `:unscoreable` scorer
  #     error: not evidence about the agent, so the sample is `:error` and
  #     stays out of pass^k
  #
  # Episodes are read from the sample output (the run record keeps it, so a
  # rescore reads the same thing), never from the simulator's own account:
  # no scorer sees its `thought`.

  alias Nous.Eval.{Score, ScoreInput, ScorerError, Trace}
  alias Nous.Eval.Simulator.Episode

  @schema Episode.schema()
  @scoreable ["stop", "transfer", "out_of_scope"]
  @abnormal ["max_turns", "agent_error"]
  @unscoreable ["user_error", "setup_error", "budget"]

  @type class ::
          {:scoreable, String.t(), map()}
          | {:abnormal, String.t(), map() | nil}
          | {:unscoreable, String.t(), map()}
          | :not_episode

  @doc false
  @spec classify(ScoreInput.t()) :: class()
  def classify(%ScoreInput{run_outcome: :killed}), do: {:abnormal, "timeout", nil}

  def classify(%ScoreInput{
        run_outcome: {:ok, _},
        output: %{"schema" => @schema, "termination" => termination} = episode
      }) do
    cond do
      termination in @scoreable -> {:scoreable, termination, episode}
      termination in @abnormal -> {:abnormal, termination, episode}
      termination in @unscoreable -> {:unscoreable, termination, episode}
      true -> :not_episode
    end
  end

  def classify(%ScoreInput{run_outcome: {:ok, _}}), do: :not_episode
  def classify(%ScoreInput{}), do: {:abnormal, "run_failed", nil}

  @doc false
  # Runs `check.(episode)` for a scoreable episode whose termination the case
  # accepts; every other class gets its shared result.
  @spec score(ScoreInput.t(), String.t(), (map() -> Nous.Eval.Scorer.result())) ::
          Nous.Eval.Scorer.result()
  def score(%ScoreInput{} = input, id, check) do
    case classify(input) do
      {:scoreable, termination, episode} ->
        accepted = accepted_terminations(input)

        if termination in accepted,
          do: check.(episode),
          else:
            fail(
              id,
              "the episode ended with #{termination}, which this case does not accept " <>
                "(#{Enum.join(accepted, ", ")})",
              termination
            )

      {:abnormal, termination, _episode} ->
        fail(id, "the episode ended abnormally (#{termination})", termination)

      {:unscoreable, termination, episode} ->
        unscoreable(id, termination, episode["error"])

      :not_episode ->
        not_episode(id)
    end
  end

  defp accepted_terminations(%ScoreInput{case: %{expected: %{"terminations" => [_ | _] = list}}}),
    do: list

  defp accepted_terminations(_input), do: @scoreable

  @doc false
  def fail(id, reason, termination) do
    {:ok,
     %Score{
       name: id,
       value: :fail,
       passed?: false,
       reason: reason,
       metadata: %{"termination" => termination}
     }}
  end

  @doc false
  def unscoreable(id, why, detail) do
    reason =
      "the episode ended with #{why}#{if detail, do: ": " <> to_string(detail), else: ""}; " <>
        "it is not evidence about the agent"

    {:error,
     %ScorerError{scorer: id, kind: :unscoreable, reason: reason, details: %{"why" => why}}}
  end

  @doc false
  def scorer_error(id, kind, reason),
    do: {:error, %ScorerError{scorer: id, kind: kind, reason: reason}}

  @doc false
  def not_episode(id) do
    {:error,
     %ScorerError{
       scorer: id,
       kind: :invalid_config,
       reason: "#{id} scores simulated episodes (nous.sim_case/1) only"
     }}
  end

  @doc false
  # The value at `path` (string keys, list indexes) of JSON-native data.
  @spec dig(term(), [String.t() | non_neg_integer()]) :: {:ok, term()} | :missing
  def dig(value, []), do: {:ok, value}

  def dig(%{} = map, [key | rest]) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> dig(value, rest)
      :error -> :missing
    end
  end

  def dig(list, [index | rest]) when is_list(list) and is_integer(index) do
    case Enum.fetch(list, index) do
      {:ok, value} -> dig(value, rest)
      :error -> :missing
    end
  end

  def dig(_value, _path), do: :missing

  @doc false
  # The `{path, equals}` entries the end state fails, as JSON-native maps.
  @spec state_mismatches(map(), [map()]) :: [map()]
  def state_mismatches(state, entries) do
    for %{"path" => path, "equals" => expected} <- entries,
        mismatch = mismatch(dig(state, path), path, expected),
        do: mismatch
  end

  @doc false
  # The `{path, equals}` entries the end state holds.
  @spec state_matches(map(), [map()]) :: [map()]
  def state_matches(state, entries) do
    Enum.filter(entries, fn %{"path" => path, "equals" => expected} ->
      match?({:ok, value} when value == expected, dig(state, path))
    end)
  end

  defp mismatch({:ok, value}, _path, expected) when value == expected, do: nil

  defp mismatch({:ok, value}, path, expected),
    do: %{"path" => path, "expected" => expected, "actual" => value}

  defp mismatch(:missing, path, expected),
    do: %{"path" => path, "expected" => expected, "actual" => nil, "missing" => true}

  @doc false
  # The `[:nous, :eval, :sim, :turn]` events of a trace that sent a message,
  # as `{seq, turn}` in trace order: the user turn an event belongs to is
  # the last one sent before it.
  @spec sent_turns(Trace.t() | nil) :: [{non_neg_integer(), non_neg_integer()}]
  def sent_turns(%Trace{events: events}) when is_list(events) do
    for %Trace.Event{name: [:nous, :eval, :sim, :turn], metadata: meta, seq: seq} <- events,
        meta[:sent] == true,
        is_integer(meta[:turn]),
        do: {seq, meta[:turn]}
  end

  def sent_turns(_trace), do: []

  @doc false
  @spec turn_at([{non_neg_integer(), non_neg_integer()}], non_neg_integer()) ::
          non_neg_integer() | nil
  def turn_at(turns, seq) do
    turns
    |> Enum.take_while(fn {turn_seq, _turn} -> turn_seq < seq end)
    |> List.last()
    |> case do
      {_seq, turn} -> turn
      nil -> nil
    end
  end
end
