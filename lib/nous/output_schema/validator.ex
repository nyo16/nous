defmodule Nous.OutputSchema.Validator do
  @moduledoc """
  Behaviour for structured output validation.

  Implement `validate_changeset/1` in your Ecto schema modules to add
  custom validation rules that the LLM must satisfy. Failed validations
  are sent back to the LLM as retry messages when `max_retries` > 0.

  ## Example

      defmodule SpamPrediction do
        use Ecto.Schema
        use Nous.OutputSchema

        @llm_doc \"""
        ## Field Descriptions:
        - class: Whether or not the email is spam.
        - reason: A short, less than 10 word rationalization.
        - score: A confidence score between 0.0 and 1.0.
        \"""
        @primary_key false
        embedded_schema do
          field :class, Ecto.Enum, values: [:spam, :not_spam]
          field :reason, :string
          field :score, :float
        end

        @impl true
        def validate_changeset(changeset) do
          changeset
          |> Ecto.Changeset.validate_number(:score,
            greater_than_or_equal_to: 0.0,
            less_than_or_equal_to: 1.0
          )
        end
      end

  """

  @doc """
  Apply custom validation rules to the changeset after Ecto casting.

  Return the changeset with any additional validations applied.
  Errors on the changeset will be formatted and sent back to the LLM
  for retry when `max_retries` > 0.
  """
  @callback validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()

  @optional_callbacks [validate_changeset: 1]
end
