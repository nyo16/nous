#!/usr/bin/env elixir

# Quick test script for Vertex AI with service account (Goth)
#
# Prerequisites:
#   export GOOGLE_CREDENTIALS='{"type":"service_account","project_id":"...","private_key":"...",...}'
#   export GOOGLE_CLOUD_PROJECT="your-project-id"
#   export GOOGLE_CLOUD_REGION="us-central1"  # optional
#
# Run:
#   mix run test_vertex_ai.exs

credentials_json = System.get_env("GOOGLE_CREDENTIALS")
project = System.get_env("GOOGLE_CLOUD_PROJECT")

unless credentials_json && project do
  IO.puts("""
  Missing environment variables. Set:
    export GOOGLE_CREDENTIALS='<service account JSON content>'
    export GOOGLE_CLOUD_PROJECT="your-project-id"
  """)

  System.halt(1)
end

IO.puts("=== Vertex AI Test with Service Account ===\n")
IO.puts("Project: #{project}")
IO.puts("Region: #{System.get_env("GOOGLE_CLOUD_REGION", "us-central1")}\n")

# Start Goth with service account credentials from env var
credentials = Jason.decode!(credentials_json)

{:ok, _} = Goth.start_link(name: Nous.TestGoth, source: {:service_account, credentials})

IO.puts("Goth started successfully.\n")

# --- Test 1: Non-streaming ---
IO.puts("--- Test 1: Non-streaming ---")

agent =
  Nous.new("vertex_ai:gemini-2.0-flash",
    instructions: "You are a helpful assistant. Be concise.",
    default_settings: %{goth: Nous.TestGoth}
  )

case Nous.run(agent, "What is Elixir? Answer in one sentence.") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")

# --- Test 2: Streaming ---
IO.puts("--- Test 2: Streaming ---")

case Nous.run_stream(agent, "Write a haiku about functional programming.") do
  {:ok, stream} ->
    stream
    |> Enum.each(fn
      {:text_delta, text} -> IO.write(text)
      {:thinking_delta, _} -> :ok
      {:finish, _} -> IO.puts("")
      other -> IO.puts("\n[Event: #{inspect(other)}]")
    end)

  {:error, error} ->
    IO.puts("Streaming error: #{inspect(error)}")
end

IO.puts("\nDone!")
