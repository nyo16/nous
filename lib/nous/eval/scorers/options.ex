defmodule Nous.Eval.Scorers.Options do
  @moduledoc false
  # Option parsing shared by the built-in scorers. Values may come from
  # Elixir (atoms, tuples) or from dataset files (strings, maps, lists);
  # string enum values are mapped through literal tables, never turned into
  # atoms.

  alias Nous.Eval.{Score, ScoreInput, ScorerError}
  alias Nous.Eval.Trace.ToolCall

  @doc "Validates `opts` as a keyword list with only `allowed` keys."
  def validate(scorer, opts, allowed) do
    cond do
      not Keyword.keyword?(opts) ->
        invalid(scorer, "options must be a keyword list")

      (unknown = Keyword.keys(opts) -- allowed) != [] ->
        invalid(
          scorer,
          "unknown options #{inspect(Enum.uniq(unknown))}; allowed: #{inspect(allowed)}"
        )

      true ->
        {:ok, Map.new(opts)}
    end
  end

  def invalid(scorer, message), do: {:error, "#{scorer}: #{message}"}

  @doc "An enum option: one of `atoms`, or its string name."
  def enum(scorer, key, value, atoms) do
    by_name = Map.new(atoms, &{Atom.to_string(&1), &1})

    cond do
      is_atom(value) and value in atoms -> {:ok, value}
      is_binary(value) and is_map_key(by_name, value) -> {:ok, Map.fetch!(by_name, value)}
      true -> invalid(scorer, "#{key} must be one of #{inspect(atoms)}, got #{inspect(value)}")
    end
  end

  def boolean(_scorer, _key, value) when is_boolean(value), do: {:ok, value}

  def boolean(scorer, key, value),
    do: invalid(scorer, "#{key} must be a boolean, got #{inspect(value)}")

  def non_neg_integer(_scorer, _key, value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  def non_neg_integer(scorer, key, value),
    do: invalid(scorer, "#{key} must be a non-negative integer, got #{inspect(value)}")

  def non_neg_number(_scorer, _key, value) when is_number(value) and value >= 0, do: {:ok, value}

  def non_neg_number(scorer, key, value),
    do: invalid(scorer, "#{key} must be a non-negative number, got #{inspect(value)}")

  def unit_float(_scorer, _key, value) when is_number(value) and value >= 0 and value <= 1,
    do: {:ok, value / 1}

  def unit_float(scorer, key, value),
    do: invalid(scorer, "#{key} must be a number in 0..1, got #{inspect(value)}")

  def string(_scorer, _key, value) when is_binary(value) and value != "", do: {:ok, value}

  def string(scorer, key, value),
    do: invalid(scorer, "#{key} must be a non-empty string, got #{inspect(value)}")

  def string_list(scorer, key, value) do
    case value do
      [_ | _] = values ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")),
          do: {:ok, values},
          else: string_list_error(scorer, key, value)

      _ ->
        string_list_error(scorer, key, value)
    end
  end

  defp string_list_error(scorer, key, value),
    do:
      invalid(
        scorer,
        "#{key} must be a non-empty list of non-empty strings, got #{inspect(value)}"
      )

  @scopes [:root, :tree]

  @doc "A trace scope: `:root | :tree | {:run, id} | {:sub_agent, template}` or their file forms."
  def scope(scorer, value) do
    case value do
      scope when scope in @scopes ->
        {:ok, scope}

      "root" ->
        {:ok, :root}

      "tree" ->
        {:ok, :tree}

      {:sub_agent, template} when is_binary(template) ->
        {:ok, {:sub_agent, template}}

      {:run, id} when is_binary(id) ->
        {:ok, {:run, id}}

      %{"sub_agent" => template} when is_binary(template) ->
        {:ok, {:sub_agent, template}}

      other ->
        invalid(
          scorer,
          "scope must be root, tree or {:sub_agent, template}, got #{inspect(other)}"
        )
    end
  end

  @doc "A tool-call outcome filter: `:all` or a list of outcomes (atoms or strings)."
  def include(scorer, value) do
    outcomes = ToolCall.outcomes()

    case value do
      v when v in [:all, "all"] ->
        {:ok, :all}

      [_ | _] = list ->
        list
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
          case enum(scorer, :include, item, outcomes) do
            {:ok, outcome} -> {:cont, {:ok, [outcome | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          error -> error
        end

      other ->
        invalid(
          scorer,
          "include must be :all or a non-empty list of outcomes, got #{inspect(other)}"
        )
    end
  end

  @doc "True when the agent run did not complete."
  def run_failed?(%ScoreInput{run_outcome: {:ok, _}}), do: false
  def run_failed?(%ScoreInput{}), do: true

  @doc "The fail score an output scorer returns for a failed run."
  def run_failed_score(name) do
    %Score{name: name, value: :fail, passed?: false, reason: "run_failed"}
  end

  def pass_fail(name, passed?, reason, details \\ %{}) do
    %Score{
      name: name,
      value: if(passed?, do: :pass, else: :fail),
      passed?: passed?,
      reason: reason,
      details: details
    }
  end

  def missing_trace(scorer, reason) do
    {:error, %ScorerError{scorer: scorer, kind: :missing_trace, reason: reason}}
  end

  def scorer_error(scorer, kind, reason) do
    {:error, %ScorerError{scorer: scorer, kind: kind, reason: reason}}
  end

  @doc """
  The text output of a sample, or the result an output scorer returns
  instead: a `run_failed` fail for a failed run, an `:invalid_config` error
  for structured output.
  """
  def text_output(scorer, %ScoreInput{} = input) do
    cond do
      run_failed?(input) ->
        {:result, {:ok, run_failed_score(scorer)}}

      is_binary(input.output) ->
        {:ok, input.output}

      true ->
        {:result,
         scorer_error(scorer, :invalid_config, "text expected but the output is not text")}
    end
  end

  @doc "Parsers for the text normalization options shared by Equals and Similarity."
  def text_parsers(scorer) do
    [
      {:case_sensitive, true, &boolean(scorer, :case_sensitive, &1)},
      {:trim, true, &boolean(scorer, :trim, &1)},
      {:collapse_whitespace, false, &boolean(scorer, :collapse_whitespace, &1)}
    ]
  end

  def normalize_text(text, config) do
    text = if config.trim, do: String.trim(text), else: text
    text = if config.collapse_whitespace, do: String.replace(text, ~r/\s+/u, " "), else: text
    if config.case_sensitive, do: text, else: String.downcase(text)
  end

  @doc """
  The expected value: the `:expected` option, else the case's
  `expected["output"]` (or `expected[:output]` in Elixir-authored cases).
  """
  def expected(%{expected: expected}, _input) when not is_nil(expected), do: {:ok, expected}

  def expected(_config, %ScoreInput{case: %{expected: %{} = expected}}) do
    case Map.get(expected, "output", Map.get(expected, :output)) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  def expected(_config, _input), do: :error

  @doc "Folds `{key, parser}` pairs over the given option map into a config map."
  def parse(map, parsers, config \\ %{}) do
    Enum.reduce_while(parsers, {:ok, config}, fn {key, default, parser}, {:ok, acc} ->
      value = Map.get(map, key, default)

      case parser.(value) do
        {:ok, parsed} -> {:cont, {:ok, Map.put(acc, key, parsed)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
