#!/usr/bin/env elixir

# Nous AI - Structured Output
# Return validated, typed data from agents instead of raw text.
#
# This example demonstrates:
#   1. Ecto schema output with validation
#   2. Schemaless type maps
#   3. Custom validation with retries
#   4. Choice mode for vLLM/SGLang
#   5. Error handling

IO.puts("=== Nous AI - Structured Output Demo ===\n")

# ============================================================================
# Example 1: Basic Ecto schema output
# ============================================================================
#
# Define an Ecto embedded schema and pass it as output_type.
# Nous converts it to JSON schema, sends it to the provider, and
# casts the response back into the struct.

IO.puts("--- Example 1: Ecto schema output ---")

defmodule SpamPrediction do
  use Ecto.Schema
  use Nous.OutputSchema

  @llm_doc """
  ## Field Descriptions:
  - class: Whether or not the email is spam.
  - reason: A short, less than 10 word rationalization.
  - score: A confidence score between 0.0 and 1.0.
  """
  @primary_key false
  embedded_schema do
    field(:class, Ecto.Enum, values: [:spam, :not_spam])
    field(:reason, :string)
    field(:score, :float)
  end
end

agent =
  Nous.new("openai:gpt-4o-mini",
    output_type: SpamPrediction,
    instructions: "You are an email spam classifier."
  )

email_text = """
Congratulations! You have been selected as the winner of our grand prize
drawing. Click here immediately to claim your $1,000,000 reward before
it expires in 24 hours!
"""

{:ok, result} = Nous.run(agent, "Classify this email:\n\n#{email_text}")

IO.puts("  Class:  #{result.output.class}")
IO.puts("  Reason: #{result.output.reason}")
IO.puts("  Score:  #{result.output.score}")
IO.puts("  Struct: #{inspect(result.output)}")
IO.puts("")

# ============================================================================
# Example 2: Schemaless types
# ============================================================================
#
# For quick prototyping, pass a map of field names to Ecto types.
# No module definition needed.

IO.puts("--- Example 2: Schemaless types ---")

agent =
  Nous.new("openai:gpt-4o-mini",
    output_type: %{name: :string, age: :integer, hobbies: {:array, :string}},
    instructions: "Generate realistic user profiles."
  )

{:ok, result} = Nous.run(agent, "Generate a profile for a software engineer in their 30s")

IO.puts("  Name:    #{result.output.name}")
IO.puts("  Age:     #{result.output.age}")
IO.puts("  Hobbies: #{Enum.join(result.output.hobbies, ", ")}")
IO.puts("")

# ============================================================================
# Example 3: Custom validation with retries
# ============================================================================
#
# Use validate_changeset/1 to enforce domain rules. When validation fails,
# Nous sends the errors back to the LLM and retries up to max_retries times.

IO.puts("--- Example 3: Validation with retries ---")

defmodule MovieReview do
  use Ecto.Schema
  use Nous.OutputSchema

  @llm_doc """
  ## Field Descriptions:
  - title: The exact title of the movie being reviewed.
  - rating: An integer rating from 1 to 5.
  - summary: A one-sentence summary of the review, max 100 characters.
  """
  @primary_key false
  embedded_schema do
    field(:title, :string)
    field(:rating, :integer)
    field(:summary, :string)
  end

  @impl true
  def validate_changeset(changeset) do
    changeset
    |> Ecto.Changeset.validate_required([:title, :rating, :summary])
    |> Ecto.Changeset.validate_number(:rating,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 5
    )
    |> Ecto.Changeset.validate_length(:summary, max: 100)
  end
end

agent =
  Nous.new("openai:gpt-4o-mini",
    output_type: MovieReview,
    structured_output: [max_retries: 3],
    instructions: "You are a movie critic. Write concise reviews."
  )

{:ok, result} = Nous.run(agent, "Review the movie 'The Matrix'")

IO.puts("  Title:   #{result.output.title}")
IO.puts("  Rating:  #{result.output.rating}/5")
IO.puts("  Summary: #{result.output.summary}")
IO.puts("")

# ============================================================================
# Example 4: Choice mode (vLLM/SGLang guided decoding)
# ============================================================================
#
# Constrain the LLM to pick from a fixed set of values.
# This uses guided decoding on vLLM/SGLang for token-level enforcement.
# On other providers, it falls back to prompt-based constraints.

IO.puts("--- Example 4: Choice mode ---")

# Note: Replace "vllm:meta-llama/Llama-3-8b" with your actual vLLM model,
# or use any provider for demonstration (choices are validated client-side).
agent =
  Nous.new("openai:gpt-4o-mini",
    output_type: {:choice, ["positive", "negative", "neutral"]},
    instructions: "You are a sentiment classifier. Respond with only the sentiment label."
  )

{:ok, result} = Nous.run(agent, "Classify: 'This product exceeded all my expectations!'")

IO.puts("  Sentiment: #{result.output}")
IO.puts("")

# ============================================================================
# Example 5: Error handling
# ============================================================================
#
# When validation fails and retries are exhausted, you get a ValidationError.

IO.puts("--- Example 5: Error handling ---")

alias Nous.Errors.ValidationError

agent =
  Nous.new("openai:gpt-4o-mini",
    output_type: SpamPrediction,
    structured_output: [max_retries: 0],
    instructions: "You are an email classifier."
  )

case Nous.run(agent, "Classify this email: 'Hello, how are you?'") do
  {:ok, result} ->
    IO.puts("  Success: #{inspect(result.output)}")

  {:error, %ValidationError{} = err} ->
    IO.puts("  Validation failed: #{err.message}")
    IO.puts("  Errors: #{inspect(err.errors)}")
    IO.puts("  Type:   #{inspect(err.output_type)}")

  {:error, other} ->
    IO.puts("  Other error: #{inspect(other)}")
end

IO.puts("")
IO.puts("Done!")
