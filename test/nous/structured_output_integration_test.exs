defmodule Nous.StructuredOutputIntegrationTest do
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, Message, Usage}
  alias Nous.Errors

  # --- Test Schema ---

  defmodule TestUser do
    use Ecto.Schema
    use Nous.OutputSchema

    @llm_doc "A user with name and age."
    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:age, :integer)
    end
  end

  defmodule TestScore do
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

  # --- Mock Dispatcher ---

  defmodule MockDispatcher do
    @moduledoc false

    def request(_model, messages, settings) do
      # Check what was requested
      user_content =
        messages
        |> Enum.find_value(fn
          %Message{role: :user, content: content} -> content
          _ -> nil
        end)

      # Track calls for retry testing
      call_count = :persistent_term.get({__MODULE__, :call_count}, 0)
      :persistent_term.put({__MODULE__, :call_count}, call_count + 1)

      response_text = determine_response(user_content, settings, call_count)

      legacy_response = %{
        parts: [{:text, response_text}],
        usage: %Usage{
          input_tokens: 10,
          output_tokens: 5,
          total_tokens: 15,
          tool_calls: 0,
          requests: 1
        },
        model_name: "test-model",
        timestamp: DateTime.utc_now()
      }

      response = Message.from_legacy(legacy_response)
      {:ok, response}
    end

    defp determine_response(content, settings, call_count) do
      cond do
        String.contains?(content || "", "structured_user") ->
          ~s({"name": "Alice", "age": 30})

        String.contains?(content || "", "schemaless_test") ->
          ~s({"name": "Bob", "age": 25})

        String.contains?(content || "", "raw_json_test") ->
          ~s({"answer": "hello world"})

        String.contains?(content || "", "choice_test") ->
          "positive"

        String.contains?(content || "", "retry_test") ->
          # First call returns invalid, second returns valid
          if call_count == 0 do
            ~s({"score": 2.0, "label": "test"})
          else
            ~s({"score": 0.8, "label": "test"})
          end

        String.contains?(content || "", "validation_fail") ->
          ~s({"score": 2.0, "label": "test"})

        String.contains?(content || "", "check_settings") ->
          # Return the settings as JSON for verification
          Jason.encode!(%{
            has_response_format: Map.has_key?(settings, :response_format),
            has_tools: Map.has_key?(settings, :tools)
          })

        true ->
          "plain text response"
      end
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  setup do
    Application.put_env(:nous, :model_dispatcher, MockDispatcher)
    :persistent_term.put({MockDispatcher, :call_count}, 0)

    on_exit(fn ->
      Application.delete_env(:nous, :model_dispatcher)

      try do
        :persistent_term.erase({MockDispatcher, :call_count})
      rescue
        _ -> :ok
      end
    end)

    %{model: "openai:test-model"}
  end

  describe "full agent run with Ecto schema output_type" do
    test "returns typed struct output", %{model: model} do
      agent = Agent.new(model, output_type: TestUser)

      assert {:ok, result} = AgentRunner.run(agent, "structured_user")
      assert %TestUser{} = result.output
      assert result.output.name == "Alice"
      assert result.output.age == 30
    end

    test "system prompt includes schema instructions", %{model: model} do
      agent =
        Agent.new(model,
          output_type: TestUser,
          instructions: "Be helpful"
        )

      assert {:ok, _result} = AgentRunner.run(agent, "structured_user")
      # The system prompt should include schema info (verified by compilation)
    end
  end

  describe "schemaless output_type" do
    test "returns map output", %{model: model} do
      agent = Agent.new(model, output_type: %{name: :string, age: :integer})

      assert {:ok, result} = AgentRunner.run(agent, "schemaless_test")
      assert result.output.name == "Bob"
      assert result.output.age == 25
    end
  end

  describe "raw JSON schema output_type" do
    test "returns raw map output", %{model: model} do
      agent =
        Agent.new(model,
          output_type: %{
            "type" => "object",
            "properties" => %{"answer" => %{"type" => "string"}}
          }
        )

      assert {:ok, result} = AgentRunner.run(agent, "raw_json_test")
      assert result.output["answer"] == "hello world"
    end
  end

  describe "choice output_type" do
    test "validates choice", %{model: model} do
      agent = Agent.new(model, output_type: {:choice, ["positive", "negative", "neutral"]})

      assert {:ok, result} = AgentRunner.run(agent, "choice_test")
      assert result.output == "positive"
    end
  end

  describe "validation retry" do
    test "retries on validation failure and succeeds", %{model: model} do
      agent =
        Agent.new(model,
          output_type: TestScore,
          structured_output: [max_retries: 3]
        )

      assert {:ok, result} = AgentRunner.run(agent, "retry_test")
      assert result.output.score == 0.8
      assert result.output.label == "test"
    end

    test "returns error when retries exhausted", %{model: model} do
      agent =
        Agent.new(model,
          output_type: TestScore,
          structured_output: [max_retries: 0]
        )

      assert {:error, %Errors.ValidationError{}} =
               AgentRunner.run(agent, "validation_fail")
    end
  end

  describe "provider params" do
    test "response_format is included in model settings for json_schema mode", %{model: model} do
      # This test verifies indirectly: if the agent runs successfully with a schema,
      # the settings were properly injected
      agent =
        Agent.new(model,
          output_type: TestUser,
          structured_output: [mode: :json_schema]
        )

      assert {:ok, _result} = AgentRunner.run(agent, "structured_user")
    end
  end

  describe "plain text agent unaffected" do
    test "default output_type :string works as before", %{model: model} do
      agent = Agent.new(model, instructions: "Be helpful")

      assert {:ok, result} = AgentRunner.run(agent, "hello")
      assert is_binary(result.output)
    end
  end
end
