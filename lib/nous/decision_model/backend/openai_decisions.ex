defmodule Nous.DecisionModel.Backend.OpenAIDecisions do
  @moduledoc """
  HTTP backend for OpenAI's **Decisions API** (`POST /v1/decisions`), served
  by OpenAI (`gpt-6-luna`) and by vLLM.

      Nous.DecisionModel.parse("openai_decisions:gpt-6-luna")
      Nous.DecisionModel.parse("openai_decisions:Qwen/Qwen3-0.6B", base_url: "http://localhost:8000")

  ## Mapping

  | `Nous.DecisionModel.Question` | Decisions API |
  |---|---|
  | `id` | `name` (answers are matched back by `name`, in declared order) |
  | `:noul` | `predicate`; the answer's `probability` is the `noul` |
  | `:choice` criteria `[{key, desc}]` | `choices: [{value, description}]` |
  | `:score` criteria `[desc]` | `levels: [{label}]` |

  A `predicate` has no criteria field, so `:noul` criteria are appended to
  the instructions as `True if: ...` / `False if: ...` lines. A string state
  is sent as `input`; any other state is sent as its JSON text (vLLM's MVP
  accepts only text input). A `refusal` answer is an error
  (`reason: :invalid_response`): a refused check is never read as an answer.

  ## Options

    * `:base_url` - server root. Default `"https://api.openai.com"` (a
      trailing `/v1` is accepted).
    * `:api_key` - bearer token. Default: `OPENAI_API_KEY` when `base_url` is
      OpenAI's; optional for self-hosted servers.
    * `:timeout` - request timeout in ms. Default `5_000`.
    * `:allow_private_hosts` - allow a private-network `base_url` (loopback
      is always allowed).
    * `:max_state_tokens` - token budget. Default 16,384.
    * `:http_backend` - a `Nous.HTTP.Backend` module for this backend's
      requests.

  Errors map as in `Nous.DecisionModel.Backend.SystemOne`.
  """

  @behaviour Nous.DecisionModel.Backend

  alias Nous.DecisionModel
  alias Nous.DecisionModel.{Answer, Backend, OrderedObject, Question, Result, SystemOneWire}
  alias Nous.DecisionModel.Backend.HTTP, as: DecisionHTTP

  @openai_base_url "https://api.openai.com"
  @epsilon 1.0e-6

  @impl true
  def decide(%DecisionModel{opts: opts} = dm, state, questions, call_opts) do
    base = Keyword.get(opts, :base_url, @openai_base_url)
    url = DecisionHTTP.root(base) <> "/v1/decisions"

    body =
      OrderedObject.new(
        maybe_model(dm.model) ++
          [{"input", input(state)}, {"questions", Enum.map(questions, &encode_question/1)}]
      )

    with {:ok, response} <-
           DecisionHTTP.post(__MODULE__, url, body, headers(base, opts), opts, call_opts),
         {:ok, answers} <- decode_answers(response["answers"], questions) do
      {:ok,
       %Result{
         answers: answers,
         usage: SystemOneWire.usage(response["usage"]),
         backend: __MODULE__,
         model: dm.model
       }}
    end
  end

  @impl true
  def max_state_tokens(_dm), do: 16_384

  defp maybe_model(nil), do: []
  defp maybe_model(model), do: [{"model", model}]

  defp headers(base, opts) do
    key =
      Keyword.get(opts, :api_key) ||
        if DecisionHTTP.root(base) == @openai_base_url, do: System.get_env("OPENAI_API_KEY")

    if is_binary(key) and key != "", do: [{"authorization", "Bearer " <> key}], else: []
  end

  defp input(state) when is_binary(state), do: state
  defp input(state), do: JSON.encode!(state)

  # --- request ---

  defp encode_question(%Question{} = question) do
    OrderedObject.new(
      [
        {"type", wire_type(question.type)},
        {"name", Question.key_string(question.id)}
      ] ++ instructions(question) ++ options(question)
    )
  end

  defp wire_type(:noul), do: "predicate"
  defp wire_type(:choice), do: "choice"
  defp wire_type(:score), do: "score"

  defp instructions(%Question{type: :noul, criteria: [_ | _] = criteria} = question) do
    lines =
      Enum.flat_map(criteria, fn
        {_key, nil} -> []
        {"true", desc} -> ["True if: " <> desc]
        {"false", desc} -> ["False if: " <> desc]
      end)

    case {instruction_text(question.instructions), lines} do
      {text, []} -> maybe_instructions(text)
      {nil, lines} -> [{"instructions", Enum.join(lines, "\n")}]
      {text, lines} -> [{"instructions", Enum.join([text | lines], "\n")}]
    end
  end

  defp instructions(%Question{instructions: instructions}),
    do: maybe_instructions(instruction_text(instructions))

  defp maybe_instructions(nil), do: []
  defp maybe_instructions(text), do: [{"instructions", text}]

  defp instruction_text(nil), do: nil
  defp instruction_text(text) when is_binary(text), do: text
  defp instruction_text(term), do: JSON.encode!(term)

  defp options(%Question{type: :choice, criteria: options}) do
    choices =
      Enum.map(options, fn
        {key, nil} ->
          OrderedObject.new([{"value", Question.key_string(key)}])

        {key, desc} ->
          OrderedObject.new([{"value", Question.key_string(key)}, {"description", desc}])
      end)

    [{"choices", choices}]
  end

  defp options(%Question{type: :score, criteria: levels}) do
    [{"levels", Enum.map(levels, &OrderedObject.new([{"label", &1}]))}]
  end

  defp options(%Question{type: :noul}), do: []

  # --- response ---

  defp decode_answers(answers, questions) when is_list(answers) do
    with {:ok, by_name} <- index_by_name(answers, questions) do
      collect(questions, fn question ->
        case Map.fetch(by_name, Question.key_string(question.id)) do
          {:ok, raw} ->
            with {:ok, answer} <- decode_answer(question, raw), do: {:ok, {question.id, answer}}

          :error ->
            invalid("no answer for #{inspect(question.id)}")
        end
      end)
    end
  end

  defp decode_answers(answers, _questions) do
    invalid("answers is not an array: #{inspect(answers)}")
  end

  defp index_by_name(answers, questions) do
    declared = MapSet.new(questions, &Question.key_string(&1.id))

    Enum.reduce_while(answers, {:ok, %{}}, fn
      %{"name" => name} = raw, {:ok, acc} when is_binary(name) ->
        cond do
          not MapSet.member?(declared, name) ->
            {:halt, unknown("answer for undeclared question #{inspect(name)}")}

          Map.has_key?(acc, name) ->
            {:halt, invalid("duplicate answer for #{inspect(name)}")}

          true ->
            {:cont, {:ok, Map.put(acc, name, raw)}}
        end

      raw, _acc ->
        {:halt, invalid("answer without a name: #{inspect(raw)}")}
    end)
  end

  defp decode_answer(question, %{"type" => "refusal"}) do
    invalid("the model refused to answer #{inspect(question.id)}")
  end

  defp decode_answer(%Question{type: :noul} = question, %{"type" => "predicate"} = raw) do
    with {:ok, p} <- probability(question, raw["probability"]),
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

  defp decode_answer(
         %Question{type: :choice, criteria: options} = question,
         %{"type" => "choice"} = raw
       ) do
    keys = Map.new(options, fn {key, _} -> {Question.key_string(key), key} end)

    with {:ok, choice} <- declared(question, keys, raw["choice"]),
         {:ok, by_value} <-
           distribution(question, raw["probabilities"], "value", &Map.fetch(keys, &1)),
         {:ok, probabilities} <- ordered(question, Enum.map(options, &elem(&1, 0)), by_value),
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

  defp decode_answer(
         %Question{type: :score, criteria: levels} = question,
         %{"type" => "score"} = raw
       ) do
    n = length(levels)

    level = fn value ->
      if is_integer(value) and value in 0..(n - 1), do: {:ok, value}, else: :error
    end

    with {:ok, score} <- score(question, raw["score"], n),
         {:ok, by_index} <- distribution(question, raw["probabilities"], "value", level),
         {:ok, probabilities} <- ordered(question, Enum.to_list(0..(n - 1)), by_index),
         {:ok, confidence} <- optional_probability(question, raw["confidence"]) do
      {:ok,
       %Answer{type: :score, score: score, probabilities: probabilities, confidence: confidence}}
    end
  end

  defp decode_answer(question, raw) do
    invalid(
      "#{inspect(question.id)}: unexpected #{inspect(raw["type"])} answer for a #{question.type}"
    )
  end

  defp declared(question, keys, value) when is_binary(value) do
    case Map.fetch(keys, value) do
      {:ok, key} -> {:ok, key}
      :error -> unknown("#{inspect(question.id)}: undeclared choice #{inspect(value)}")
    end
  end

  defp declared(question, _keys, value),
    do: invalid("#{inspect(question.id)}: invalid choice #{inspect(value)}")

  # `[{"value": v, "probability": p}]` -> %{declared_key => p}
  defp distribution(question, entries, field, resolve) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      %{^field => value, "probability" => p}, {:ok, acc} ->
        with {:ok, key} <- resolve.(value),
             {:ok, p} <- probability(question, p) do
          {:cont, {:ok, Map.put(acc, key, p)}}
        else
          :error ->
            {:halt, unknown("#{inspect(question.id)}: undeclared label #{inspect(value)}")}

          error ->
            {:halt, error}
        end

      entry, _acc ->
        {:halt, invalid("#{inspect(question.id)}: malformed probability #{inspect(entry)}")}
    end)
  end

  defp distribution(question, entries, _field, _resolve),
    do: invalid("#{inspect(question.id)}: invalid probabilities #{inspect(entries)}")

  defp ordered(question, keys, by_key) do
    collect(keys, fn key ->
      case Map.fetch(by_key, key) do
        {:ok, p} -> {:ok, {key, p}}
        :error -> invalid("#{inspect(question.id)}: no probability for #{inspect(key)}")
      end
    end)
  end

  defp score(_question, score, n)
       when is_number(score) and score >= -@epsilon and score <= n - 1 + @epsilon,
       do: {:ok, score / 1}

  defp score(question, score, _n),
    do: invalid("#{inspect(question.id)}: invalid score #{inspect(score)}")

  defp probability(_question, p) when is_number(p) and p >= -@epsilon and p <= 1 + @epsilon,
    do: {:ok, p / 1}

  defp probability(question, p),
    do: invalid("#{inspect(question.id)}: invalid probability #{inspect(p)}")

  defp optional_probability(_question, nil), do: {:ok, nil}
  defp optional_probability(question, p), do: probability(question, p)

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
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

  defp invalid(message), do: {:error, Backend.error(__MODULE__, :invalid_response, message)}
  defp unknown(message), do: {:error, Backend.error(__MODULE__, :unknown_label, message)}
end
