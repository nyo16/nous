defmodule Nous.Eval.Evaluators.Schema do
  @moduledoc """
  Evaluator that validates structured output against an Ecto schema.

  ## Expected Format

  The expected value should be an Ecto schema module:

      TestCase.new(
        id: "structured",
        input: "Generate a user with name Alice",
        expected: MyApp.User,
        eval_type: :schema
      )

  Or a map with the schema and optional field checks:

      TestCase.new(
        id: "structured",
        input: "Generate a user",
        expected: %{
          schema: MyApp.User,
          required_fields: [:name, :email],
          field_values: %{name: "Alice"}
        },
        eval_type: :schema
      )

  ## Configuration

    * `:allow_extra_fields` - Allow fields not in schema (default: true)
    * `:validate_changeset` - Run changeset validations (default: true)

  """

  @behaviour Nous.Eval.Evaluator

  @impl true
  def evaluate(actual, expected, config) do
    {schema_module, opts} = parse_expected(expected)

    cond do
      is_nil(schema_module) ->
        %{
          score: 0.0,
          passed: false,
          reason: "No schema module specified",
          details: %{}
        }

      not Code.ensure_loaded?(schema_module) ->
        %{
          score: 0.0,
          passed: false,
          reason: "Schema module #{inspect(schema_module)} not found",
          details: %{}
        }

      true ->
        validate_against_schema(actual, schema_module, opts, config)
    end
  end

  @impl true
  def name, do: "Schema"

  defp parse_expected(expected) when is_atom(expected), do: {expected, %{}}

  defp parse_expected(expected) when is_map(expected) do
    schema = Map.get(expected, :schema) || Map.get(expected, "schema")
    {schema, expected}
  end

  defp parse_expected(_), do: {nil, %{}}

  defp validate_against_schema(actual, schema_module, opts, config) do
    # If actual is already the right struct, validate it
    actual_data = extract_data(actual)

    case validate_data(actual_data, schema_module, config) do
      {:ok, struct} ->
        # Check additional constraints
        check_additional_constraints(struct, opts)

      {:error, errors} ->
        %{
          score: 0.0,
          passed: false,
          reason: "Schema validation failed",
          details: %{errors: errors, actual: actual_data}
        }
    end
  end

  defp extract_data(actual) when is_map(actual) do
    cond do
      Map.has_key?(actual, :output) -> actual.output
      Map.has_key?(actual, :agent_result) -> extract_data(actual.agent_result)
      true -> actual
    end
  end

  defp extract_data(actual), do: actual

  defp validate_data(data, schema_module, config) do
    # Check if data is already the right struct
    if matches_struct?(data, schema_module) do
      if Map.get(config, :validate_changeset, true) do
        validate_changeset(data, schema_module)
      else
        {:ok, data}
      end
    else
      # Try to cast the data
      try_cast(data, schema_module, config)
    end
  end

  defp matches_struct?(data, module) do
    is_map(data) and Map.get(data, :__struct__) == module
  end

  defp try_cast(data, schema_module, config) when is_map(data) do
    try do
      # Get schema fields
      fields = schema_module.__schema__(:fields)
      types = schema_module.__schema__(:types)

      # Build a map of field values
      field_values =
        Enum.reduce(fields, %{}, fn field, acc ->
          value =
            Map.get(data, field) ||
              Map.get(data, to_string(field)) ||
              Map.get(data, Atom.to_string(field))

          if value != nil do
            Map.put(acc, field, value)
          else
            acc
          end
        end)

      # Create struct
      struct = struct(schema_module, field_values)

      if Map.get(config, :validate_changeset, true) do
        validate_changeset(struct, schema_module, field_values, types)
      else
        {:ok, struct}
      end
    rescue
      e ->
        {:error, [Exception.message(e)]}
    end
  end

  defp try_cast(data, _schema_module, _config) do
    {:error, ["Expected a map, got: #{inspect(data)}"]}
  end

  defp validate_changeset(struct, schema_module) do
    # Get all field values from struct
    fields = schema_module.__schema__(:fields)
    types = schema_module.__schema__(:types)
    values = Map.take(struct, fields)
    validate_changeset(struct, schema_module, values, types)
  end

  defp validate_changeset(_struct, schema_module, values, _types) do
    # Try to use the schema's changeset function if available
    if function_exported?(schema_module, :changeset, 2) do
      changeset = schema_module.changeset(struct(schema_module), values)

      if changeset.valid? do
        {:ok, Ecto.Changeset.apply_changes(changeset)}
      else
        errors = format_changeset_errors(changeset)
        {:error, errors}
      end
    else
      # Just return the struct if no changeset function
      {:ok, struct(schema_module, values)}
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, errors} ->
      Enum.map(errors, fn error -> "#{field}: #{error}" end)
    end)
  end

  defp check_additional_constraints(struct, opts) do
    checks = [
      check_required_fields(struct, opts),
      check_field_values(struct, opts)
    ]

    failed = Enum.filter(checks, fn {passed, _, _} -> not passed end)

    if failed == [] do
      %{
        score: 1.0,
        passed: true,
        reason: nil,
        details: %{validated_struct: struct}
      }
    else
      reasons = Enum.map(failed, fn {_, reason, _} -> reason end)
      details = Enum.reduce(failed, %{}, fn {_, _, d}, acc -> Map.merge(acc, d) end)

      %{
        score: 0.0,
        passed: false,
        reason: Enum.join(reasons, "; "),
        details: Map.put(details, :validated_struct, struct)
      }
    end
  end

  defp check_required_fields(struct, opts) do
    required = Map.get(opts, :required_fields) || Map.get(opts, "required_fields") || []

    if required == [] do
      {true, nil, %{}}
    else
      missing =
        Enum.filter(required, fn field ->
          field = if is_binary(field), do: String.to_atom(field), else: field
          value = Map.get(struct, field)
          is_nil(value) or value == ""
        end)

      if missing == [] do
        {true, nil, %{}}
      else
        {false, "Missing required fields: #{inspect(missing)}", %{missing_fields: missing}}
      end
    end
  end

  defp check_field_values(struct, opts) do
    expected_values = Map.get(opts, :field_values) || Map.get(opts, "field_values") || %{}

    if expected_values == %{} do
      {true, nil, %{}}
    else
      mismatches =
        Enum.reduce(expected_values, [], fn {field, expected}, acc ->
          field = if is_binary(field), do: String.to_atom(field), else: field
          actual = Map.get(struct, field)

          if actual == expected do
            acc
          else
            [{field, expected, actual} | acc]
          end
        end)

      if mismatches == [] do
        {true, nil, %{}}
      else
        {false, "Field value mismatches", %{field_mismatches: mismatches}}
      end
    end
  end
end
