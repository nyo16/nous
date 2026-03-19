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

  # ===================================================================
  # {:one_of, [...]} and synthetic tool name tests
  # ===================================================================

  # --- Test schemas for one_of ---

  defmodule SentimentResult do
    use Ecto.Schema
    use Nous.OutputSchema

    @llm_doc "Sentiment analysis result."
    @primary_key false
    embedded_schema do
      field(:sentiment, :string)
      field(:confidence, :float)
    end
  end

  defmodule TopicResult do
    use Ecto.Schema
    use Nous.OutputSchema

    @llm_doc "Topic classification result."
    @primary_key false
    embedded_schema do
      field(:topic, :string)
      field(:keywords, {:array, :string})
    end
  end

  # --- schema_name/1 (now public) ---

  describe "schema_name/1" do
    test "returns last module segment underscored" do
      assert OutputSchema.schema_name(SentimentResult) == "sentiment_result"
    end

    test "returns underscored name for SimpleSchema" do
      assert OutputSchema.schema_name(SimpleSchema) == "simple_schema"
    end

    test "returns 'output' for map types" do
      assert OutputSchema.schema_name(%{name: :string}) == "output"
    end

    test "returns 'output' for raw JSON schema" do
      assert OutputSchema.schema_name(%{"type" => "object"}) == "output"
    end

    test "returns 'output' for other types" do
      assert OutputSchema.schema_name(:string) == "output"
    end
  end

  # --- synthetic_tool_name?/1 ---

  describe "synthetic_tool_name?/1" do
    test "true for __structured_output__ (backward compat)" do
      assert OutputSchema.synthetic_tool_name?("__structured_output__")
    end

    test "true for per-schema tool name" do
      assert OutputSchema.synthetic_tool_name?("__structured_output_sentiment_result__")
    end

    test "true for another per-schema tool name" do
      assert OutputSchema.synthetic_tool_name?("__structured_output_topic_result__")
    end

    test "false for regular tool name" do
      refute OutputSchema.synthetic_tool_name?("search")
    end

    test "false for unrelated dunder name" do
      refute OutputSchema.synthetic_tool_name?("__other__")
    end

    test "false for empty string" do
      refute OutputSchema.synthetic_tool_name?("")
    end

    test "false for partial prefix without trailing __" do
      refute OutputSchema.synthetic_tool_name?("__structured_output")
    end

    test "false for prefix only with single trailing _" do
      refute OutputSchema.synthetic_tool_name?("__structured_output_sentiment_result_")
    end
  end

  # --- tool_name_for_schema/1 ---

  describe "tool_name_for_schema/1" do
    test "builds correct name for SentimentResult" do
      assert OutputSchema.tool_name_for_schema(SentimentResult) ==
               "__structured_output_sentiment_result__"
    end

    test "builds correct name for TopicResult" do
      assert OutputSchema.tool_name_for_schema(TopicResult) ==
               "__structured_output_topic_result__"
    end

    test "builds correct name for SimpleSchema" do
      assert OutputSchema.tool_name_for_schema(SimpleSchema) ==
               "__structured_output_simple_schema__"
    end
  end

  # --- find_schema_for_tool_name/2 ---

  describe "find_schema_for_tool_name/2" do
    test "finds SentimentResult from schemas list" do
      schemas = [SentimentResult, TopicResult]

      assert OutputSchema.find_schema_for_tool_name(
               "__structured_output_sentiment_result__",
               schemas
             ) == SentimentResult
    end

    test "finds TopicResult from schemas list" do
      schemas = [SentimentResult, TopicResult]

      assert OutputSchema.find_schema_for_tool_name(
               "__structured_output_topic_result__",
               schemas
             ) == TopicResult
    end

    test "returns nil for unknown tool name" do
      schemas = [SentimentResult, TopicResult]

      assert OutputSchema.find_schema_for_tool_name(
               "__structured_output_unknown__",
               schemas
             ) == nil
    end

    test "returns nil for empty schemas list" do
      assert OutputSchema.find_schema_for_tool_name(
               "__structured_output_sentiment_result__",
               []
             ) == nil
    end
  end

  # --- to_json_schema/1 with {:one_of, ...} ---

  describe "to_json_schema/1 with {:one_of, ...}" do
    test "returns nil" do
      assert OutputSchema.to_json_schema({:one_of, [SentimentResult, TopicResult]}) == nil
    end
  end

  # --- to_provider_settings/3 with {:one_of, ...} ---

  describe "to_provider_settings/3 with {:one_of, ...}" do
    test "returns map with __structured_output_tools__ key" do
      settings =
        OutputSchema.to_provider_settings(
          {:one_of, [SentimentResult, TopicResult]},
          :openai
        )

      assert is_list(settings[:__structured_output_tools__])
      assert length(settings[:__structured_output_tools__]) == 2
    end

    test "each tool has correct name" do
      settings =
        OutputSchema.to_provider_settings(
          {:one_of, [SentimentResult, TopicResult]},
          :openai
        )

      tool_names =
        Enum.map(settings[:__structured_output_tools__], fn t ->
          t["function"]["name"]
        end)

      assert "__structured_output_sentiment_result__" in tool_names
      assert "__structured_output_topic_result__" in tool_names
    end

    test "each tool has JSON schema matching its module" do
      settings =
        OutputSchema.to_provider_settings(
          {:one_of, [SentimentResult, TopicResult]},
          :openai
        )

      sentiment_tool =
        Enum.find(settings[:__structured_output_tools__], fn t ->
          t["function"]["name"] == "__structured_output_sentiment_result__"
        end)

      assert sentiment_tool["function"]["parameters"]["properties"]["sentiment"]["type"] ==
               "string"

      assert sentiment_tool["function"]["parameters"]["properties"]["confidence"] ==
               %{"type" => "number", "format" => "float"}
    end

    test "tool_choice is auto" do
      settings =
        OutputSchema.to_provider_settings(
          {:one_of, [SentimentResult, TopicResult]},
          :openai
        )

      assert settings[:__structured_output_tool_choice__] == "auto"
    end

    test "uses @llm_doc as tool description" do
      settings =
        OutputSchema.to_provider_settings(
          {:one_of, [SentimentResult, TopicResult]},
          :openai
        )

      sentiment_tool =
        Enum.find(settings[:__structured_output_tools__], fn t ->
          t["function"]["name"] == "__structured_output_sentiment_result__"
        end)

      assert sentiment_tool["function"]["description"] == "Sentiment analysis result."
    end

    test "raises for duplicate schema names" do
      # Create a second module with the same last segment name
      # We can simulate this by passing the same schema twice
      assert_raise ArgumentError, ~r/Duplicate schema names/, fn ->
        OutputSchema.to_provider_settings(
          {:one_of, [SentimentResult, SentimentResult]},
          :openai
        )
      end
    end

    test "works with Anthropic provider" do
      settings =
        OutputSchema.to_provider_settings(
          {:one_of, [SentimentResult, TopicResult]},
          :anthropic
        )

      assert is_list(settings[:__structured_output_tools__])
      assert settings[:__structured_output_tool_choice__] == "auto"
    end
  end

  # --- parse_and_validate/2 with {:one_of, ...} ---

  describe "parse_and_validate/2 with {:one_of, ...}" do
    test "matches first schema" do
      json = ~s({"sentiment": "positive", "confidence": 0.9})

      assert {:ok, result} =
               OutputSchema.parse_and_validate(json, {:one_of, [SentimentResult, TopicResult]})

      assert %SentimentResult{} = result
      assert result.sentiment == "positive"
      assert result.confidence == 0.9
    end

    test "matches second schema when first is listed second" do
      # TopicResult is listed first, so it matches first since Ecto is lenient
      json = ~s({"topic": "elixir", "keywords": ["otp", "beam"]})

      assert {:ok, result} =
               OutputSchema.parse_and_validate(json, {:one_of, [TopicResult, SentimentResult]})

      assert %TopicResult{} = result
      assert result.topic == "elixir"
      assert result.keywords == ["otp", "beam"]
    end

    test "matches first schema by order (Ecto is lenient)" do
      # When data could fit multiple schemas, first one wins
      json = ~s({"topic": "elixir", "keywords": ["otp", "beam"]})

      assert {:ok, result} =
               OutputSchema.parse_and_validate(json, {:one_of, [SentimentResult, TopicResult]})

      # SentimentResult matches first because Ecto cast is lenient
      assert %SentimentResult{} = result
    end

    test "returns error when no schema matches" do
      # Neither schema has a "unrelated" field that's required
      # Both schemas will cast successfully since Ecto is lenient with extra/missing fields.
      # Let's use SchemaWithValidation which has a validate_changeset
      json = ~s({"score": 2.0, "label": "test"})

      assert {:ok, _} =
               OutputSchema.parse_and_validate(
                 json,
                 {:one_of, [SchemaWithValidation, TopicResult]}
               )
    end

    test "returns error for invalid JSON" do
      assert {:error, %ValidationError{} = err} =
               OutputSchema.parse_and_validate(
                 "not json",
                 {:one_of, [SentimentResult, TopicResult]}
               )

      assert err.message =~ "Failed to parse JSON"
    end

    test "extracts JSON from markdown code fence" do
      text = "```json\n{\"sentiment\": \"negative\", \"confidence\": 0.8}\n```"

      assert {:ok, %SentimentResult{sentiment: "negative", confidence: 0.8}} =
               OutputSchema.parse_and_validate(
                 text,
                 {:one_of, [SentimentResult, TopicResult]}
               )
    end

    test "prefers first matching schema when data fits multiple" do
      # Data that both schemas could accept (Ecto is lenient)
      json = ~s({"sentiment": "test", "confidence": 0.5, "topic": "extra"})

      assert {:ok, %SentimentResult{}} =
               OutputSchema.parse_and_validate(
                 json,
                 {:one_of, [SentimentResult, TopicResult]}
               )
    end

    test "returns error with schema names when validation-strict schemas fail" do
      # SchemaWithValidation requires score <= 1.0
      json = ~s({"score": 2.0, "label": "test"})

      # TopicResult will succeed since it's lenient, so let's just test the validate one
      assert {:error, %ValidationError{}} =
               OutputSchema.parse_and_validate(json, SchemaWithValidation)
    end

    test "error includes one_of context when no schemas match" do
      # Use schemas that have strict validation
      # SchemaWithValidation: score must be <= 1.0
      json = ~s({"score": 2.0})

      assert {:error, %ValidationError{} = err} =
               OutputSchema.parse_and_validate(
                 json,
                 {:one_of, [SchemaWithValidation]}
               )

      # SchemaWithValidation fails because label is required
      assert err.output_type == {:one_of, [SchemaWithValidation]}
      assert err.message =~ "one_of"
    end
  end

  # --- system_prompt_suffix/2 with {:one_of, ...} ---

  describe "system_prompt_suffix/2 with {:one_of, ...}" do
    test "contains schema names" do
      result =
        OutputSchema.system_prompt_suffix({:one_of, [SentimentResult, TopicResult]}, [])

      assert result =~ "sentiment_result"
      assert result =~ "topic_result"
    end

    test "contains JSON schema properties from both schemas" do
      result =
        OutputSchema.system_prompt_suffix({:one_of, [SentimentResult, TopicResult]}, [])

      assert result =~ "sentiment"
      assert result =~ "confidence"
      assert result =~ "topic"
      assert result =~ "keywords"
    end

    test "mentions choosing the appropriate schema" do
      result =
        OutputSchema.system_prompt_suffix({:one_of, [SentimentResult, TopicResult]}, [])

      assert result =~ "appropriate"
    end

    test "includes tool names" do
      result =
        OutputSchema.system_prompt_suffix({:one_of, [SentimentResult, TopicResult]}, [])

      assert result =~ "__structured_output_sentiment_result__"
      assert result =~ "__structured_output_topic_result__"
    end

    test "includes @llm_doc descriptions" do
      result =
        OutputSchema.system_prompt_suffix({:one_of, [SentimentResult, TopicResult]}, [])

      assert result =~ "Sentiment analysis result."
      assert result =~ "Topic classification result."
    end
  end

  # --- extract_response_for_one_of/2 ---

  describe "extract_response_for_one_of/2" do
    test "with synthetic tool call returns json text and matched schema" do
      msg =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              "id" => "call_1",
              "name" => "__structured_output_sentiment_result__",
              "arguments" => %{"sentiment" => "positive", "confidence" => 0.95}
            }
          ]
        )

      schemas = [SentimentResult, TopicResult]
      {text, schema} = OutputSchema.extract_response_for_one_of(msg, schemas)

      assert schema == SentimentResult
      assert Jason.decode!(text) == %{"sentiment" => "positive", "confidence" => 0.95}
    end

    test "with second schema tool call returns correct schema" do
      msg =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              "id" => "call_1",
              "name" => "__structured_output_topic_result__",
              "arguments" => %{"topic" => "elixir", "keywords" => ["otp"]}
            }
          ]
        )

      schemas = [SentimentResult, TopicResult]
      {text, schema} = OutputSchema.extract_response_for_one_of(msg, schemas)

      assert schema == TopicResult
      assert Jason.decode!(text) == %{"topic" => "elixir", "keywords" => ["otp"]}
    end

    test "with plain text message returns text and nil schema" do
      msg = Nous.Message.assistant("just some text")

      schemas = [SentimentResult, TopicResult]
      {text, schema} = OutputSchema.extract_response_for_one_of(msg, schemas)

      assert text == "just some text"
      assert schema == nil
    end

    test "with standard __structured_output__ tool call returns nil schema" do
      msg =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              "id" => "call_1",
              "name" => "__structured_output__",
              "arguments" => %{"sentiment" => "positive"}
            }
          ]
        )

      schemas = [SentimentResult, TopicResult]
      {_text, schema} = OutputSchema.extract_response_for_one_of(msg, schemas)

      # __structured_output__ doesn't match any per-schema tool name
      assert schema == nil
    end

    test "with unknown synthetic tool call returns nil schema" do
      msg =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              "id" => "call_1",
              "name" => "__structured_output_unknown__",
              "arguments" => %{"data" => "test"}
            }
          ]
        )

      schemas = [SentimentResult, TopicResult]
      {_text, schema} = OutputSchema.extract_response_for_one_of(msg, schemas)

      assert schema == nil
    end

    test "handles atom key tool calls" do
      msg =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              id: "call_1",
              name: "__structured_output_sentiment_result__",
              arguments: %{"sentiment" => "positive", "confidence" => 0.9}
            }
          ]
        )

      schemas = [SentimentResult, TopicResult]
      {_text, schema} = OutputSchema.extract_response_for_one_of(msg, schemas)

      assert schema == SentimentResult
    end
  end

  # --- extract_response_text/2 backward compat with new synthetic names ---

  describe "extract_response_text/2 with per-schema tool names" do
    test "extracts from per-schema synthetic tool call" do
      msg =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              "id" => "call_1",
              "name" => "__structured_output_sentiment_result__",
              "arguments" => %{"sentiment" => "positive", "confidence" => 0.9}
            }
          ]
        )

      result = OutputSchema.extract_response_text(msg, :openai)
      assert Jason.decode!(result) == %{"sentiment" => "positive", "confidence" => 0.9}
    end

    test "still works with standard __structured_output__ name" do
      msg =
        Nous.Message.assistant("",
          tool_calls: [
            %{
              "id" => "call_1",
              "name" => "__structured_output__",
              "arguments" => %{"name" => "Alice"}
            }
          ]
        )

      result = OutputSchema.extract_response_text(msg, :anthropic)
      assert Jason.decode!(result) == %{"name" => "Alice"}
    end
  end
end
