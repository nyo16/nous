#!/usr/bin/env elixir

# Multi-region Vertex AI example
#
# Demonstrates:
#   - Testing the same prompt against multiple GCP regions
#   - v1 vs v1beta1 API version selection (stable vs preview models)
#   - Both streaming and non-streaming requests
#
# Prerequisites:
#   export GOOGLE_CLOUD_PROJECT=your-project-id
#   export VERTEX_AI_ACCESS_TOKEN=$(gcloud auth print-access-token)
#
# Run:
#   mix run examples/providers/vertex_ai_multi_region.exs

alias Nous.Providers.VertexAI

project = System.get_env("GOOGLE_CLOUD_PROJECT")
token = System.get_env("VERTEX_AI_ACCESS_TOKEN")

unless project && token do
  IO.puts("""
  Missing environment variables. Set:
    export GOOGLE_CLOUD_PROJECT="your-project-id"
    export VERTEX_AI_ACCESS_TOKEN=$(gcloud auth print-access-token)
  """)

  System.halt(1)
end

regions = ["us-central1", "europe-west1", "asia-northeast1"]
stable_model = "gemini-2.0-flash"
preview_model = "gemini-2.5-pro-preview-06-05"

IO.puts("=== Vertex AI Multi-Region Test ===\n")
IO.puts("Project: #{project}")
IO.puts("Regions: #{Enum.join(regions, ", ")}\n")

# Show v1 vs v1beta1 URL selection
IO.puts("--- API Version Selection ---")
IO.puts("Stable  (#{stable_model}):")
IO.puts("  #{VertexAI.endpoint(project, "us-central1", stable_model)}")
IO.puts("Preview (#{preview_model}):")
IO.puts("  #{VertexAI.endpoint(project, "us-central1", preview_model)}")
IO.puts("")

# Test each region with a non-streaming request
IO.puts("--- Non-Streaming: #{stable_model} ---")

for region <- regions do
  base_url = VertexAI.endpoint(project, region, stable_model)
  IO.puts("\n[#{region}] #{base_url}")

  agent =
    Nous.new("vertex_ai:#{stable_model}",
      instructions: "You are a helpful assistant. Be extremely concise.",
      base_url: base_url,
      api_key: token
    )

  case Nous.run(agent, "What region are you running in? One word answer.") do
    {:ok, result} ->
      IO.puts("[#{region}] Response: #{result.output}")

    {:error, error} ->
      IO.puts("[#{region}] Error: #{inspect(error)}")
  end
end

IO.puts("\n--- Streaming: #{stable_model} ---")

region = hd(regions)
base_url = VertexAI.endpoint(project, region, stable_model)
IO.puts("\n[#{region}] Streaming...")

agent =
  Nous.new("vertex_ai:#{stable_model}",
    instructions: "You are a helpful assistant. Be concise.",
    base_url: base_url,
    api_key: token
  )

case Nous.run_stream(agent, "Write a haiku about cloud computing.") do
  {:ok, stream} ->
    IO.write("[#{region}] ")

    stream
    |> Enum.each(fn
      {:text_delta, text} -> IO.write(text)
      {:thinking_delta, _} -> :ok
      {:finish, _} -> IO.puts("")
      _other -> :ok
    end)

  {:error, error} ->
    IO.puts("[#{region}] Streaming error: #{inspect(error)}")
end

IO.puts("\nDone!")
