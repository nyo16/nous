defmodule Nous.DecisionModel.SystemOneWire do
  @moduledoc false

  # The System One request/answer shape, shared by the HTTP SystemOne backend
  # and the in-process LlamaCpp backend (llama_cpp_ex ports llama-server's
  # `/v1/systemone`: same request, same answers).
  #
  # Answers are mapped back through the declared ids and option keys only. A
  # string from the response is compared against `Question.key_string/1` of the
  # declared keys; it is never turned into an atom.

  alias Nous.DecisionModel.{Answer, Backend, OrderedObject, Question}

  @epsilon 1.0e-6

  @doc false
  # `questions` as an ordered JSON object: id => {type, instructions, criteria}.
  @spec encode_questions([Question.t()]) :: OrderedObject.t()
  def encode_questions(questions) do
    OrderedObject.new(
      Enum.map(questions, fn question ->
        {Question.key_string(question.id), OrderedObject.new(question_fields(question))}
      end)
    )
  end

  defp question_fields(%Question{} = question) do
    [{"type", Atom.to_string(question.type)}]
    |> maybe_add("instructions", question.instructions)
    |> maybe_add("criteria", encode_criteria(question))
  end

  defp maybe_add(fields, _key, nil), do: fields
  defp maybe_add(fields, key, value), do: fields ++ [{key, value}]

  defp encode_criteria(%Question{type: :score, criteria: levels}), do: levels
  defp encode_criteria(%Question{criteria: nil}), do: nil

  defp encode_criteria(%Question{criteria: pairs}) do
    OrderedObject.new(Enum.map(pairs, fn {key, desc} -> {Question.key_string(key), desc} end))
  end

  @doc false
  # Decodes a System One `answers` object (string keys, as JSON decodes it)
  # into `[{declared_id, %Answer{}}]` in question order.
  @spec decode_answers(term(), [Question.t()], module()) ::
          {:ok, [{Question.id(), Answer.t()}]} | {:error, Nous.Errors.DecisionModelError.t()}
  def decode_answers(answers, questions, backend) when is_map(answers) do
    declared = MapSet.new(questions, &Question.key_string(&1.id))

    case Enum.find(Map.keys(answers), &(not MapSet.member?(declared, &1))) do
      nil ->
        decode_in_order(answers, questions, backend)

      unknown ->
        {:error,
         Backend.error(
           backend,
           :unknown_label,
           "answer for undeclared question #{inspect(unknown)}"
         )}
    end
  end

  def decode_answers(answers, _questions, backend) do
    {:error,
     Backend.error(backend, :invalid_response, "answers is not an object: #{inspect(answers)}")}
  end

  defp decode_in_order(answers, questions, backend) do
    Enum.reduce_while(questions, {:ok, []}, fn question, {:ok, acc} ->
      case Map.fetch(answers, Question.key_string(question.id)) do
        {:ok, raw} ->
          case decode_answer(question, raw) do
            {:ok, answer} ->
              {:cont, {:ok, [{question.id, answer} | acc]}}

            {:error, reason, message} ->
              {:halt, {:error, Backend.error(backend, reason, message)}}
          end

        :error ->
          {:halt,
           {:error,
            Backend.error(backend, :invalid_response, "no answer for #{inspect(question.id)}")}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp decode_answer(%Question{type: type} = question, %{"type" => wire_type} = raw)
       when is_binary(wire_type) do
    if wire_type == Atom.to_string(type) do
      do_decode(question, raw)
    else
      {:error, :invalid_response,
       "#{inspect(question.id)}: expected a #{type} answer, got #{inspect(wire_type)}"}
    end
  end

  defp decode_answer(question, raw) do
    {:error, :invalid_response, "#{inspect(question.id)}: malformed answer #{inspect(raw)}"}
  end

  defp do_decode(%Question{type: :noul} = question, raw) do
    with {:ok, p} <- probability(question, raw["noul"]),
         {:ok, confidence} <- optional_probability(question, raw["confidence"]) do
      {:ok,
       %Answer{
         type: :noul,
         noul: p,
         probabilities: [{"true", p}, {"false", 1.0 - p}],
         confidence: confidence
       }}
    end
  end

  defp do_decode(%Question{type: :choice, criteria: options} = question, raw) do
    keys = Map.new(options, fn {key, _} -> {Question.key_string(key), key} end)

    with {:ok, choice} <- declared_option(question, keys, raw["choice"]),
         {:ok, probabilities} <-
           choice_probabilities(question, keys, options, raw["probabilities"]),
         {:ok, confidence} <- optional_probability(question, raw["confidence"]) do
      {:ok,
       %Answer{
         type: :choice,
         choice: choice,
         probabilities: probabilities,
         confidence: confidence
       }}
    end
  end

  defp do_decode(%Question{type: :score, criteria: levels} = question, raw) do
    with {:ok, score} <- score_value(question, raw["score"], length(levels)),
         {:ok, probabilities} <-
           score_probabilities(question, length(levels), raw["probabilities"]),
         {:ok, confidence} <- optional_probability(question, raw["confidence"]) do
      {:ok,
       %Answer{type: :score, score: score, probabilities: probabilities, confidence: confidence}}
    end
  end

  defp declared_option(question, keys, label) when is_binary(label) do
    case Map.fetch(keys, label) do
      {:ok, key} -> {:ok, key}
      :error -> unknown_label(question, label)
    end
  end

  defp declared_option(question, _keys, label) do
    {:error, :invalid_response, "#{inspect(question.id)}: invalid choice #{inspect(label)}"}
  end

  defp choice_probabilities(question, keys, options, probs) when is_map(probs) do
    with :ok <- all_declared(question, Map.keys(probs), &Map.has_key?(keys, &1)) do
      collect(options, fn {key, _} ->
        with {:ok, p} <- fetch_probability(question, probs, Question.key_string(key)) do
          {:ok, {key, p}}
        end
      end)
    end
  end

  defp choice_probabilities(question, _keys, _options, probs) do
    {:error, :invalid_response,
     "#{inspect(question.id)}: invalid probabilities #{inspect(probs)}"}
  end

  defp score_probabilities(question, n_levels, probs) when is_map(probs) do
    parsed = Enum.map(probs, fn {level, p} -> {level_index(level), level, p} end)

    case Enum.find(parsed, fn {index, _, _} -> index == nil or index >= n_levels end) do
      nil ->
        by_index = Map.new(parsed, fn {index, _, p} -> {index, p} end)

        collect(0..(n_levels - 1), fn index ->
          with {:ok, p} <- fetch_probability(question, by_index, index), do: {:ok, {index, p}}
        end)

      {_, level, _} ->
        unknown_label(question, level)
    end
  end

  defp score_probabilities(question, _n, probs) do
    {:error, :invalid_response,
     "#{inspect(question.id)}: invalid probabilities #{inspect(probs)}"}
  end

  defp level_index(level) when is_integer(level) and level >= 0, do: level

  defp level_index(level) when is_binary(level) do
    case Integer.parse(level) do
      {index, ""} when index >= 0 -> index
      _ -> nil
    end
  end

  defp level_index(_), do: nil

  defp score_value(_question, score, n_levels)
       when is_number(score) and score >= -@epsilon and score <= n_levels - 1 + @epsilon,
       do: {:ok, score / 1}

  defp score_value(question, score, _n) do
    {:error, :invalid_response, "#{inspect(question.id)}: invalid score #{inspect(score)}"}
  end

  defp all_declared(question, labels, declared?) do
    case Enum.find(labels, &(not declared?.(&1))) do
      nil -> :ok
      label -> unknown_label(question, label)
    end
  end

  defp fetch_probability(question, probs, key) do
    case Map.fetch(probs, key) do
      {:ok, p} ->
        probability(question, p)

      :error ->
        {:error, :invalid_response, "#{inspect(question.id)}: no probability for #{inspect(key)}"}
    end
  end

  defp probability(_question, p) when is_number(p) and p >= -@epsilon and p <= 1 + @epsilon,
    do: {:ok, p / 1}

  defp probability(question, p) do
    {:error, :invalid_response, "#{inspect(question.id)}: invalid probability #{inspect(p)}"}
  end

  defp optional_probability(_question, nil), do: {:ok, nil}
  defp optional_probability(question, p), do: probability(question, p)

  defp unknown_label(question, label) do
    {:error, :unknown_label, "#{inspect(question.id)}: undeclared label #{inspect(label)}"}
  end

  defp collect(enum, fun) do
    Enum.reduce_while(enum, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc false
  # Usage from a System One / Decisions response body.
  @spec usage(term()) :: Nous.DecisionModel.Result.usage()
  def usage(%{} = usage) do
    %{
      input_tokens: non_neg_integer(usage["input_tokens"]),
      output_tokens: non_neg_integer(usage["output_tokens"])
    }
  end

  def usage(_), do: %{input_tokens: nil, output_tokens: nil}

  defp non_neg_integer(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_integer(_), do: nil
end
