defmodule Nous.Eval.Scorers.Judge.Scale do
  @moduledoc false
  # The declared verdict scale of `Nous.Eval.Scorers.Judge`: the closed set of
  # labels the judge may answer with and the normalized value of each.
  #
  # Accepted forms (Elixir / dataset file):
  #
  #   :binary                                  "binary"
  #   :ternary | {:ternary, partial: 0.4}      "ternary" | %{"ternary" => %{"partial" => 0.4}}
  #   {:likert, 1, 5}                          %{"likert" => %{"min" => 1, "max" => 5}}
  #   {:likert, 1, 5, labels: %{1 => "..."}}   %{"likert" => %{"min" => 1, "max" => 5, "labels" => %{"1" => "..."}}}
  #   {:choices, %{"A" => 1.0, "B" => 0.0}}    %{"choices" => %{"A" => 1.0, "B" => 0.0}}
  #
  # Labels are strings; nothing here creates an atom.

  @type kind :: :binary | :ternary | :likert | :choices

  @type t :: %__MODULE__{
          kind: kind(),
          labels: [String.t()],
          values: %{String.t() => float()},
          definitions: %{String.t() => String.t()},
          partial: float() | nil,
          min: integer() | nil,
          max: integer() | nil
        }

  @enforce_keys [:kind, :labels, :values]
  defstruct [:kind, :labels, :values, :partial, :min, :max, definitions: %{}]

  # Likert scales wider than this are almost certainly a typo, and a label
  # list that long makes a poor closed set.
  @max_likert_points 11

  @doc false
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(scale) when scale in [:binary, "binary"], do: {:ok, binary()}
  def parse(scale) when scale in [:ternary, "ternary"], do: ternary(0.5)

  def parse({:ternary, opts}) when is_list(opts) do
    case Keyword.keys(opts) -- [:partial] do
      [] -> ternary(Keyword.get(opts, :partial, 0.5))
      unknown -> {:error, "ternary scale: unknown options #{inspect(unknown)}"}
    end
  end

  def parse(%{"ternary" => opts}) when is_map(opts) do
    case Map.keys(opts) -- ["partial"] do
      [] -> ternary(Map.get(opts, "partial", 0.5))
      unknown -> {:error, "ternary scale: unknown keys #{inspect(unknown)}"}
    end
  end

  def parse({:likert, min, max}), do: likert(min, max, %{})

  def parse({:likert, min, max, opts}) when is_list(opts) do
    case Keyword.keys(opts) -- [:labels] do
      [] -> likert(min, max, Keyword.get(opts, :labels, %{}))
      unknown -> {:error, "likert scale: unknown options #{inspect(unknown)}"}
    end
  end

  def parse(%{"likert" => %{} = opts}) do
    case Map.keys(opts) -- ["min", "max", "labels"] do
      [] -> likert(Map.get(opts, "min"), Map.get(opts, "max"), Map.get(opts, "labels", %{}))
      unknown -> {:error, "likert scale: unknown keys #{inspect(unknown)}"}
    end
  end

  def parse({:choices, choices}), do: choices(choices)
  def parse(%{"choices" => choices}), do: choices(choices)

  def parse(other) do
    {:error,
     "scale must be :binary, :ternary, {:ternary, partial: p}, {:likert, min, max} " <>
       "(with optional labels:) or {:choices, %{label => value}}, got #{inspect(other)}"}
  end

  defp binary do
    %__MODULE__{
      kind: :binary,
      labels: ["pass", "fail"],
      values: %{"pass" => 1.0, "fail" => 0.0},
      definitions: %{
        "pass" => "the answer meets the criteria",
        "fail" => "the answer does not meet the criteria"
      }
    }
  end

  defp ternary(partial) when is_number(partial) and partial > 0 and partial < 1 do
    {:ok,
     %__MODULE__{
       kind: :ternary,
       labels: ["pass", "partial", "fail"],
       values: %{"pass" => 1.0, "partial" => partial / 1, "fail" => 0.0},
       partial: partial / 1,
       definitions: %{
         "pass" => "the answer fully meets the criteria",
         "partial" => "the answer meets some of the criteria but not all",
         "fail" => "the answer does not meet the criteria"
       }
     }}
  end

  defp ternary(other),
    do:
      {:error,
       "ternary scale: partial must be a number strictly between 0 and 1, got #{inspect(other)}"}

  defp likert(min, max, labels)
       when is_integer(min) and is_integer(max) and min < max and
              max - min + 1 <= @max_likert_points do
    points = Enum.to_list(min..max)

    with {:ok, definitions} <- likert_definitions(labels, min, max) do
      {:ok,
       %__MODULE__{
         kind: :likert,
         labels: Enum.map(points, &Integer.to_string/1),
         values: Map.new(points, &{Integer.to_string(&1), (&1 - min) / (max - min)}),
         definitions: definitions,
         min: min,
         max: max
       }}
    end
  end

  defp likert(min, max, _labels) do
    {:error,
     "likert scale: min and max must be integers with min < max and at most " <>
       "#{@max_likert_points} points, got #{inspect(min)}..#{inspect(max)}"}
  end

  defp likert_definitions(labels, min, max) when is_map(labels) do
    Enum.reduce_while(labels, {:ok, %{}}, fn {point, text}, {:ok, acc} ->
      with {:ok, point} <- likert_point(point, min, max),
           true <- is_binary(text) and text != "" do
        {:cont, {:ok, Map.put(acc, Integer.to_string(point), text)}}
      else
        false ->
          {:halt,
           {:error, "likert scale: the label of #{inspect(point)} must be a non-empty string"}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp likert_definitions(other, _min, _max),
    do: {:error, "likert scale: labels must be a map of point => text, got #{inspect(other)}"}

  defp likert_point(point, min, max) when is_integer(point) and point >= min and point <= max,
    do: {:ok, point}

  defp likert_point(point, min, max) when is_binary(point) do
    case Integer.parse(point) do
      {int, ""} -> likert_point(int, min, max)
      _ -> {:error, "likert scale: label key #{inspect(point)} is not a point of #{min}..#{max}"}
    end
  end

  defp likert_point(point, min, max),
    do: {:error, "likert scale: label key #{inspect(point)} is not a point of #{min}..#{max}"}

  defp choices(%{} = choices) when map_size(choices) >= 2 do
    valid? =
      Enum.all?(choices, fn {label, value} ->
        is_binary(label) and String.trim(label) == label and label != "" and is_number(value) and
          value >= 0 and value <= 1
      end)

    if valid? do
      values = Map.new(choices, fn {label, value} -> {label, value / 1} end)

      labels =
        values |> Enum.sort_by(fn {label, value} -> {-value, label} end) |> Enum.map(&elem(&1, 0))

      {:ok, %__MODULE__{kind: :choices, labels: labels, values: values}}
    else
      {:error,
       "choices scale: labels must be non-empty strings without surrounding whitespace " <>
         "and values numbers in 0..1, got #{inspect(choices)}"}
    end
  end

  defp choices(other),
    do:
      {:error,
       "choices scale: expected a map of at least two label => value, got #{inspect(other)}"}

  @doc false
  # The scale as JSON-native data, for fingerprints and stored calibrations.
  @spec describe(t()) :: map()
  def describe(%__MODULE__{kind: :binary}), do: %{"kind" => "binary"}

  def describe(%__MODULE__{kind: :ternary, partial: partial}),
    do: %{"kind" => "ternary", "partial" => partial}

  def describe(%__MODULE__{kind: :likert} = scale),
    do: %{
      "kind" => "likert",
      "min" => scale.min,
      "max" => scale.max,
      "labels" => scale.definitions
    }

  def describe(%__MODULE__{kind: :choices, values: values}),
    do: %{"kind" => "choices", "choices" => values}

  @doc false
  # The labels ordered by value, lowest first: the rank order weighted kappa
  # uses for an ordinal scale.
  @spec ordered_labels(t()) :: [String.t()]
  def ordered_labels(%__MODULE__{labels: labels, values: values}),
    do: Enum.sort_by(labels, &{Map.fetch!(values, &1), &1})
end
