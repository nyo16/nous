# Structured Output Guide

Get validated, typed data from LLM responses instead of raw text.

## Overview

Structured output lets you define an expected shape for the LLM's response -- an Ecto schema, a schemaless type map, or a raw JSON schema -- and Nous will instruct the provider to return JSON conforming to that shape, parse the response, validate it with Ecto changesets, and optionally retry on validation failure.

This feature is inspired by [instructor_ex](https://github.com/thmsmlr/instructor_ex) and brings the same pattern into the Nous agent framework, with multi-provider support and guided decoding for vLLM/SGLang.

**When to use structured output:**

- Extracting entities from text (names, dates, classifications)
- Building data pipelines that feed LLM results into downstream code
- Enforcing enums, numeric ranges, or other domain constraints
- Classification and labeling tasks (spam detection, sentiment analysis)
- Any time you need a struct or map instead of a string

## Quick Start

### 1. Ecto Schema Output

Define an Ecto embedded schema and pass it as `output_type`:

```elixir
defmodule UserInfo do
  use Ecto.Schema
  @primary_key false
  embedded_schema do
    field :name, :string
    field :age, :integer
  end
end

agent = Nous.new("openai:gpt-4o-mini", output_type: UserInfo)
{:ok, result} = Nous.run(agent, "Generate a user named Alice, age 30")
result.output
# => %UserInfo{name: "Alice", age: 30}
```

### 2. Schemaless Output

Skip the module definition with a simple type map:

```elixir
agent = Nous.new("openai:gpt-4o-mini",
  output_type: %{name: :string, age: :integer, active: :boolean}
)

{:ok, result} = Nous.run(agent, "Generate a user named Bob, age 25, who is active")
result.output
# => %{name: "Bob", age: 25, active: true}
```

### 3. Raw JSON Schema

Pass a JSON schema map with string keys for full control:

```elixir
agent = Nous.new("openai:gpt-4o-mini",
  output_type: %{
    "type" => "object",
    "properties" => %{
      "answer" => %{"type" => "string"},
      "confidence" => %{"type" => "number"}
    },
    "required" => ["answer", "confidence"]
  }
)

{:ok, result} = Nous.run(agent, "What is the capital of France?")
result.output
# => %{"answer" => "Paris", "confidence" => 0.99}
```

## Schema Definition Patterns

### Basic Ecto Schema

Any Ecto embedded schema works as an output type. Use `@primary_key false` and `embedded_schema` to avoid database-related fields:

```elixir
defmodule SentimentResult do
  use Ecto.Schema
  @primary_key false
  embedded_schema do
    field :sentiment, Ecto.Enum, values: [:positive, :negative, :neutral]
    field :confidence, :float
    field :keywords, {:array, :string}
  end
end
```

### Adding LLM Documentation with `@llm_doc`

Use `use Nous.OutputSchema` to enable the `@llm_doc` attribute. This text is injected into the JSON schema's `"description"` field, giving the LLM additional context about what each field means:

```elixir
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
    field :class, Ecto.Enum, values: [:spam, :not_spam]
    field :reason, :string
    field :score, :float
  end
end
```

### Custom Validation with `validate_changeset/1`

Implement the `validate_changeset/1` callback to add domain-specific validation rules. When validation fails and `max_retries` is configured, the errors are sent back to the LLM so it can correct its output:

```elixir
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
    field :class, Ecto.Enum, values: [:spam, :not_spam]
    field :reason, :string
    field :score, :float
  end

  @impl true
  def validate_changeset(changeset) do
    changeset
    |> Ecto.Changeset.validate_required([:class, :reason, :score])
    |> Ecto.Changeset.validate_number(:score,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> Ecto.Changeset.validate_length(:reason, max: 50)
  end
end
```

### Embedded Schemas (Nested Objects)

Ecto's `embeds_one` and `embeds_many` are supported. Nested schemas are automatically converted into `$ref` and `$defs` entries in the JSON schema:

```elixir
defmodule Address do
  use Ecto.Schema
  @primary_key false
  embedded_schema do
    field :street, :string
    field :city, :string
    field :country, :string
  end
end

defmodule Contact do
  use Ecto.Schema
  @primary_key false
  embedded_schema do
    field :name, :string
    field :email, :string
    embeds_one :address, Address
  end
end

agent = Nous.new("openai:gpt-4o-mini", output_type: Contact)
{:ok, result} = Nous.run(agent, "Generate contact info for Jane Doe in NYC")
result.output.address.city
# => "New York"
```

## Provider Support Matrix

| Provider | `:tool_call` | `:json_schema` | `:json` | `:md_json` | Default (`:auto`) |
|----------|:------------:|:--------------:|:-------:|:----------:|:------------------:|
| OpenAI | Yes | Yes | Yes | Yes | `:json_schema` |
| Anthropic | Yes (native) | -- | -- | Yes | `:tool_call` |
| Gemini | Yes | Yes | Yes | Yes | `:json_schema` |
| vLLM | Yes | Yes | Yes | Yes | `:json_schema` |
| SGLang | Yes | Yes | Yes | Yes | `:json_schema` |
| LM Studio | Yes | Yes | Yes | Yes | `:json_schema` |
| Ollama | Yes | Yes | Yes | Yes | `:json_schema` |
| Groq | Yes | Yes | Yes | Yes | `:json_schema` |
| Mistral | Yes | Yes | Yes | Yes | `:json_schema` |

When you use `:auto` (the default), Nous picks the best mode for each provider. Anthropic uses `:tool_call` because it has native support for returning structured data via tool use. All OpenAI-compatible providers use `:json_schema` for strict schema enforcement.

## Mode Configuration

Set the mode explicitly with the `structured_output` option:

```elixir
agent = Nous.new("openai:gpt-4o-mini",
  output_type: UserInfo,
  structured_output: [mode: :json_schema]
)
```

### Available Modes

**`:auto`** (default) -- Automatically selects the best mode for the provider. This is the recommended setting for most use cases.

**`:tool_call`** -- Injects a synthetic tool named `__structured_output__` and forces the LLM to call it. The tool's parameters are the JSON schema. This is the native approach for Anthropic and works well across providers.

**`:json_schema`** -- Uses the provider's `response_format` API with `type: "json_schema"`. Provides strict schema enforcement on the provider side. Best for OpenAI, vLLM, and SGLang.

**`:json`** -- Uses `response_format: {type: "json_object"}`. Requests JSON output but without strict schema enforcement. Useful as a fallback when `:json_schema` is not available.

**`:md_json`** -- Instructs the LLM to wrap its JSON response in a markdown code fence. Uses a stop token to cut off output after the closing fence. This works with any provider as a universal fallback but is the least reliable mode.

## Validation Retries

When the LLM returns output that fails validation, Nous can automatically retry by sending the validation errors back to the LLM as feedback:

```elixir
agent = Nous.new("openai:gpt-4o-mini",
  output_type: SpamPrediction,
  structured_output: [max_retries: 3]
)

{:ok, result} = Nous.run(agent, "Classify: 'You won a free iPhone!'")
```

With `max_retries: 3`, if the LLM returns a `score` of `1.5` (violating the `<= 1.0` constraint), Nous will:

1. Parse and validate the response
2. Detect the validation error: `score: must be less than or equal to 1.0`
3. Send the errors back to the LLM with a retry message
4. Repeat until validation passes or retries are exhausted

If all retries fail, the final `{:error, %ValidationError{}}` is returned.

## Error Handling

Structured output can fail at two stages: JSON parsing and Ecto validation. Both produce a `%Nous.Errors.ValidationError{}`:

```elixir
alias Nous.Errors.ValidationError

case Nous.run(agent, prompt) do
  {:ok, result} ->
    # result.output is a validated struct or map
    process(result.output)

  {:error, %ValidationError{} = err} ->
    # Structured output validation failed after all retries
    IO.puts("Validation failed: #{err.message}")
    IO.inspect(err.errors, label: "Field errors")
    IO.inspect(err.output_type, label: "Expected type")

  {:error, other} ->
    # Provider error, network error, etc.
    IO.puts("Other error: #{inspect(other)}")
end
```

The `ValidationError` struct contains:

- `message` -- Human-readable error summary
- `errors` -- Keyword list of `{field, {message, opts}}` tuples (same shape as Ecto changeset errors)
- `output_type` -- The output type that failed validation

## vLLM / SGLang Guided Modes

For vLLM and SGLang providers, Nous supports guided decoding modes that constrain the output at the token level. These are more efficient than JSON schema mode for simple constraints because they operate during generation rather than after.

### Choice Mode

Constrain the output to one of a fixed set of strings:

```elixir
agent = Nous.new("vllm:meta-llama/Llama-3-8b",
  output_type: {:choice, ["positive", "negative", "neutral"]}
)

{:ok, result} = Nous.run(agent, "Classify the sentiment: 'I love this product!'")
result.output
# => "positive"
```

### Regex Mode

Constrain the output to match a regular expression:

```elixir
agent = Nous.new("vllm:meta-llama/Llama-3-8b",
  output_type: {:regex, "\\w+@\\w+\\.com"}
)

{:ok, result} = Nous.run(agent, "Generate an email address for John")
result.output
# => "john@example.com"
```

### Grammar Mode

Constrain the output with an EBNF grammar (vLLM only):

```elixir
agent = Nous.new("vllm:meta-llama/Llama-3-8b",
  output_type: {:grammar, """
  root ::= number "+" number "=" number
  number ::= [0-9]+
  """}
)

{:ok, result} = Nous.run(agent, "Write a simple addition equation")
result.output
# => "2+3=5"
```

## Supported Ecto Types

The following Ecto types are mapped to JSON schema types:

| Ecto Type | JSON Schema Type |
|-----------|-----------------|
| `:string` | `"string"` |
| `:integer` | `"integer"` |
| `:float` | `"number"` (format: float) |
| `:boolean` | `"boolean"` |
| `:decimal` | `"number"` |
| `:date` | `"string"` (format: date) |
| `:utc_datetime` | `"string"` (format: date-time) |
| `:naive_datetime` | `"string"` (format: date-time) |
| `:map` | `"object"` |
| `Ecto.UUID` | `"string"` (format: uuid) |
| `Ecto.Enum` | `"string"` with `"enum"` values |
| `{:array, type}` | `"array"` with typed items |

## Best Practices

**Choose the right output type for the job.** Use Ecto schemas when you need validation, documentation, and reusable types. Use schemaless maps for quick prototyping. Use raw JSON schema when you need features that Ecto does not express (e.g., `minLength`, `pattern`).

**Always set `max_retries` in production.** LLMs occasionally produce output that does not pass validation, especially for numeric ranges and enum values. A retry count of 2-3 handles most transient failures without excessive cost.

**Use `@llm_doc` to guide the LLM.** Clear field descriptions significantly reduce validation failures. Tell the LLM what range a number should be in, what format a string should follow, and what each enum value means.

**Use `validate_changeset/1` for domain rules.** Ecto's built-in validators (`validate_number`, `validate_length`, `validate_format`, `validate_inclusion`) are your first line of defense. Custom validators can enforce cross-field constraints.

**Prefer `:auto` mode.** Let Nous pick the best mechanism for each provider. Only override when you have a specific reason, such as testing the `:md_json` fallback or forcing `:tool_call` for a provider where `:json_schema` is unreliable.

**Keep schemas focused.** Smaller schemas with fewer fields produce more reliable results. If you need a complex output, consider breaking it into multiple agent calls with simpler schemas.

**Test your schemas independently.** You can unit-test the JSON schema conversion and validation without making LLM calls:

```elixir
# Test JSON schema generation
schema = Nous.OutputSchema.to_json_schema(SpamPrediction)
assert schema["properties"]["score"]["type"] == "number"

# Test validation
assert {:ok, %SpamPrediction{}} =
  Nous.OutputSchema.parse_and_validate(
    ~s({"class": "spam", "reason": "too good to be true", "score": 0.95}),
    SpamPrediction
  )

assert {:error, %Nous.Errors.ValidationError{}} =
  Nous.OutputSchema.parse_and_validate(
    ~s({"class": "spam", "reason": "too good to be true", "score": 1.5}),
    SpamPrediction
  )
```
