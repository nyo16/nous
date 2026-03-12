#!/usr/bin/env elixir

# Integration test for Vertex AI provider hardening
#
# Tests the v1/v1beta1 fix, GOOGLE_CLOUD_LOCATION support, and validation.
#
# Credentials (pick one):
#   1. Service account JSON in env var:
#      export GOOGLE_CREDENTIALS='{"type":"service_account",...}'
#
#   2. Service account JSON file path (standard GCP convention):
#      export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
#
#   3. Pre-obtained access token:
#      export VERTEX_AI_ACCESS_TOKEN=$(gcloud auth print-access-token)
#
# Required:
#   export GOOGLE_CLOUD_PROJECT="your-project-id"
#
# Optional:
#   export GOOGLE_CLOUD_REGION="us-central1"        # defaults to us-central1
#   export GOOGLE_CLOUD_LOCATION="us-central1"      # fallback for REGION
#
# Run:
#   mix run examples/providers/vertex_ai_integration_test.exs

alias Nous.Providers.VertexAI

project = System.get_env("GOOGLE_CLOUD_PROJECT")

unless project do
  IO.puts("""
  Missing GOOGLE_CLOUD_PROJECT. Set:
    export GOOGLE_CLOUD_PROJECT="your-project-id"

  Also provide credentials via one of:
    export GOOGLE_CREDENTIALS='<service account JSON>'
    export GOOGLE_APPLICATION_CREDENTIALS="/path/to/sa.json"
    export VERTEX_AI_ACCESS_TOKEN=$(gcloud auth print-access-token)
  """)

  System.halt(1)
end

# --- Resolve credentials ---
{auth_method, agent_opts} =
  cond do
    json = System.get_env("GOOGLE_CREDENTIALS") ->
      credentials = Jason.decode!(json)

      {:ok, _} =
        Goth.start_link(name: Nous.IntegrationGoth, source: {:service_account, credentials})

      {"Goth (GOOGLE_CREDENTIALS)", %{goth: Nous.IntegrationGoth}}

    path = System.get_env("GOOGLE_APPLICATION_CREDENTIALS") ->
      credentials = path |> File.read!() |> Jason.decode!()

      {:ok, _} =
        Goth.start_link(name: Nous.IntegrationGoth, source: {:service_account, credentials})

      {"Goth (GOOGLE_APPLICATION_CREDENTIALS: #{path})", %{goth: Nous.IntegrationGoth}}

    token = System.get_env("VERTEX_AI_ACCESS_TOKEN") ->
      {"Access token (VERTEX_AI_ACCESS_TOKEN)", %{api_key: token}}

    true ->
      IO.puts(
        "No credentials found. Set GOOGLE_CREDENTIALS, GOOGLE_APPLICATION_CREDENTIALS, or VERTEX_AI_ACCESS_TOKEN."
      )

      System.halt(1)
  end

region =
  System.get_env("GOOGLE_CLOUD_REGION") ||
    System.get_env("GOOGLE_CLOUD_LOCATION") ||
    "us-central1"

IO.puts("=== Vertex AI Integration Test ===\n")
IO.puts("Project:  #{project}")
IO.puts("Region:   #{region}")
IO.puts("Auth:     #{auth_method}\n")

# Helper to build agent opts
make_agent = fn model_name, extra_opts ->
  opts =
    [instructions: "You are a helpful assistant. Be extremely concise — one sentence max."]
    |> Keyword.merge(extra_opts)

  default_settings = Map.merge(agent_opts, Keyword.get(opts, :default_settings, %{}))
  opts = Keyword.put(opts, :default_settings, default_settings)

  # If using access token, pass as api_key
  opts =
    if api_key = agent_opts[:api_key] do
      Keyword.put_new(opts, :api_key, api_key)
    else
      opts
    end

  Nous.new("vertex_ai:#{model_name}", opts)
end

passed = 0
failed = 0

