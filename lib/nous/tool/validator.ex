defmodule Nous.Tool.Validator do
  @moduledoc """
  Validates tool arguments against JSON schema.

  Provides validation of arguments before tool execution to catch
  errors early and provide helpful feedback to the LLM.

  ## Example

      schema = %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"},
          "limit" => %{"type" => "integer"}
        },
        "required" => ["query"]
      }

      args = %{"query" => "elixir", "limit" => 10}
      {:ok, args} = Validator.validate(args, schema)

      # Missing required field
      {:error, {:missing_required, ["query"]}} = Validator.validate(%{}, schema)

      # Wrong type
      {:error, {:type_mismatch, [{"limit", "integer", "string"}]}} =
        Validator.validate(%{"query" => "x", "limit" => "not a number"}, schema)

  ## Integration with ToolExecutor

  When `tool.validate_args` is `true`, the ToolExecutor will validate
  arguments before calling the tool function.

  """

  @type validation_error ::
          {:missing_required, [String.t()]}
          | {:type_mismatch, [{String.t(), String.t(), String.t()}]}
          | {:validation_failed, String.t()}

  @doc """
  Validate arguments against a JSON schema.

  ## Parameters

  - `args` - The arguments map to validate
  - `schema` - JSON schema with "properties" and "required" fields

  ## Returns

  - `{:ok, args}` - Arguments are valid
  - `{:error, reason}` - Validation failed

  ## Example

      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        },
        "required" => ["name"]
      }

      Validator.validate(%{"name" => "Alice"}, schema)
      # => {:ok, %{"name" => "Alice"}}

  """
  @spec validate(map(), map()) :: {:ok, map()} | {:error, validation_error()}
  def validate(args, schema) when is_map(args) and is_map(schema) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    with :ok <- validate_required(args, required),
         :ok <- validate_types(args, properties) do
      {:ok, args}
    end
  end

  @doc """
  Validate that all required fields are present.

  ## Example

      Validator.validate_required(%{"a" => 1}, ["a", "b"])
      # => {:error, {:missing_required, ["b"]}}

  """
  @spec validate_required(map(), [String.t()]) ::
          :ok | {:error, {:missing_required, [String.t()]}}
  def validate_required(args, required) when is_map(args) and is_list(required) do
    missing =
      Enum.filter(required, fn key ->
        not Map.has_key?(args, key)
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_required, missing}}
    end
  end

  @doc """
  Validate argument types against schema properties.

  ## Example

      properties = %{
        "count" => %{"type" => "integer"}
      }

      Validator.validate_types(%{"count" => "not a number"}, properties)
      # => {:error, {:type_mismatch, [{"count", "integer", "string"}]}}

  """
  @spec validate_types(map(), map()) :: :ok | {:error, {:type_mismatch, list()}}
  def validate_types(args, properties) when is_map(args) and is_map(properties) do
    errors =
      args
      |> Enum.reduce([], fn {key, value}, acc ->
        case Map.get(properties, key) do
          nil ->
            # Unknown keys are allowed (additionalProperties: true by default)
            acc

          %{"type" => expected_type} ->
            if matches_type?(value, expected_type) do
              acc
            else
              [{key, expected_type, typeof(value)} | acc]
            end

          %{"enum" => allowed_values} ->
            if value in allowed_values do
              acc
            else
              [{key, "enum:#{inspect(allowed_values)}", inspect(value)} | acc]
            end

          _other ->
            # Schema without type constraint
            acc
        end
      end)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, {:type_mismatch, Enum.reverse(errors)}}
    end
  end

  @doc """
  Check if a value matches a JSON schema type.

  Supports: string, integer, number, boolean, array, object, null

  ## Example

      Validator.matches_type?("hello", "string")  # => true
      Validator.matches_type?(42, "integer")      # => true
      Validator.matches_type?(3.14, "number")     # => true
      Validator.matches_type?([1, 2], "array")    # => true
      Validator.matches_type?(%{}, "object")      # => true

  """
  @spec matches_type?(any(), String.t()) :: boolean()
  def matches_type?(value, "string"), do: is_binary(value)
  def matches_type?(value, "integer"), do: is_integer(value)
  def matches_type?(value, "number"), do: is_number(value)
  def matches_type?(value, "boolean"), do: is_boolean(value)
  def matches_type?(value, "array"), do: is_list(value)
  def matches_type?(value, "object"), do: is_map(value)
  def matches_type?(nil, "null"), do: true
  # Unknown types are permissive
  def matches_type?(_value, _type), do: true

  @doc """
  Get the JSON schema type name for a value.

  ## Example

      Validator.typeof("hello")  # => "string"
      Validator.typeof(42)       # => "integer"
      Validator.typeof(3.14)     # => "number"
      Validator.typeof([])       # => "array"
      Validator.typeof(%{})      # => "object"
      Validator.typeof(nil)      # => "null"

  """
  @spec typeof(any()) :: String.t()
  def typeof(value) when is_binary(value), do: "string"
  def typeof(value) when is_integer(value), do: "integer"
  def typeof(value) when is_float(value), do: "number"
  def typeof(value) when is_boolean(value), do: "boolean"
  def typeof(value) when is_list(value), do: "array"
  def typeof(value) when is_map(value), do: "object"
  def typeof(nil), do: "null"
  def typeof(_), do: "unknown"

  @doc """
  Format validation errors into a human-readable string.

  ## Example

      error = {:missing_required, ["query", "limit"]}
      Validator.format_error(error)
      # => "Missing required fields: query, limit"

  """
  @spec format_error(validation_error()) :: String.t()
  def format_error({:missing_required, fields}) do
    "Missing required fields: #{Enum.join(fields, ", ")}"
  end

  def format_error({:type_mismatch, errors}) do
    formatted =
      Enum.map_join(errors, "; ", fn {field, expected, actual} ->
        "#{field}: expected #{expected}, got #{actual}"
      end)

    "Type mismatch: #{formatted}"
  end

  def format_error({:validation_failed, message}) do
    "Validation failed: #{message}"
  end

  @doc """
  Validate arguments and raise on error.

  Useful for tests or when you want to fail fast.

  ## Example

      Validator.validate!(args, schema)  # Raises on invalid

  """
  @spec validate!(map(), map()) :: map()
  def validate!(args, schema) do
    case validate(args, schema) do
      {:ok, validated} -> validated
      {:error, reason} -> raise format_error(reason)
    end
  end
end
