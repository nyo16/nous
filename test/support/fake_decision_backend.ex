defmodule Nous.Test.FakeDecisionBackend do
  @moduledoc false
  # A scripted `Nous.DecisionModel.Backend` for request-path tests of
  # `:decision` hooks. `model(script, opts)` builds a decision model whose
  # `script.(state)` (or `script.(state, questions)`) answers every call:
  #
  #   * a number `p` - every `:noul` question answers P(true) = p; every
  #     `:choice` question puts p on its last option and 1 - p on its first
  #   * `%{id => answer}` - per question: a number as above, or for a
  #     `:choice` an ordered `[{option, p}]` list
  #   * `{:sleep, ms, answer}` - sleeps, then answers `answer`
  #   * `{:error, reason}` - a `Nous.Errors.DecisionModelError`
  #
  # With `test_pid:`, every call sends `{:decision_state, state}` there (and
  # `{:decision_call, state, questions}` with `report_questions: true`).
  # `max_state_tokens:` (a `Nous.DecisionModel` option) shrinks the window.

  @behaviour Nous.DecisionModel.Backend

  alias Nous.DecisionModel
  alias Nous.DecisionModel.{Answer, Backend, Result}

  def model(script, opts \\ []) when is_function(script, 1) or is_function(script, 2) do
    DecisionModel.new(__MODULE__, [model: "fake", script: script] ++ opts)
  end

  @impl true
  def decide(dm, state, questions, _opts) do
    if pid = dm.opts[:test_pid] do
      send(pid, {:decision_state, state})
      if dm.opts[:report_questions], do: send(pid, {:decision_call, state, questions})
    end

    script = dm.opts[:script]

    reply =
      if is_function(script, 2), do: script.(state, questions), else: script.(state)

    answer(reply, questions)
  end

  defp answer({:sleep, ms, answer}, questions) do
    Process.sleep(ms)
    answer(answer, questions)
  end

  defp answer({:error, reason}, _questions),
    do: {:error, Backend.error(__MODULE__, reason, "scripted failure")}

  defp answer(p, questions) when is_number(p),
    do: answer(Map.new(questions, &{&1.id, p}), questions)

  defp answer(probs, questions) when is_map(probs) do
    answers = Enum.map(questions, &{&1.id, question_answer(&1, Map.fetch!(probs, &1.id))})
    {:ok, %Result{answers: answers, usage: %{input_tokens: 1, output_tokens: 0}}}
  end

  defp question_answer(%{type: :noul}, p) when is_number(p),
    do: %Answer{type: :noul, noul: p, probabilities: [{"true", p}, {"false", 1 - p}]}

  defp question_answer(%{type: :choice, criteria: criteria} = q, p) when is_number(p) do
    options = Enum.map(criteria, fn {option, _} -> option end)
    first = hd(options)
    last = List.last(options)

    question_answer(
      q,
      Enum.map(options, fn
        ^last -> {last, p}
        ^first -> {first, 1 - p}
        option -> {option, 0.0}
      end)
    )
  end

  defp question_answer(%{type: :choice}, probabilities) when is_list(probabilities) do
    {choice, _} = Enum.max_by(probabilities, fn {_, p} -> p end)
    %Answer{type: :choice, choice: choice, probabilities: probabilities}
  end
end
