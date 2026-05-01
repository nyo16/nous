defmodule Nous.Providers.VertexAI do
  @moduledoc """
  Google Vertex AI provider implementation.

  Supports Gemini models via the Vertex AI API, which provides enterprise features
  like VPC-SC, CMEK, IAM, and regional/global endpoints.

  ## Supported Models

  | Model                    | Model ID                       | Endpoint       | API Version |
  |--------------------------|--------------------------------|----------------|-------------|
  | Gemini 3.1 Pro (preview) | `gemini-3.1-pro-preview`       | global only    | v1beta1     |
  | Gemini 3 Flash (preview) | `gemini-3-flash-preview`       | global only    | v1beta1     |
  | Gemini 3.1 Flash-Lite    | `gemini-3.1-flash-lite-preview`| global only    | v1beta1     |
  | Gemini 2.5 Pro           | `gemini-2.5-pro`               | regional/global| v1          |
  | Gemini 2.5 Flash         | `gemini-2.5-flash`             | regional/global| v1          |
  | Gemini 2.0 Flash         | `gemini-2.0-flash`             | regional/global| v1          |

  Preview and experimental models automatically use the `v1beta1` API version.
  Stable models use `v1`. This is determined by `api_version_for_model/1`.

  ## Authentication

  Vertex AI uses OAuth2 Bearer tokens (not API keys like Google AI).
  Token resolution order:

  1. `:api_key` option passed directly (treated as a Bearer access token)
  2. Goth integration — if a Goth process name is configured, fetches tokens automatically
  3. `VERTEX_AI_ACCESS_TOKEN` environment variable
  4. Application config: `config :nous, :vertex_ai, api_key: "..."`

  ### Using Goth with a Service Account (Recommended)

  Goth handles OAuth2 token fetching, caching, and auto-refresh from a GCP service account.
  Load the service account JSON from an environment variable (no file path dependency):

      # Set env vars:
      # export GOOGLE_CREDENTIALS='{"type":"service_account","project_id":"...",...}'
      # export GOOGLE_CLOUD_PROJECT="your-project-id"
      # export GOOGLE_CLOUD_LOCATION="global"  # required for Gemini 3.x preview

      # mix.exs
      {:goth, "~> 1.4"}

      # application.ex — start Goth in your supervision tree
      credentials = System.get_env("GOOGLE_CREDENTIALS") |> JSON.decode!()

      children = [
        {Goth, name: MyApp.Goth, source: {:service_account, credentials}}
      ]

  Then configure Nous to use it:

      # config.exs (recommended for production)
      config :nous, :vertex_ai, goth: MyApp.Goth

      # Then just use it:
      agent = Nous.new("vertex_ai:gemini-3.1-pro-preview")
      {:ok, result} = Nous.run(agent, "Hello!")

  Or pass Goth per-model (useful for multiple projects):

      agent = Nous.new("vertex_ai:gemini-3-flash-preview",
        default_settings: %{goth: MyApp.Goth}
      )

  ### Using an Access Token

  For quick testing without Goth (tokens expire after ~1 hour):

      # export VERTEX_AI_ACCESS_TOKEN="$(gcloud auth print-access-token)"
      agent = Nous.new("vertex_ai:gemini-3.1-pro-preview")

  Or pass it explicitly:

      agent = Nous.new("vertex_ai:gemini-3.1-pro-preview",
        api_key: System.get_env("VERTEX_AI_ACCESS_TOKEN")
      )

  ## URL Construction

  The base URL is built at request time from environment variables and the model name.
  The provider selects the correct hostname and API version automatically.

  ### Regional Endpoints (for stable models)

      https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}

  ### Global Endpoint (required for Gemini 3.x preview models)

      https://aiplatform.googleapis.com/v1beta1/projects/{project}/locations/global

  ### Environment Variables

  - `GOOGLE_CLOUD_PROJECT` (or `GCLOUD_PROJECT`) — GCP project ID (required)
  - `GOOGLE_CLOUD_REGION` (or `GOOGLE_CLOUD_LOCATION`) — GCP region or `global` (defaults to `us-central1`)

  Both `GOOGLE_CLOUD_REGION` and `GOOGLE_CLOUD_LOCATION` are supported, consistent with
  other Google Cloud libraries and tooling. `GOOGLE_CLOUD_REGION` takes precedence if both
  are set.

  ### Explicit Base URL

  You can override the auto-constructed URL entirely:

      alias Nous.Providers.VertexAI

      # Use the endpoint helper to build the URL with correct API version:
      url = VertexAI.endpoint("my-project", "global", "gemini-3.1-pro-preview")
      # => "https://aiplatform.googleapis.com/v1beta1/projects/my-project/locations/global"

      agent = Nous.new("vertex_ai:gemini-3.1-pro-preview", base_url: url)

  ## Input Validation

  The provider validates `GOOGLE_CLOUD_PROJECT` and the region at request time and returns
  helpful error messages for invalid values (e.g., typos, wrong format) instead of opaque
  DNS or HTTP errors.

  ## Configuration

      # config.exs
      config :nous, :vertex_ai,
        goth: MyApp.Goth

      # Or with an explicit base_url (overrides env var URL construction):
      config :nous, :vertex_ai,
        goth: MyApp.Goth,
        base_url: "https://aiplatform.googleapis.com/v1beta1/projects/my-project/locations/global"

  ## Examples

      # Gemini 3.1 Pro on global endpoint (preview, v1beta1)
      agent = Nous.new("vertex_ai:gemini-3.1-pro-preview")

      # Gemini 3 Flash on global endpoint (preview, v1beta1)
      agent = Nous.new("vertex_ai:gemini-3-flash-preview")

      # Gemini 2.0 Flash on regional endpoint (stable, v1)
      agent = Nous.new("vertex_ai:gemini-2.0-flash")

      # With explicit region override
      agent = Nous.new("vertex_ai:gemini-3.1-pro-preview",
        base_url: VertexAI.endpoint("my-project", "global", "gemini-3.1-pro-preview")
      )

  """

  use Nous.Provider,
    id: :vertex_ai,
    # Default is constructed dynamically from env vars in resolve_base_url/1
    default_base_url: "",
    default_env_key: "VERTEX_AI_ACCESS_TOKEN"

  alias Nous.Providers.HTTP

  require Logger

  @default_timeout 180_000
  @streaming_timeout 300_000

  # Override to convert from generic format to Gemini's format (same API format)
  defp build_request_params(model, messages, settings) do
    merged_settings = Map.merge(model.default_settings, settings)

    # Reuse Gemini message format — Vertex AI uses the same content structure
    {system_prompt, contents} = Nous.Messages.to_provider_format(messages, :gemini)

    params = %{"model" => model.model, "contents" => contents}

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

    params =
      if map_size(generation_config) > 0 do
        Map.put(params, "generationConfig", generation_config)
      else
        params
      end

    maybe_merge_extra_body(params, merged_settings[:extra_body])
  end

  # Use Gemini stream normalizer — same response format
  defp default_stream_normalizer, do: Nous.StreamNormalizer.Gemini

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || "gemini-2.0-flash"

    with {:ok, token} <- resolve_token(opts),
         {:ok, url_base} <- resolve_base_url(opts, model) do
      url = build_url(url_base, model, :generate)
      headers = build_headers(token)
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      Logger.debug("Vertex AI chat request: url=#{url}, model=#{model}")

      # Remove model from params (it's in the URL)
      body = params |> Map.delete("model") |> Map.delete(:model)

      HTTP.post(url, body, headers, timeout: timeout)
    end
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || "gemini-2.0-flash"

    with {:ok, token} <- resolve_token(opts),
         {:ok, url_base} <- resolve_base_url(opts, model) do
      url = build_url(url_base, model, :stream)
      headers = build_headers(token)
      timeout = Keyword.get(opts, :timeout, @streaming_timeout)
      finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

      Logger.debug("Vertex AI stream request: url=#{url}, model=#{model}")

      # Remove model from params (it's in the URL)
      body = params |> Map.delete("model") |> Map.delete(:model)

      # Vertex AI with ?alt=sse returns SSE format (default parser)
      HTTP.stream(url, body, headers, timeout: timeout, finch_name: finch_name)
    end
  end

  @doc """
  Build a Vertex AI endpoint URL from project ID, region, and optional model name.

  Uses `v1beta1` API version for preview/experimental models and `v1` for stable models.
  If no model name is provided, defaults to `v1`.

  When region is `"global"`, uses `aiplatform.googleapis.com` (no region prefix).
  Regional endpoints use `{region}-aiplatform.googleapis.com`.

  Gemini 3.x preview models (`gemini-3.1-pro-preview`, `gemini-3-flash-preview`, etc.)
  are only available on the global endpoint.

  ## Examples

      # Regional endpoint, stable model (v1)
      iex> Nous.Providers.VertexAI.endpoint("my-project", "us-central1")
      "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"

      iex> Nous.Providers.VertexAI.endpoint("my-project", "us-central1", "gemini-2.0-flash")
      "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"

      # Global endpoint, preview model (v1beta1) — required for Gemini 3.x
      iex> Nous.Providers.VertexAI.endpoint("my-project", "global", "gemini-3.1-pro-preview")
      "https://aiplatform.googleapis.com/v1beta1/projects/my-project/locations/global"

      iex> Nous.Providers.VertexAI.endpoint("my-project", "global", "gemini-3-flash-preview")
      "https://aiplatform.googleapis.com/v1beta1/projects/my-project/locations/global"

  """
  @spec endpoint(String.t(), String.t(), String.t() | nil) :: String.t()
  def endpoint(project_id, region \\ "us-central1", model \\ nil) do
    api_version = api_version_for_model(model)

    host =
      if region == "global" do
        "aiplatform.googleapis.com"
      else
        "#{region}-aiplatform.googleapis.com"
      end

    "https://#{host}/#{api_version}/projects/#{project_id}/locations/#{region}"
  end

  @doc """
  Returns the appropriate API version for a model name.

  Preview and experimental models use `v1beta1`, stable models use `v1`.
  """
  @spec api_version_for_model(String.t() | nil) :: String.t()
  def api_version_for_model(nil), do: "v1"

  def api_version_for_model(model) when is_binary(model) do
    if String.contains?(model, "preview") or String.contains?(model, "experimental") do
      "v1beta1"
    else
      "v1"
    end
  end

  # Resolve the base URL from options, app config, or env vars.
  # When building from env vars, uses the model name to determine the API version.
  defp resolve_base_url(opts, model) do
    explicit_url =
      Keyword.get(opts, :base_url) ||
        get_in(Application.get_env(:nous, :vertex_ai, []), [:base_url])

    cond do
      explicit_url && explicit_url != "" ->
        {:ok, explicit_url}

      true ->
        case build_default_base_url(model) do
          {:ok, url} ->
            {:ok, url}

          {:error, _} = error ->
            error

          :not_configured ->
            {:error,
             %{
               reason: :no_base_url,
               message:
                 "No Vertex AI base URL configured. Provide :base_url option, " <>
                   "set GOOGLE_CLOUD_PROJECT or GOOGLE_CLOUD_LOCATION environment variable, or configure " <>
                   "config :nous, :vertex_ai, base_url: \"...\""
             }}
        end
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
  defp build_default_base_url(model) do
    project = System.get_env("GOOGLE_CLOUD_PROJECT") || System.get_env("GCLOUD_PROJECT")

    region =
      System.get_env("GOOGLE_CLOUD_REGION") ||
        System.get_env("GOOGLE_CLOUD_LOCATION") ||
        "us-central1"

    if project do
      with {:ok, project} <- validate_project_id(project),
           {:ok, region} <- validate_region(region) do
        {:ok, endpoint(project, region, model)}
      end
    else
      :not_configured
    end
  end

  # Validates a GCP project ID matches the expected format.
  defp validate_project_id(nil) do
    {:error,
     %{
       reason: :invalid_project_id,
       message: "GOOGLE_CLOUD_PROJECT is not set."
     }}
  end

  defp validate_project_id(project) do
    if Regex.match?(~r/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/, project) do
      {:ok, project}
    else
      {:error,
       %{
         reason: :invalid_project_id,
         message:
           "Invalid GCP project ID: #{inspect(project)}. " <>
             "Project IDs must be 6-30 characters, start with a letter, " <>
             "and contain only lowercase letters, digits, and hyphens."
       }}
    end
  end

  # Validates a GCP region matches the expected format (e.g., us-central1, global).
  defp validate_region(region) do
    if Regex.match?(~r/^[a-z]+-[a-z]+\d+$/, region) or region == "global" do
      {:ok, region}
    else
      {:error,
       %{
         reason: :invalid_region,
         message:
           "Invalid GCP region: #{inspect(region)}. " <>
             "Expected format like 'us-central1', 'europe-west1', or 'global'."
       }}
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
