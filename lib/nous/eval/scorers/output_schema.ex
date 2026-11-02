defmodule Nous.Eval.Scorers.OutputSchema do
  @moduledoc """
  Passes when the output validates against an output type, using the same
  validation the agent uses (`Nous.OutputSchema.parse_and_validate/2`).

      {Nous.Eval.Scorers.OutputSchema, schema: MyApp.Refund, values: %{"status" => "approved"}}

  ## Options

    * `:schema` - any `Nous.Types.output_type()` except `:string`: an Ecto
      schema module, a schemaless `%{field: type}` map, a raw JSON schema
      (string-keyed map; only the JSON is parsed, as for the agent),
      `{:choice, [..]}`, `{:regex, source}` or `{:one_of, [..]}`. Dataset
      files can give a raw JSON schema
    * `:values` - optional map of expected field values, compared as a
      recursive subset of the validated output (keys as strings, numbers
      with `==`)

  Text output is parsed and validated. Structured output (the agent ran with
  an `output_type`) is re-validated through its JSON form; a struct of the
  schema module itself is already valid. A failed run fails with reason
  `"run_failed"`; validation failure fails with
  `"schema_validation_failed"` and the formatted errors in `details`.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Scorers.{Args, Options}

  @id "output_schema"
  @option_keys [:schema, :values]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys),
         {:ok, schema} <- schema(Map.get(map, :schema)),
         {:ok, values} <- values(Map.get(map, :values)) do
      {:ok, %{schema: schema, values: values}}
    end
  end

  defp schema(module) when is_atom(module) and module not in [nil, :string] do
    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1),
      do: {:ok, module},
      else: Options.invalid(@id, "schema #{inspect(module)} is not an Ecto schema module")
  end

  defp schema(%{} = map) when map_size(map) > 0, do: {:ok, map}
  defp schema({tag, _} = type) when tag in [:choice, :regex, :one_of], do: {:ok, type}

  defp schema(other),
    do: Options.invalid(@id, "schema must be an output type, got #{inspect(other)}")

  defp values(nil), do: {:ok, nil}
  defp values(%{} = map), do: {:ok, Args.normalize_expected(map)}
  defp values(other), do: Options.invalid(@id, "values must be a map, got #{inspect(other)}")

  @impl true
  def score(%ScoreInput{} = input, config) do
    if Options.run_failed?(input) do
      {:ok, Options.run_failed_score(@id)}
    else
      case validate(input.output, config.schema) do
        {:ok, validated} ->
          check_values(validated, config.values)

        {:error, %Nous.Errors.ValidationError{} = error} ->
          {:ok,
           %Score{
             Options.pass_fail(@id, false, "schema_validation_failed")
             | details: %{errors: Nous.OutputSchema.format_errors(error)}
           }}

        {:error, reason} when is_binary(reason) ->
          {:ok, Options.pass_fail(@id, false, reason)}
      end
    end
  end

  defp validate(%module{} = struct, module), do: {:ok, struct}

  defp validate(text, schema) when is_binary(text),
    do: Nous.OutputSchema.parse_and_validate(text, schema)

  defp validate(nil, _schema), do: {:error, "no_output"}

  defp validate(output, schema) do
    case encode(output) do
      {:ok, json} -> Nous.OutputSchema.parse_and_validate(json, schema)
      :error -> {:error, "output_not_encodable"}
    end
  end

  defp encode(output) do
    plain =
      if is_struct(output), do: output |> Map.from_struct() |> Map.delete(:__meta__), else: output

    {:ok, JSON.encode!(plain)}
  rescue
    _ in [Protocol.UndefinedError, ArgumentError] -> :error
  end

  defp check_values(_validated, nil), do: {:ok, Options.pass_fail(@id, true, nil)}

  defp check_values(validated, values) do
    plain =
      if is_struct(validated),
        do: validated |> Map.from_struct() |> Map.delete(:__meta__),
        else: validated

    case Args.diff(nil, plain, values, Args.config(%{})) do
      [] ->
        {:ok, Options.pass_fail(@id, true, nil)}

      paths ->
        {:ok,
         %Score{Options.pass_fail(@id, false, "field_values_mismatch") | details: %{paths: paths}}}
    end
  end

  @impl true
  def describe(config), do: config
end
