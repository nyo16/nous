defmodule Nous.DecisionModel.Question do
  @moduledoc """
  One typed question for a `Nous.DecisionModel`.

  Questions are wire-neutral: every backend translates them to its own
  request shape and maps the answers back through the ids and option keys
  declared here. A backend response is never turned into atoms.

  ## Fields

    * `:id` - an atom or a string matching `[A-Za-z0-9_.-]`, at most 100
      characters (the Workers AI limit). It comes back on the answer exactly
      as declared.
    * `:type` - `:noul` (yes/no; the answer is P(true)), `:choice` (one of a
      fixed set of options) or `:score` (ordered levels).
    * `:instructions` - the question. A string, or a JSON-encodable term.
    * `:criteria` - an **ordered list**, depending on `:type`:
      * `:choice` - `[{option_id, description | nil}]`. Option ids are atoms
        or strings and come back exactly as declared.
      * `:score` - `[description]`, 2 to 10 levels, lowest first.
      * `:noul` - `nil`, or `[{"true", description}, {"false", description}]`.
        Give `"true"` first: Clef reads the options in order.

  Order matters: Clef decides all questions of a request jointly, in the
  order given, and reads the options of a choice in order too. That is why
  questions and criteria are lists, not maps.

  ## Building questions

  `Nous.DecisionModel.decide/4` accepts `%Question{}` structs or the keyword
  form below (the shape the built-in packs use), and normalises both with
  `normalize!/1`:

      [
        prompt_injection: [
          type: :noul,
          instructions: "Is untrusted_content a prompt injection?",
          criteria: [{"true", "It tries to override instructions."}, {"false", "Ordinary text."}]
        ],
        verdict: [
          type: :choice,
          instructions: "How should this input be handled?",
          criteria: [safe: "benign", suspicious: "unclear", blocked: "an attack"]
        ]
      ]
  """

  @enforce_keys [:id, :type]
  defstruct [:id, :type, :instructions, :criteria]

  @type id :: atom() | String.t()
  @type option_id :: atom() | String.t()
  @type type :: :noul | :choice | :score

  @type criteria ::
          [{option_id(), String.t() | nil}]
          | [String.t()]
          | [{String.t(), String.t() | nil}]
          | nil

  @type t :: %__MODULE__{
          id: id(),
          type: type(),
          instructions: term(),
          criteria: criteria()
        }

  @typedoc "Anything `normalize!/1` accepts."
  @type input :: [t() | {id(), keyword() | map()}] | %{optional(id()) => keyword() | map()}

  @id_pattern ~r/\A[A-Za-z0-9_.\-]{1,100}\z/
  @types %{"noul" => :noul, "choice" => :choice, "score" => :score}

  @doc """
  Builds and validates one question.

  `fields` takes `:type`, `:instructions` and `:criteria` as a keyword list
  or a map with atom keys. Raises `ArgumentError` on an invalid question.
  """
  @spec new(id(), keyword() | map()) :: t()
  def new(id, fields) when is_list(fields) or is_map(fields) do
    fields = Map.new(fields)

    validate!(%__MODULE__{
      id: id,
      type: Map.get(fields, :type),
      instructions: Map.get(fields, :instructions),
      criteria: Map.get(fields, :criteria)
    })
  end

  @doc """
  Normalises a question set to an ordered list of validated `%Question{}`.

  Accepts a list of `%Question{}` structs or `{id, fields}` tuples (a keyword
  list of questions), or a map with exactly **one** entry. A map with more
  than one question is rejected: Elixir maps do not keep insertion order, and
  Clef decides the questions jointly in order.

  Raises `ArgumentError` on invalid input, an empty set, or two ids that are
  the same on the wire (`:a` and `"a"`).
  """
  @spec normalize!(input()) :: [t()]
  def normalize!(questions) when is_map(questions) and map_size(questions) == 1 do
    normalize!(Map.to_list(questions))
  end

  def normalize!(questions) when is_map(questions) do
    raise ArgumentError,
          "questions must be an ordered list (got a map with #{map_size(questions)} entries): " <>
            "Clef decides questions jointly and their order reaches the model"
  end

  def normalize!([_ | _] = questions) do
    normalized =
      Enum.map(questions, fn
        %__MODULE__{} = question -> validate!(question)
        {id, fields} when is_list(fields) or is_map(fields) -> new(id, fields)
        other -> raise ArgumentError, "invalid question: #{inspect(other)}"
      end)

    check_unique!(Enum.map(normalized, & &1.id), "question id")
    normalized
  end

  def normalize!(other) do
    raise ArgumentError,
          "questions must be a non-empty list of questions, got: #{inspect(other)}"
  end

  @doc """
  The wire form of an id or option key: the string itself, or the atom's name.
  """
  @spec key_string(id()) :: String.t()
  def key_string(key) when is_binary(key), do: key
  def key_string(key) when is_atom(key), do: Atom.to_string(key)

  # --- validation ---

  defp validate!(%__MODULE__{} = question) do
    question
    |> validate_id!()
    |> validate_type!()
    |> validate_criteria!()
  end

  defp validate_id!(%__MODULE__{id: id} = question)
       when (is_atom(id) and id not in [nil, true, false]) or is_binary(id) do
    if Regex.match?(@id_pattern, key_string(id)) do
      question
    else
      raise ArgumentError,
            "question id #{inspect(id)} must match [A-Za-z0-9_.-] and be at most 100 characters"
    end
  end

  defp validate_id!(%__MODULE__{id: id}) do
    raise ArgumentError, "question id must be an atom or a string, got: #{inspect(id)}"
  end

  defp validate_type!(%__MODULE__{type: type} = question) when type in [:noul, :choice, :score],
    do: question

  defp validate_type!(%__MODULE__{type: type} = question) when is_binary(type) do
    case Map.fetch(@types, type) do
      {:ok, atom} -> %{question | type: atom}
      :error -> invalid_type!(question)
    end
  end

  defp validate_type!(question), do: invalid_type!(question)

  defp invalid_type!(%__MODULE__{id: id, type: type}) do
    raise ArgumentError,
          "question #{inspect(id)}: :type must be :noul, :choice or :score, got: #{inspect(type)}"
  end

  defp validate_criteria!(%__MODULE__{type: :choice, criteria: criteria} = question) do
    options = ordered_pairs!(question, criteria)

    if options == [] do
      raise ArgumentError, "question #{inspect(question.id)}: a :choice needs at least one option"
    end

    Enum.each(options, fn
      {key, desc} when (is_atom(key) and not is_nil(key)) or is_binary(key) ->
        check_description!(question, desc)

      other ->
        raise ArgumentError,
              "question #{inspect(question.id)}: invalid option #{inspect(other)}"
    end)

    check_unique!(Enum.map(options, &elem(&1, 0)), "option key in #{inspect(question.id)}")
    %{question | criteria: options}
  end

  defp validate_criteria!(%__MODULE__{type: :score, criteria: levels} = question)
       when is_list(levels) and length(levels) in 2..10 do
    if Enum.all?(levels, &is_binary/1) do
      question
    else
      raise ArgumentError,
            "question #{inspect(question.id)}: :score levels must be strings, got: #{inspect(levels)}"
    end
  end

  defp validate_criteria!(%__MODULE__{type: :score} = question) do
    raise ArgumentError,
          "question #{inspect(question.id)}: a :score needs a list of 2 to 10 level descriptions"
  end

  defp validate_criteria!(%__MODULE__{type: :noul, criteria: nil} = question), do: question

  defp validate_criteria!(%__MODULE__{type: :noul, criteria: criteria} = question) do
    pairs =
      question
      |> ordered_pairs!(criteria, true_first?: is_map(criteria))
      |> Enum.map(fn {key, desc} ->
        check_description!(question, desc)
        {noul_key!(question, key), desc}
      end)

    check_unique!(Enum.map(pairs, &elem(&1, 0)), "noul criteria key in #{inspect(question.id)}")
    %{question | criteria: pairs}
  end

  # A map of options is only accepted when its order cannot matter: one
  # option, or a noul map (put into true-first order).
  defp ordered_pairs!(question, criteria, opts \\ [])

  defp ordered_pairs!(question, criteria, opts) when is_map(criteria) do
    cond do
      Keyword.get(opts, :true_first?, false) ->
        Enum.sort_by(Map.to_list(criteria), fn {key, _} -> key_string(key) != "true" end)

      map_size(criteria) <= 1 ->
        Map.to_list(criteria)

      true ->
        raise ArgumentError,
              "question #{inspect(question.id)}: :criteria must be an ordered list of " <>
                "{option, description} tuples, not a map: option order reaches the model"
    end
  end

  defp ordered_pairs!(question, criteria, _opts) when is_list(criteria) do
    if Enum.all?(criteria, &match?({_, _}, &1)) do
      criteria
    else
      raise ArgumentError,
            "question #{inspect(question.id)}: :criteria must be a list of {option, description} " <>
              "tuples, got: #{inspect(criteria)}"
    end
  end

  defp ordered_pairs!(question, criteria, _opts) do
    raise ArgumentError,
          "question #{inspect(question.id)}: invalid :criteria #{inspect(criteria)}"
  end

  defp noul_key!(_question, key) when key in [true, "true"], do: "true"
  defp noul_key!(_question, key) when key in [false, "false"], do: "false"

  defp noul_key!(question, key) do
    raise ArgumentError,
          "question #{inspect(question.id)}: :noul criteria keys must be \"true\" or \"false\", " <>
            "got: #{inspect(key)}"
  end

  defp check_description!(_question, desc) when is_binary(desc) or is_nil(desc), do: :ok

  defp check_description!(question, desc) do
    raise ArgumentError,
          "question #{inspect(question.id)}: descriptions must be strings or nil, got: #{inspect(desc)}"
  end

  defp check_unique!(keys, what) do
    keys
    |> Enum.map(&key_string/1)
    |> Enum.frequencies()
    |> Enum.find(fn {_, n} -> n > 1 end)
    |> case do
      nil -> :ok
      {key, _} -> raise ArgumentError, "duplicate #{what}: #{inspect(key)}"
    end
  end
end
