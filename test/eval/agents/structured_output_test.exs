defmodule Nous.Eval.Agents.StructuredOutputTest do
  @moduledoc """
  LLM integration tests for structured output.

  Run with: mix test test/eval/agents/structured_output_test.exs --include llm

  Requires a running LLM (LM Studio by default, or set TEST_MODEL).
  """

  use ExUnit.Case, async: false

  @moduletag :llm
  @moduletag timeout: 120_000

  alias Nous.Agent

  @default_model Nous.LLMTestHelper.test_model()

  # --- Test Schemas ---

  defmodule UserInfo do
    use Ecto.Schema
    use Nous.OutputSchema

    @llm_doc "A person with their name and age."
    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:age, :integer)
    end
  end

  defmodule Sentiment do
    use Ecto.Schema
    use Nous.OutputSchema

    @llm_doc """
    Sentiment analysis result.
    - sentiment: The detected sentiment (positive, negative, or neutral).
    - confidence: A confidence score between 0.0 and 1.0.
    """
    @primary_key false
    embedded_schema do
      field(:sentiment, Ecto.Enum, values: [:positive, :negative, :neutral])
      field(:confidence, :float)
    end

    @impl true
    def validate_changeset(changeset) do
      changeset
      |> Ecto.Changeset.validate_number(:confidence,
        greater_than_or_equal_to: 0.0,
        less_than_or_equal_to: 1.0
      )
    end
  end

  setup_all do
    case Nous.LLMTestHelper.check_model_available() do
      :ok -> {:ok, model: @default_model}
      {:error, reason} -> {:ok, skip: "LLM not available: #{reason}"}
    end
  end

  defp skip_if_unavailable(%{skip: reason}) do
    IO.puts("[StructuredOutputTest] Skipping: #{reason}")
    :skip
  end

  defp skip_if_unavailable(_), do: :ok

  describe "Ecto schema output" do
    @tag timeout: 60_000
    test "returns a typed struct with correct fields", context do
      skip_if_unavailable(context)

      agent =
        Agent.new(context[:model],
          output_type: UserInfo,
          instructions: "You extract user information from text.",
          structured_output: [max_retries: 2]
        )

      {:ok, result} = Agent.run(agent, "Alice is 30 years old.")

      assert %UserInfo{} = result.output
      assert is_binary(result.output.name)
      assert result.output.name =~ ~r/alice/i
      assert is_integer(result.output.age)
      assert result.output.age == 30

      IO.puts("[StructuredOutputTest] Ecto schema: #{inspect(result.output)}")
    end
  end

  describe "Ecto schema with validation" do
    @tag timeout: 60_000
    test "returns validated sentiment analysis", context do
      skip_if_unavailable(context)

      agent =
        Agent.new(context[:model],
          output_type: Sentiment,
          instructions: "You analyze the sentiment of text.",
          structured_output: [max_retries: 3]
        )

      {:ok, result} = Agent.run(agent, "I absolutely love this product! Best purchase ever!")

      assert %Sentiment{} = result.output
      assert result.output.sentiment in [:positive, :negative, :neutral]
      assert is_float(result.output.confidence)
      assert result.output.confidence >= 0.0 and result.output.confidence <= 1.0

      # Strong positive text should be classified as positive
      assert result.output.sentiment == :positive

      IO.puts("[StructuredOutputTest] Sentiment: #{inspect(result.output)}")
    end
  end

  describe "Schemaless output" do
    @tag timeout: 60_000
    test "returns a map with typed fields", context do
      skip_if_unavailable(context)

      agent =
        Agent.new(context[:model],
          output_type: %{city: :string, country: :string, population: :integer},
          instructions: "You return factual geographic data as JSON.",
          structured_output: [max_retries: 2]
        )

      {:ok, result} = Agent.run(agent, "Give me info about Tokyo.")

      assert is_binary(result.output.city)
      assert is_binary(result.output.country)
      assert is_integer(result.output.population)

      IO.puts("[StructuredOutputTest] Schemaless: #{inspect(result.output)}")
    end
  end
end
