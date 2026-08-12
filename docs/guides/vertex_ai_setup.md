# Google Vertex AI Setup

[Back to README](../../README.md#supported-providers)

Vertex AI is Google Cloud's enterprise platform for accessing Gemini models with
VPC-SC, CMEK, IAM, regional/global endpoints, and the latest preview models.
Use it when you need GCP-native auth, data residency, or features that aren't
on the public Gemini API (Vertex-only previews, enterprise compliance).

## Supported Models

| Model | Model ID | Endpoint | API Version |
|-------|----------|----------|-------------|
| Gemini 3.1 Pro (preview) | `gemini-3.1-pro-preview` | global only | v1beta1 |
| Gemini 3 Flash (preview) | `gemini-3-flash-preview` | global only | v1beta1 |
| Gemini 3.1 Flash-Lite (preview) | `gemini-3.1-flash-lite-preview` | global only | v1beta1 |
| Gemini 2.5 Pro | `gemini-2.5-pro` | regional + global | v1 |
| Gemini 2.5 Flash | `gemini-2.5-flash` | regional + global | v1 |
| Gemini 2.0 Flash | `gemini-2.0-flash` | regional + global | v1 |

> **Note:** Preview and experimental models automatically use the `v1beta1` API version.
> The Gemini 3.x preview models are **global endpoint only** — set `GOOGLE_CLOUD_LOCATION=global`.

## Regional vs Global Endpoints

Vertex AI offers two endpoint types:

- **Regional** (e.g., `us-central1`, `europe-west1`): Low-latency, data residency guarantees
  ```
  https://us-central1-aiplatform.googleapis.com/v1/projects/{project}/locations/us-central1
  ```
- **Global**: Higher availability, required for Gemini 3.x preview models
  ```
  https://aiplatform.googleapis.com/v1beta1/projects/{project}/locations/global
  ```

The provider automatically selects the correct hostname and API version based on the
region and model name. Set `GOOGLE_CLOUD_LOCATION=global` for Gemini 3.x preview models.

## Step 1: Create a Service Account

```bash
export PROJECT_ID="your-project-id"

# Enable Vertex AI API
gcloud services enable aiplatform.googleapis.com --project=$PROJECT_ID

# Create service account
gcloud iam service-accounts create nous-vertex-ai \
  --display-name="Nous Vertex AI" \
  --project=$PROJECT_ID

# Grant the Vertex AI User role
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:nous-vertex-ai@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user"

# Download the key file
gcloud iam service-accounts keys create /tmp/sa-key.json \
  --iam-account="nous-vertex-ai@${PROJECT_ID}.iam.gserviceaccount.com"
```

## Step 2: Set Environment Variables

```bash
# Load the service account JSON into an env var (recommended — no file path dependency)
export GOOGLE_CREDENTIALS="$(cat /tmp/sa-key.json)"

# Required: your GCP project ID
export GOOGLE_CLOUD_PROJECT="your-project-id"

# Required for Gemini 3.x preview models (global endpoint only)
export GOOGLE_CLOUD_LOCATION="global"

# Or use a regional endpoint for stable models:
# export GOOGLE_CLOUD_LOCATION="us-central1"
# export GOOGLE_CLOUD_LOCATION="europe-west1"
```

Both `GOOGLE_CLOUD_REGION` and `GOOGLE_CLOUD_LOCATION` are supported (consistent with
other Google Cloud libraries). `GOOGLE_CLOUD_REGION` takes precedence if both are set.
Defaults to `us-central1` if neither is set.

## Step 3: Add Goth to Your Application

Goth handles OAuth2 token fetching and auto-refresh from the service account credentials.

```elixir
# mix.exs
{:goth, "~> 1.4"}
```

```elixir
# application.ex — start Goth in your supervision tree
credentials = System.get_env("GOOGLE_CREDENTIALS") |> JSON.decode!()

children = [
  {Goth, name: MyApp.Goth, source: {:service_account, credentials}}
]
```

## Step 4: Configure and Use

```elixir
# Option A: App config (recommended for production)
# config/config.exs
config :nous, :vertex_ai, goth: MyApp.Goth

# Then use it — Goth handles token refresh automatically:
agent = Nous.new("vertex_ai:gemini-3.1-pro-preview")
{:ok, result} = Nous.run(agent, "Hello from Vertex AI!")
```

```elixir
# Option B: Per-model Goth (useful for multiple projects)
agent = Nous.new("vertex_ai:gemini-3-flash-preview",
  default_settings: %{goth: MyApp.Goth}
)
```

```elixir
# Option C: Explicit base_url (for custom endpoint or specific region)
alias Nous.Providers.VertexAI

agent = Nous.new("vertex_ai:gemini-3.1-pro-preview",
  base_url: VertexAI.endpoint("my-project", "global", "gemini-3.1-pro-preview"),
  default_settings: %{goth: MyApp.Goth}
)
```

```elixir
# Option D: Quick testing with gcloud CLI (no Goth needed)
# export VERTEX_AI_ACCESS_TOKEN="$(gcloud auth print-access-token)"
agent = Nous.new("vertex_ai:gemini-3.1-pro-preview")
```

## Model settings

Everything below is passed as **model settings** — a plain map that Nous merges into the
Vertex `generateContent` request body. Settings live at three layers, each merged over the
previous one:

```elixir
# Model layer — stored on the %Nous.Model{} struct behind the agent
agent = Nous.new("vertex_ai:gemini-2.5-pro", default_settings: %{temperature: 0.2})

# Agent layer — merged over the model layer
agent = Nous.new("vertex_ai:gemini-2.5-pro", model_settings: %{temperature: 0.2})

# Run layer — merged over the agent layer, for a single call
{:ok, result} = Nous.run(agent, "Summarize this.", model_settings: %{temperature: 0.9})
```

Any setting you leave out is omitted from the request entirely — Nous never substitutes a
value of its own for the keys in this section, so the API's defaults apply.

This whole surface is **shared between `vertex_ai:` and `gemini:`**. Both providers build
their request body through `Nous.Messages.Gemini.build_request_params/3` (same wire
format), so every key works identically against either prefix; whether a given *value* is
accepted (a preview model, a Vertex-only native tool) is an API-side question, not a
library one. The only Vertex-specific setting is `:goth`, and it is read from the **model
layer only** — `default_settings: %{goth: MyApp.Goth}` or
`config :nous, :vertex_ai, goth: MyApp.Goth` (see [Step 4](#step-4-configure-and-use)).
Putting `:goth` in `model_settings:` has no effect.

| Setting | Request field | Accepted shape | Default |
|---------|---------------|----------------|---------|
| `:thinking_config` | `generationConfig.thinkingConfig` | Map, either `%{thinking_budget: integer, include_thoughts: boolean}` or native `%{"thinkingBudget" => …, "includeThoughts" => …}`; unrecognized keys pass through | omitted |
| `:json_response` | `generationConfig.responseMimeType` | `true` — sets `"application/json"` with no schema | omitted |
| `:json_schema` | `generationConfig.responseMimeType` + `responseSchema` | Map (a JSON schema); also forces the JSON mime type | omitted |
| `:safety_settings` | `safetySettings` (top level) | List of maps, atom- or string-keyed (`%{category: ..., threshold: ...}`); atom keys are stringified, unknown keys pass through | omitted |
| `:tool_choice` | `toolConfig.functionCallingConfig` | `:auto`, `:any`, `:required`, `:none`, `{:any, ["fn_a", ...]}`, or a raw map | omitted |
| `:tool_config` | `toolConfig` (top level) | Raw map, passed through as-is; takes precedence over `:tool_choice` | omitted |
| `:native_tools` | extra entries in `tools` (top level) | List of `:google_search`, `:url_context`, `:code_execution`, `{name, config_map}` tuples, or raw maps | omitted |
| `:cached_content` | `cachedContent` (top level) | Passed through unvalidated; Vertex expects a cached-content resource name | omitted |
| `:response_modalities` | `generationConfig.responseModalities` | List of modality strings, passed through unchanged | omitted |
| `:candidate_count` | `generationConfig.candidateCount` | Integer, passed through unchanged | omitted |
| `:seed` | `generationConfig.seed` | Integer, passed through unchanged | omitted |
| `:top_k` | `generationConfig.topK` | Integer, passed through unchanged | omitted |

The familiar cross-provider keys map here too: `:temperature`, `:max_tokens` →
`maxOutputTokens`, `:top_p` → `topP`, `:presence_penalty`, `:frequency_penalty`, and
`:stop_sequences` (or `:stop`) → `stopSequences`. Two escape hatches cover anything not
listed: `:generationConfig` (a raw map, merged last into `generationConfig`) and
`:extra_body` (merged into the top-level body, subject to the provider's blocked-key
policy).

### Thinking

`:thinking_config` maps to `generationConfig.thinkingConfig` for Gemini 2.5/3.x. Elixir
keys (`thinking_budget`, `include_thoughts`) are camelized for you; native camelCase string
keys are accepted verbatim, and any key Nous does not recognize is forwarded unchanged, so
newer Vertex fields work without a library bump.

```elixir
agent =
  Nous.new("vertex_ai:gemini-2.5-pro",
    model_settings: %{
      thinking_config: %{thinking_budget: 1024, include_thoughts: true}
    }
  )

{:ok, result} = Nous.run(agent, "Prove that the square root of 2 is irrational.")
result.output
```

With `include_thoughts: true`, thought summaries arrive as the assistant message's
`reasoning_content` rather than in `output`. For tool-using thinking models, Vertex's
`thoughtSignature` is preserved on each parsed tool call and echoed back on the next turn
automatically — no configuration needed.

### JSON output

Three settings feed Gemini's `responseMimeType` / `responseSchema` pair, in this priority
order: `:json_schema` (a map) wins, then `:response_format`
(`%{type: :json_schema, schema: schema}` or `%{type: :json_object}`, the cross-provider
shape), then `:json_response` (a boolean, mime type only).

```elixir
# Loose JSON: responseMimeType only, no schema enforcement
agent = Nous.new("gemini:gemini-2.5-flash", model_settings: %{json_response: true})

# Schema-constrained JSON: responseMimeType + responseSchema
schema = %{
  "type" => "object",
  "properties" => %{
    "city" => %{"type" => "string"},
    "population" => %{"type" => "integer"}
  },
  "required" => ["city", "population"]
}

agent = Nous.new("vertex_ai:gemini-2.5-flash", model_settings: %{json_schema: schema})
{:ok, result} = Nous.run(agent, "Which is the largest city in Japan, and how big is it?")
result.output
```

These are the raw provider knobs. If you want a validated Elixir struct back instead of a
JSON string, use the agent-level `output_type:` option — see the
[Structured Output guide](structured_output.md), which drives these same fields for you.

### Safety settings

`:safety_settings` is a list of category/threshold maps placed at the top level of the
request as `safetySettings`. Atom keys are stringified; entries written with string keys are
passed through, as are keys Nous does not know about (e.g. `"method"`).

```elixir
agent =
  Nous.new("vertex_ai:gemini-2.5-flash",
    model_settings: %{
      safety_settings: [
        %{category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_ONLY_HIGH"},
        %{"category" => "HARM_CATEGORY_HARASSMENT", "threshold" => "BLOCK_NONE"}
      ]
    }
  )

{:ok, result} = Nous.run(agent, "Summarize this support ticket.")
result.output
```

### Function calling, tool choice, and native tools

**Function calling works on Vertex and Gemini.** As of 0.16.0, tool declarations are
serialized into Vertex's `tools[].functionDeclarations` format via
`Nous.ToolSchema.to_gemini/1` (which drops OpenAI's `strict` field and the schema keys
Vertex rejects — `additionalProperties` and `$schema`, recursively). Notes claiming that
tools are silently dropped for these providers describe pre-0.16.0 behaviour — pass
`tools:` exactly as you would for any other provider.

`:tool_choice` accepts the friendly forms `:auto`, `:any` / `:required`, `:none`, and
`{:any, ["fn_a", "fn_b"]}` (which becomes `allowedFunctionNames`); a raw map is passed
through. `:native_tools` adds Vertex's built-in tools alongside your function declarations.

```elixir
defmodule WeatherTools do
  @doc "Get the current weather for a city"
  def get_weather(%{"city" => city}, _deps) do
    {:ok, "18C and clear in #{city}"}
  end
end

agent =
  Nous.new("vertex_ai:gemini-2.5-flash",
    tools: [&WeatherTools.get_weather/2],
    model_settings: %{
      tool_choice: {:any, ["get_weather"]},
      native_tools: [:google_search]
    }
  )

{:ok, result} = Nous.run(agent, "What is the weather in Kyoto right now?")
result.output
```

`:native_tools` entries may be bare atoms (`:google_search` → `%{"googleSearch" => %{}}`,
`:url_context` → `%{"urlContext" => %{}}`, `:code_execution` → `%{"codeExecution" => %{}}`),
`{name, config_map}` tuples for tools that take configuration (the name is camelized), or a
raw map when you want full control.

When you need a `toolConfig` shape Nous does not model, set `:tool_config` directly. It is
used verbatim and takes precedence over `:tool_choice`:

```elixir
agent =
  Nous.new("gemini:gemini-2.5-flash",
    tools: [&WeatherTools.get_weather/2],
    model_settings: %{
      tool_config: %{
        "functionCallingConfig" => %{
          "mode" => "ANY",
          "allowedFunctionNames" => ["get_weather"]
        }
      }
    }
  )

{:ok, result} = Nous.run(agent, "Weather in Osaka?")
result.output
```

### Sampling and generation config

`:top_k`, `:seed`, `:candidate_count`, and `:response_modalities` are forwarded into
`generationConfig` unchanged (as `topK`, `seed`, `candidateCount`, `responseModalities`),
next to the cross-provider sampling keys:

```elixir
agent =
  Nous.new("gemini:gemini-2.5-flash",
    model_settings: %{
      temperature: 0.2,
      max_tokens: 2048,
      top_p: 0.95,
      top_k: 40,
      seed: 42,
      candidate_count: 1,
      response_modalities: ["TEXT"],
      stop_sequences: ["\n\n"]
    }
  )

{:ok, result} = Nous.run(agent, "Give me three product names.")
result.output
```

Note on `:candidate_count`: Nous parses only the first candidate of a response (streaming
and non-streaming alike), so asking for more than one candidate costs output tokens without
surfacing the extra completions.

### Context caching

`:cached_content` is a pass-through of Vertex's top-level `cachedContent` field. Nous
neither creates nor validates caches — create one with the Vertex REST API and reference the
resource name it returns:

```elixir
agent =
  Nous.new("vertex_ai:gemini-2.5-flash",
    model_settings: %{
      cached_content:
        "projects/my-project/locations/us-central1/cachedContents/1234567890"
    }
  )

{:ok, result} = Nous.run(agent, "Given the cached contract, when does it expire?")
result.usage.cache_read_input_tokens
```

Cache hits come back from Vertex as `usageMetadata.cachedContentTokenCount`, which Nous
parses into `usage.cache_read_input_tokens`.

## Input Validation

The provider validates `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_LOCATION` at request time
and returns helpful error messages for invalid values instead of opaque DNS or HTTP errors.

## Examples

- [`examples/providers/vertex_ai.exs`](../../examples/providers/vertex_ai.exs) — Basic usage with access token
- [`examples/providers/vertex_ai_goth_test.exs`](../../examples/providers/vertex_ai_goth_test.exs) — Service account with Goth
- [`examples/providers/vertex_ai_multi_region.exs`](../../examples/providers/vertex_ai_multi_region.exs) — Multi-region + v1/v1beta1 demo
- [`examples/providers/vertex_ai_integration_test.exs`](../../examples/providers/vertex_ai_integration_test.exs) — Full integration test (Flash + Pro, streaming + non-streaming)
