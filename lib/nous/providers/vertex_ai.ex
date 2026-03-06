defmodule Nous.Providers.VertexAI do
  @moduledoc """
  Google Vertex AI provider implementation.

  Supports Gemini models via the Vertex AI API, which provides enterprise features
  like VPC-SC, CMEK, and regional endpoints.

  ## Authentication

  Vertex AI uses OAuth2 Bearer tokens (not API keys like Google AI).
  Token resolution order:

  1. `:api_key` option passed directly (treated as a Bearer access token)
  2. Goth integration — if a Goth process name is configured, fetches tokens automatically
  3. `VERTEX_AI_ACCESS_TOKEN` environment variable
  4. Application config: `config :nous, :vertex_ai, api_key: "..."`

  ### Using Goth (Recommended)

  If you already use Goth for Google Cloud services (PubSub, etc.), you can reuse it.
  Goth handles service account credentials, token caching, and auto-refresh via the
  `GOOGLE_APPLICATION_CREDENTIALS` environment variable.

  Add Goth to your deps and supervision tree:

      # mix.exs
      {:goth, "~> 1.4"}

      # application.ex
      children = [
        {Goth, name: MyApp.Goth}
      ]

  Then configure Nous to use it:

      # config.exs
      config :nous, :vertex_ai, goth: MyApp.Goth

  Or pass it per-model:

      model = Model.parse("vertex_ai:gemini-2.0-flash",
        default_settings: %{goth: MyApp.Goth}
      )

  ### Using an Access Token

  You can pass a pre-obtained token (e.g., from `gcloud auth print-access-token`):

      model = Model.parse("vertex_ai:gemini-2.0-flash",
        api_key: System.get_env("VERTEX_AI_ACCESS_TOKEN")
      )

  ## URL Construction

  The base URL is constructed from project and region:

      https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}

  Set via environment variables:

  - `GOOGLE_CLOUD_PROJECT` — GCP project ID
  - `GOOGLE_CLOUD_REGION` — GCP region (defaults to `us-central1`)

  Or pass `:base_url` explicitly:

      model = Model.parse("vertex_ai:gemini-2.0-flash",
        base_url: "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"
      )

  ## Configuration

      # In config.exs
      config :nous, :vertex_ai,
        goth: MyApp.Goth,
        base_url: "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"

  """

  use Nous.Provider,
    id: :vertex_ai,
    # Default is constructed dynamically from env vars in resolve_base_url/1
    default_base_url: "",
    default_env_key: "VERTEX_AI_ACCESS_TOKEN"

  alias Nous.Providers.HTTP

  require Logger

  @default_timeout 60_000
  @streaming_timeout 120_000

  # Override to convert from generic format to Gemini's format (same API format)
  defp build_request_params(model, messages, settings) do
    merged_settings = Map.merge(model.default_settings, settings)

    # Reuse Gemini message format — Vertex AI uses the same content structure
    {system_prompt, contents} = Nous.Messages.to_provider_format(messages, :gemini)

    params = %{"contents" => contents}

    params =
      if system_prompt do
        Map.put(params, "systemInstruction", %{"parts" => [%{"text" => system_prompt}]})
      else
        params
      end

    # Map generic settings to Gemini's generationConfig
    generation_config =
      %{}
      |> maybe_put("temperature", merged_settings[:temperature])
      |> maybe_put("maxOutputTokens", merged_settings[:max_tokens])
      |> maybe_put("topP", merged_settings[:top_p])
      |> maybe_put("stopSequences", merged_settings[:stop_sequences] || merged_settings[:stop])

    # Merge any explicit generationConfig from settings
    generation_config =
      Map.merge(generation_config, merged_settings[:generationConfig] || %{})

    if map_size(generation_config) > 0 do
      Map.put(params, "generationConfig", generation_config)
    else
      params
    end
  end

  # Use Gemini stream normalizer — same response format
  defp default_stream_normalizer, do: Nous.StreamNormalizer.Gemini

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || "gemini-2.0-flash"

    with {:ok, token} <- resolve_token(opts),
         {:ok, url_base} <- resolve_base_url(opts) do
      url = build_url(url_base, model, :generate)
      headers = build_headers(token)
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      # Remove model from params (it's in the URL)
      body = params |> Map.delete("model") |> Map.delete(:model)

      HTTP.post(url, body, headers, timeout: timeout)
    end
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || "gemini-2.0-flash"

    with {:ok, token} <- resolve_token(opts),
         {:ok, url_base} <- resolve_base_url(opts) do
      url = build_url(url_base, model, :stream)
      headers = build_headers(token)
      timeout = Keyword.get(opts, :timeout, @streaming_timeout)
      finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

      # Remove model from params (it's in the URL)
      body = params |> Map.delete("model") |> Map.delete(:model)

      # Vertex AI with ?alt=sse returns SSE format (default parser)
      HTTP.stream(url, body, headers, timeout: timeout, finch_name: finch_name)
    end
  end

  @doc """
  Build a Vertex AI endpoint URL from project ID and region.

  ## Examples

      iex> Nous.Providers.VertexAI.endpoint("my-project", "us-central1")
      "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"

  """
  @spec endpoint(String.t(), String.t()) :: String.t()
  def endpoint(project_id, region \\ "us-central1") do
    "https://#{region}-aiplatform.googleapis.com/v1/projects/#{project_id}/locations/#{region}"
  end

  # Resolve the base URL from options, app config, or env vars
  defp resolve_base_url(opts) do
    url =
      Keyword.get(opts, :base_url) ||
        get_in(Application.get_env(:nous, :vertex_ai, []), [:base_url]) ||
        build_default_base_url()

    if url && url != "" do
      {:ok, url}
    else
      {:error,
       %{
         reason: :no_base_url,
         message:
           "No Vertex AI base URL configured. Provide :base_url option, " <>
             "set GOOGLE_CLOUD_PROJECT environment variable, or configure " <>
             "config :nous, :vertex_ai, base_url: \"...\""
       }}
    end
  end

  # Build URL for Vertex AI endpoints
  defp build_url(base_url, model, :generate) do
    "#{base_url}/publishers/google/models/#{model}:generateContent"
  end

  defp build_url(base_url, model, :stream) do
    "#{base_url}/publishers/google/models/#{model}:streamGenerateContent?alt=sse"
  end

  # Build headers with Bearer token auth
  defp build_headers(token) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{token}"}
    ]
  end

  # Build default base URL from environment variables
  defp build_default_base_url do
    project = System.get_env("GOOGLE_CLOUD_PROJECT") || System.get_env("GCLOUD_PROJECT")
    region = System.get_env("GOOGLE_CLOUD_REGION") || "us-central1"

    if project do
      endpoint(project, region)
    else
      nil
    end
  end

  # Resolve access token from multiple sources
  defp resolve_token(opts) do
    cond do
      # 1. Direct api_key option
      token = api_key(opts) ->
        {:ok, token}

      # 2. Goth integration
      goth_name = goth_name(opts) ->
        fetch_goth_token(goth_name)

      true ->
        {:error,
         %{
           reason: :no_credentials,
           message:
             "No Vertex AI credentials found. Provide :api_key, configure Goth, " <>
               "or set VERTEX_AI_ACCESS_TOKEN environment variable."
         }}
    end
  end

  # Get the configured Goth process name
  defp goth_name(opts) do
    Keyword.get(opts, :goth) ||
      get_in(Application.get_env(:nous, :vertex_ai, []), [:goth])
  end

  # Override build_provider_opts to pass goth name from model settings
  defp build_provider_opts(model) do
    opts = [
      base_url: model.base_url,
      api_key: model.api_key,
      timeout: model.receive_timeout,
      finch_name: Application.get_env(:nous, :finch, Nous.Finch)
    ]

    # Pass goth name from model's default_settings if present
    if goth = model.default_settings[:goth] do
      Keyword.put(opts, :goth, goth)
    else
      opts
    end
  end

  if Code.ensure_loaded?(Goth) do
    defp fetch_goth_token(goth_name) do
      case Goth.fetch(goth_name) do
        {:ok, %{token: token}} ->
          {:ok, token}

        {:error, reason} ->
          Logger.error("Failed to fetch Goth token: #{inspect(reason)}")
          {:error, %{reason: :goth_error, message: "Goth token fetch failed", details: reason}}
      end
    end
  else
    defp fetch_goth_token(_goth_name) do
      {:error,
       %{
         reason: :goth_not_available,
         message:
           "Goth is not available. Add {:goth, \"~> 1.4\"} to your deps " <>
             "or provide an access token via :api_key option."
       }}
    end
  end
end