run_test = fn name, fun ->
  IO.write("  #{name}... ")

  try do
    case fun.() do
      :ok ->
        IO.puts("PASS")
        {:ok, :pass}

      {:error, reason} ->
        IO.puts("FAIL: #{inspect(reason)}")
        {:ok, :fail}
    end
  rescue
    e ->
      IO.puts("ERROR: #{Exception.message(e)}")
      {:ok, :fail}
  end
end

global_url_flash = VertexAI.endpoint(project, "global", "gemini-3-flash-preview")
global_url_pro = VertexAI.endpoint(project, "global", "gemini-3.1-pro-preview")

results =
  [
    # --- URL construction tests ---
    {"v1beta1 URL for preview model",
     fn ->
       url = VertexAI.endpoint(project, "global", "gemini-3.1-pro-preview")

       if url =~ "/v1beta1/projects/" do
         IO.write("(#{url}) ")
         :ok
       else
         {:error, "Expected v1beta1 URL, got: #{url}"}
       end
     end},
    {"global endpoint uses aiplatform.googleapis.com (no region prefix)",
     fn ->
       url = VertexAI.endpoint(project, "global", "gemini-3.1-pro-preview")

       if url =~ "https://aiplatform.googleapis.com/" and url =~ "/locations/global" do
         IO.write("(#{url}) ")
         :ok
       else
         {:error, "Expected global URL, got: #{url}"}
       end
     end},
    {"Model.parse base_url is nil (deferred to provider)",
     fn ->
       model = Nous.Model.parse("vertex_ai:gemini-3.1-pro-preview")

       if model.base_url == nil do
         :ok
       else
         {:error, "Expected nil base_url, got: #{inspect(model.base_url)}"}
       end
     end},

    # --- Flash model (global) ---
    {"Flash non-streaming (gemini-3-flash-preview, global)",
     fn ->
       agent = make_agent.("gemini-3-flash-preview", base_url: global_url_flash)

       case Nous.run(agent, "Say hello in exactly 3 words.") do
         {:ok, result} ->
           IO.write("(#{result.output}) ")
           :ok

         {:error, error} ->
           {:error, error}
       end
     end},
    {"Flash streaming (gemini-3-flash-preview, global)",
     fn ->
       agent = make_agent.("gemini-3-flash-preview", base_url: global_url_flash)

       case Nous.run_stream(agent, "Say goodbye in exactly 3 words.") do
         {:ok, stream} ->
           IO.write("(")

           stream
           |> Enum.each(fn
             {:text_delta, text} -> IO.write(text)
             {:finish, _} -> IO.write(") ")
             _ -> :ok
           end)

           :ok

         {:error, error} ->
           {:error, error}
       end
     end},

    # --- Pro model (global) ---
    {"Pro non-streaming (gemini-3.1-pro-preview, global)",
     fn ->
       agent = make_agent.("gemini-3.1-pro-preview", base_url: global_url_pro)

       case Nous.run(agent, "Say 'pro works' and nothing else.") do
         {:ok, result} ->
           IO.write("(#{result.output}) ")
           :ok

         {:error, error} ->
           {:error, error}
       end
     end},
    {"Pro streaming (gemini-3.1-pro-preview, global)",
     fn ->
       agent = make_agent.("gemini-3.1-pro-preview", base_url: global_url_pro)

       case Nous.run_stream(agent, "Say 'streaming pro' and nothing else.") do
         {:ok, stream} ->
           IO.write("(")

           stream
           |> Enum.each(fn
             {:text_delta, text} -> IO.write(text)
             {:finish, _} -> IO.write(") ")
             _ -> :ok
           end)

           :ok

         {:error, error} ->
           {:error, error}
       end
     end}
  ]

IO.puts("--- Running #{length(results)} tests ---\n")

outcomes =
  Enum.map(results, fn {name, fun} ->
    {_, result} = run_test.(name, fun)
    result
  end)

pass_count = Enum.count(outcomes, &(&1 == :pass))
fail_count = Enum.count(outcomes, &(&1 == :fail))

IO.puts("\n--- Results: #{pass_count} passed, #{fail_count} failed out of #{length(results)} ---")

if fail_count > 0 do
  System.halt(1)
end
