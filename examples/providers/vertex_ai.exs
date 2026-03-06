#!/usr/bin/env elixir

# Nous AI - Google Vertex AI Provider
#
# Vertex AI provides enterprise access to Gemini models with features like
# VPC-SC, CMEK, regional endpoints, and IAM-based access control.
#
# Prerequisites:
#   - A Google Cloud project with Vertex AI API enabled
#   - Authentication (one of):
#     a) Access token: `export VERTEX_AI_ACCESS_TOKEN=$(gcloud auth print-access-token)`
#     b) Goth with service account: `export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa.json`
#   - Project configuration:
#     `export GOOGLE_CLOUD_PROJECT=your-project-id`
#     `export GOOGLE_CLOUD_REGION=us-central1`  (optional, defaults to us-central1)

IO.puts("=== Nous AI - Vertex AI Provider ===\n")

# ============================================================================
# Option 1: Using environment variables
# ============================================================================

IO.puts("--- Setup with Environment Variables ---")

project = System.get_env("GOOGLE_CLOUD_PROJECT")
token = System.get_env("VERTEX_AI_ACCESS_TOKEN")

if project && token do
  IO.puts("Project: #{project}")
  IO.puts("Region: #{System.get_env("GOOGLE_CLOUD_REGION", "us-central1")}\n")

  # With env vars set, just use the model string
  agent =
    Nous.new("vertex_ai:gemini-2.0-flash",
      instructions: "You are a helpful assistant. Be concise."
    )

  case Nous.run(agent, "What is Elixir? Answer in one sentence.") do
    {:ok, result} ->
      IO.puts("Response: #{result.output}")
      IO.puts("Tokens: #{result.usage.total_tokens}")

    {:error, error} ->
      IO.puts("Error: #{inspect(error)}")
  end
else
  IO.puts("""
  Skipping: Set these environment variables to test:
    export GOOGLE_CLOUD_PROJECT=your-project-id
    export VERTEX_AI_ACCESS_TOKEN=$(gcloud auth print-access-token)
  """)
end

IO.puts("")

# ============================================================================
# Option 2: Explicit configuration
# ============================================================================

IO.puts("--- Explicit Configuration ---")

IO.puts("""
# Pass base_url and api_key directly:
model = Nous.Model.parse("vertex_ai:gemini-2.0-flash",
  base_url: Nous.Providers.VertexAI.endpoint("my-project", "us-central1"),
  api_key: access_token
)
""")

# ============================================================================
# Option 3: Using Goth (recommended for production)
# ============================================================================

IO.puts("--- Goth Integration (Production) ---")

IO.puts("""
# 1. Add {:goth, "~> 1.4"} to your deps
# 2. Start Goth in your supervision tree:
#
#    children = [
#      {Goth, name: MyApp.Goth}
#    ]
#
# 3. Set GOOGLE_APPLICATION_CREDENTIALS to your service account JSON
# 4. Configure Nous:
#
#    config :nous, :vertex_ai,
#      goth: MyApp.Goth,
#      base_url: "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"
#
# 5. Use it:
#    agent = Nous.new("vertex_ai:gemini-2.0-flash")
""")

# ============================================================================
# Streaming
# ============================================================================

IO.puts("--- Streaming ---")

if project && token do
  agent =
    Nous.new("vertex_ai:gemini-2.0-flash",
      instructions: "You are a helpful assistant."
    )

  case Nous.run_stream(agent, "Write a haiku about Elixir.") do
    {:ok, stream} ->
      stream
      |> Enum.each(fn
        {:text_delta, text} -> IO.write(text)
        {:finish, _} -> IO.puts("\n")
        _ -> :ok
      end)

    {:error, error} ->
      IO.puts("Streaming error: #{inspect(error)}")
  end
else
  IO.puts("Skipping streaming demo (no credentials)\n")
end

# ============================================================================
# Available Gemini Models on Vertex AI
# ============================================================================

IO.puts("--- Available Models ---")

IO.puts("""
Model                          | Description
-------------------------------|-------------------------------------------
gemini-2.0-flash               | Fast, efficient for most tasks
gemini-2.0-flash-lite          | Lightweight, lowest latency
gemini-2.5-pro-preview-06-05   | Most capable, best for complex reasoning
gemini-2.5-flash-preview-05-20 | Balanced speed and capability
""")
