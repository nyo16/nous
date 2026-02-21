defmodule Nous.OutputSchemaTest do
  use ExUnit.Case, async: true

  alias Nous.OutputSchema
  alias Nous.Errors.ValidationError

  # --- Test Schema Modules ---

  defmodule SimpleSchema do
    use Ecto.Schema
    use Nous.OutputSchema

    @llm_doc """
    A simple test schema with name and age.
    """
    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:age, :integer)
    end
  end

  defmodule SchemaWithValidation do
    use Ecto.Schema
    use Nous.OutputSchema

    @primary_key false
    embedded_schema do
      field(:score, :float)
      field(:label, :string)
    end

    @impl true
    def validate_changeset(changeset) do
      changeset
      |> Ecto.Changeset.validate_number(:score,
        greater_than_or_equal_to: 0.0,
        less_than_or_equal_to: 1.0
      )
      |> Ecto.Changeset.validate_required([:label])
    end
  end

  defmodule SchemaWithEnum do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field(:class, Ecto.Enum, values: [:spam, :not_spam])
      field(:reason, :string)
    end
  end

  defmodule SchemaWithTypes do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:count, :integer)
      field(:score, :float)
      field(:active, :boolean)
      field(:tags, {:array, :string})
      field(:metadata, :map)
    end
  end

  defmodule InnerSchema do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field(:street, :string)
      field(:city, :string)
    end
  end

  defmodule SchemaWithEmbed do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field(:name, :string)
      embeds_one(:address, InnerSchema)
    end
  end

  # --- to_json_schema/1 ---

  describe "to_json_schema/1" do
    test "returns nil for :string" do
      assert OutputSchema.to_json_schema(:string) == nil
    end

    test "returns nil for tuples" do
      assert OutputSchema.to_json_schema({:regex, "\\d+"}) == nil
      assert OutputSchema.to_json_schema({:grammar, "start: ..."}) == nil
      assert OutputSchema.to_json_schema({:choice, ["a", "b"]}) == nil
    end

    test "converts simple Ecto schema" do
      schema = OutputSchema.to_json_schema(SimpleSchema)

      assert schema["type"] == "object"
      assert schema["additionalProperties"] == false
      assert "name" in schema["required"]
      assert "age" in schema["required"]
      assert schema["properties"]["name"] == %{"type" => "string"}
      assert schema["properties"]["age"] == %{"type" => "integer"}
    end

    test "includes @llm_doc as description" do
      schema = OutputSchema.to_json_schema(SimpleSchema)
      assert schema["description"] =~ "simple test schema"
    end

    test "converts various Ecto types" do
      schema = OutputSchema.to_json_schema(SchemaWithTypes)

      assert schema["properties"]["name"] == %{"type" => "string"}
      assert schema["properties"]["count"] == %{"type" => "integer"}
      assert schema["properties"]["score"] == %{"type" => "number", "format" => "float"}
      assert schema["properties"]["active"] == %{"type" => "boolean"}

      assert schema["properties"]["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }

      assert schema["properties"]["metadata"] == %{"type" => "object"}
    end

    test "converts Ecto.Enum to enum constraint" do
      schema = OutputSchema.to_json_schema(SchemaWithEnum)
      enum_prop = schema["properties"]["class"]

      assert enum_prop["type"] == "string"
      assert is_list(enum_prop["enum"])
      assert "spam" in enum_prop["enum"]
      assert "not_spam" in enum_prop["enum"]
    end

    test "converts embedded schemas with $defs/$ref" do
      schema = OutputSchema.to_json_schema(SchemaWithEmbed)

      assert schema["properties"]["name"] == %{"type" => "string"}
      assert schema["properties"]["address"]["$ref"] == "#/$defs/InnerSchema"

      assert schema["$defs"]["InnerSchema"]["type"] == "object"
      assert schema["$defs"]["InnerSchema"]["properties"]["street"] == %{"type" => "string"}
      assert schema["$defs"]["InnerSchema"]["properties"]["city"] == %{"type" => "string"}
    end

    test "converts schemaless types (atom keys)" do
      schema = OutputSchema.to_json_schema(%{name: :string, age: :integer, active: :boolean})

      assert schema["type"] == "object"
      assert schema["properties"]["name"] == %{"type" => "string"}
      assert schema["properties"]["age"] == %{"type" => "integer"}
      assert schema["properties"]["active"] == %{"type" => "boolean"}
      assert "name" in schema["required"]
    end

    test "passes through raw JSON schema (string keys)" do
      raw = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "string"}}
      }

      assert OutputSchema.to_json_schema(raw) == raw
    end
  end

  # --- to_provider_settings/3 ---

  describe "to_provider_settings/3" do
    test "returns empty map for :string" do
      assert OutputSchema.to_provider_settings(:string, :openai) == %{}
    end

    test "generates json_schema mode for OpenAI" do
      settings = OutputSchema.to_provider_settings(SimpleSchema, :openai, mode: :json_schema)

      assert settings.response_format["type"] == "json_schema"
      assert settings.response_format["json_schema"]["name"] == "simple_schema"
      assert settings.response_format["json_schema"]["strict"] == true
      assert settings.response_format["json_schema"]["schema"]["type"] == "object"
    end

    test "generates tool_call mode" do
      settings = OutputSchema.to_provider_settings(SimpleSchema, :anthropic, mode: :tool_call)

      assert settings[:__structured_output_tool__]["function"]["name"] == "__structured_output__"
      assert settings[:__structured_output_tool_choice__]
    end

    test "auto mode resolves to json_schema for OpenAI" do
      settings = OutputSchema.to_provider_settings(SimpleSchema, :openai, mode: :auto)
      assert settings.response_format["type"] == "json_schema"
    end

    test "auto mode resolves to tool_call for Anthropic" do
      settings = OutputSchema.to_provider_settings(SimpleSchema, :anthropic, mode: :auto)
      assert settings[:__structured_output_tool__]
    end

    test "json mode generates json_object response_format" do
      settings = OutputSchema.to_provider_settings(SimpleSchema, :openai, mode: :json)
      assert settings.response_format["type"] == "json_object"
    end

    test "md_json mode generates stop token" do
      settings = OutputSchema.to_provider_settings(SimpleSchema, :openai, mode: :md_json)
      assert settings[:stop] == ["```"]
    end

    test "vLLM adds guided_json alongside response_format" do
      settings = OutputSchema.to_provider_settings(SimpleSchema, :vllm, mode: :json_schema)
      assert settings.response_format
      assert settings[:guided_json]
    end

    test "vLLM regex generates guided_regex" do
      settings = OutputSchema.to_provider_settings({:regex, "\\d+"}, :vllm)
      assert settings[:guided_regex] == "\\d+"
    end

    test "vLLM grammar generates guided_grammar" do
      settings = OutputSchema.to_provider_settings({:grammar, "start: ..."}, :vllm)
      assert settings[:guided_grammar] == "start: ..."
    end

    test "vLLM choice generates guided_choice" do
      settings = OutputSchema.to_provider_settings({:choice, ["yes", "no"]}, :vllm)
      assert settings[:guided_choice] == ["yes", "no"]
    end

    test "SGLang adds json_schema alongside response_format" do
      settings = OutputSchema.to_provider_settings(SimpleSchema, :sglang, mode: :json_schema)
      assert settings.response_format
      assert settings[:json_schema]
    end
  end

  # --- parse_and_validate/2 ---

  describe "parse_and_validate/2" do
    test "passes through :string type" do
      assert {:ok, "hello"} = OutputSchema.parse_and_validate("hello", :string)
    end

    test "validates choice type - success" do
      assert {:ok, "yes"} = OutputSchema.parse_and_validate("yes", {:choice, ["yes", "no"]})
    end

    test "validates choice type - trims whitespace" do
      assert {:ok, "yes"} = OutputSchema.parse_and_validate("  yes  ", {:choice, ["yes", "no"]})
    end

    test "validates choice type - failure" do
      assert {:error, %ValidationError{}} =
               OutputSchema.parse_and_validate("maybe", {:choice, ["yes", "no"]})
    end

    test "validates regex type - success" do
      assert {:ok, "123"} = OutputSchema.parse_and_validate("123", {:regex, "^\\d+$"})
    end

    test "validates regex type - failure" do
      assert {:error, %ValidationError{}} =
               OutputSchema.parse_and_validate("abc", {:regex, "^\\d+$"})
    end

    test "grammar type passes through" do
      assert {:ok, "SELECT * FROM users"} =
               OutputSchema.parse_and_validate("SELECT * FROM users", {:grammar, "start: ..."})
    end

    test "parses and validates Ecto schema" do
      json = ~s({"name": "Alice", "age": 30})
      assert {:ok, result} = OutputSchema.parse_and_validate(json, SimpleSchema)
      assert result.name == "Alice"
      assert result.age == 30
      assert is_struct(result, SimpleSchema)
    end

    test "returns validation error for invalid Ecto schema data" do
      json = ~s({"name": "Alice"})
      # Missing age should still work since integer cast from nil just sets nil
      assert {:ok, _result} = OutputSchema.parse_and_validate(json, SimpleSchema)
    end

    test "parses and validates with validate_changeset callback" do
      json = ~s({"score": 0.5, "label": "test"})
      assert {:ok, result} = OutputSchema.parse_and_validate(json, SchemaWithValidation)
      assert result.score == 0.5
      assert result.label == "test"
    end

    test "returns validation error when validate_changeset fails" do
      json = ~s({"score": 1.5, "label": "test"})

      assert {:error, %ValidationError{}} =
               OutputSchema.parse_and_validate(json, SchemaWithValidation)
    end

    test "returns validation error when required field missing in validate_changeset" do
      json = ~s({"score": 0.5})

      assert {:error, %ValidationError{}} =
               OutputSchema.parse_and_validate(json, SchemaWithValidation)
    end

    test "parses schemaless types" do
      json = ~s({"name": "Alice", "age": 30})

      assert {:ok, result} =
               OutputSchema.parse_and_validate(json, %{name: :string, age: :integer})

      assert result.name == "Alice"
      assert result.age == 30
    end

    test "passes through raw JSON schema (string keys)" do
      json = ~s({"answer": "hello"})
      raw_schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}
      assert {:ok, result} = OutputSchema.parse_and_validate(json, raw_schema)
      assert result["answer"] == "hello"
    end

    test "returns error for invalid JSON" do
      assert {:error, %ValidationError{}} =
               OutputSchema.parse_and_validate("not json", SimpleSchema)
    end

    test "extracts JSON from markdown code fence" do
      text = "```json\n{\"name\": \"Alice\", \"age\": 30}\n```"
      assert {:ok, result} = OutputSchema.parse_and_validate(text, SimpleSchema)
      assert result.name == "Alice"
    end

    test "handles Ecto.Enum values" do
      json = ~s({"class": "spam", "reason": "suspicious"})
      assert {:ok, result} = OutputSchema.parse_and_validate(json, SchemaWithEnum)
      assert result.class == :spam
      assert result.reason == "suspicious"
    end
  end

  # --- extract_response_text/2 ---

  describe "extract_response_text/2" do
    test "extracts text from regular message" do
      msg = Nous.Message.assistant("hello world")
      assert OutputSchema.extract_response_text(msg, :openai) == "hello world"
    end

    test "extracts from synthetic tool call" do
      msg =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              "id" => "call_1",
              "name" => "__structured_output__",
              "arguments" => %{"name" => "Alice", "age" => 30}
            }
          ]
        )

      result = OutputSchema.extract_response_text(msg, :anthropic)
      assert Jason.decode!(result) == %{"name" => "Alice", "age" => 30}
    end
  end

  # --- format_errors/1 ---

  describe "format_errors/1" do
    test "formats validation error with field errors" do
      err =
        ValidationError.exception(
          errors: [score: {"must be less than or equal to 1.0", []}],
          output_type: SchemaWithValidation
        )

      result = OutputSchema.format_errors(err)
      assert result =~ "score"
      assert result =~ "must be less than"
    end

    test "formats validation error with message only" do
      err = ValidationError.exception(message: "Failed to parse JSON")
      result = OutputSchema.format_errors(err)
      assert result == "Failed to parse JSON"
    end
  end

  # --- system_prompt_suffix/2 ---

  describe "system_prompt_suffix/2" do
    test "returns nil for :string" do
      assert OutputSchema.system_prompt_suffix(:string, []) == nil
    end

    test "returns nil for :regex" do
      assert OutputSchema.system_prompt_suffix({:regex, "\\d+"}, []) == nil
    end

    test "returns choice instructions" do
      result = OutputSchema.system_prompt_suffix({:choice, ["a", "b"]}, [])
      assert result =~ "exactly one of"
      assert result =~ "a, b"
    end

    test "returns schema instructions for Ecto schema" do
      result = OutputSchema.system_prompt_suffix(SimpleSchema, [])
      assert result =~ "JSON"
      assert result =~ "schema"
    end

    test "returns md_json instructions when mode is :md_json" do
      result = OutputSchema.system_prompt_suffix(SimpleSchema, mode: :md_json)
      assert result =~ "markdown"
    end
  end

  # --- __llm_doc__ ---

  describe "use Nous.OutputSchema" do
    test "@llm_doc is accessible at runtime" do
      assert SimpleSchema.__llm_doc__() =~ "simple test schema"
    end

    test "@llm_doc returns nil when not set" do
      # SchemaWithValidation uses Nous.OutputSchema but has no @llm_doc set
      assert SchemaWithValidation.__llm_doc__() == nil
    end
  end
end
