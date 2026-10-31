defmodule Nous.DecisionModel.Result do
  @moduledoc """
  The result of `Nous.DecisionModel.decide/4`.

  ## Fields

    * `:answers` - `[{question_id, Nous.DecisionModel.Answer.t()}]`, in the
      order the questions were given, keyed by the ids exactly as declared.
    * `:usage` - `%{input_tokens: integer | nil, output_tokens: integer | nil}`
      as the backend reports it.
    * `:backend` - the `Nous.DecisionModel.Backend` module that answered.
    * `:model` - the model reference of the `Nous.DecisionModel`.
  """

  alias Nous.DecisionModel.Answer

  @enforce_keys [:answers]
  defstruct answers: [], usage: %{input_tokens: nil, output_tokens: nil}, backend: nil, model: nil

  @type usage :: %{input_tokens: non_neg_integer() | nil, output_tokens: non_neg_integer() | nil}

  @type t :: %__MODULE__{
          answers: [{Nous.DecisionModel.Question.id(), Answer.t()}],
          usage: usage(),
          backend: module() | nil,
          model: String.t() | nil
        }

  @doc """
  Fetches the answer for `id`, compared exactly as declared (`:a` is not `"a"`).
  """
  @spec fetch(t(), Nous.DecisionModel.Question.id()) :: {:ok, Answer.t()} | :error
  def fetch(%__MODULE__{answers: answers}, id) do
    case List.keyfind(answers, id, 0) do
      {^id, answer} -> {:ok, answer}
      nil -> :error
    end
  end
end
