defmodule Nous.Test.FakeDecisionBackend do
  @moduledoc false
  # A scripted `Nous.DecisionModel.Backend` for request-path tests of
  # `:decision` hooks. `model(script, opts)` builds a decision model whose
  # `script.(state)` answers every call:
  #
  #   * a number `p` - every `:noul` question answers P(true) = p
  #   * `%{id => p}` - per question
  #   * `{:sleep, ms, answer}` - sleeps, then answers `answer`
  #   * `{:error, reason}` - a `Nous.Errors.DecisionModelError`
  #
  # With `test_pid:`, every call sends `{:decision_state, state}` there.
  # `max_state_tokens:` (a `Nous.DecisionModel` option) shrinks the window.

  @behaviour Nous.DecisionModel.Backend

  alias Nous.DecisionModel
  alias Nous.DecisionModel.{Answer, Backend, Result}

  def model(script, opts \\ []) when is_function(script, 1) do
    DecisionModel.new(__MODULE__, [model: "fake", script: script] ++ opts)
  end

  @impl true
  def decide(dm, state, questions, _opts) do
    if pid = dm.opts[:test_pid], do: send(pid, {:decision_state, state})
    answer(dm.opts[:script].(state), questions)
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
    answers =
      Enum.map(questions, fn %{id: id, type: :noul} ->
        p = Map.fetch!(probs, id)
        {id, %Answer{type: :noul, noul: p, probabilities: [{"true", p}, {"false", 1 - p}]}}
      end)

    {:ok, %Result{answers: answers, usage: %{input_tokens: 1, output_tokens: 0}}}
  end
end
