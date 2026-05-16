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

## Input Validation

The provider validates `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_LOCATION` at request time
and returns helpful error messages for invalid values instead of opaque DNS or HTTP errors.

## Examples

- [`examples/providers/vertex_ai.exs`](../../examples/providers/vertex_ai.exs) — Basic usage with access token
- [`examples/providers/vertex_ai_goth_test.exs`](../../examples/providers/vertex_ai_goth_test.exs) — Service account with Goth
- [`examples/providers/vertex_ai_multi_region.exs`](../../examples/providers/vertex_ai_multi_region.exs) — Multi-region + v1/v1beta1 demo
- [`examples/providers/vertex_ai_integration_test.exs`](../../examples/providers/vertex_ai_integration_test.exs) — Full integration test (Flash + Pro, streaming + non-streaming)
