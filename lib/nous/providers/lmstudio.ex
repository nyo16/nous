defmodule Nous.Providers.LMStudio do
  @moduledoc """
  LM Studio local provider implementation.

  LM Studio provides a local OpenAI-compatible API server for running
  models locally. By default it runs on `http://localhost:1234/v1`.

  ## Configuration

  No API key is required for local usage. Configure the base URL if needed:

      config :nous, :lmstudio,
        base_url: "http://localhost:1234/v1"

  Or use environment variable:

      export LMSTUDIO_BASE_URL="http://localhost:1234/v1"

  ## Usage

      # Via Model.parse
      model = Nous.Model.parse("lmstudio:my-local-model")

      # Direct provider usage
      {:ok, response} = Nous.Providers.LMStudio.chat(%{
        "model" => "my-local-model",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

  ## Features

  LM Studio supports:
  - OpenAI-compatible chat completions
  - Streaming responses
  - Tool/function calling (model-dependent)
  - Various open-source models (Llama, Mistral, etc.)

  """

  use Nous.Provider,
    id: :lmstudio,
    default_base_url: "http://localhost:1234/v1",
    default_env_key: "LMSTUDIO_API_KEY"

  alias Nous.Providers.HTTP

  # Local models may be slower
  @default_timeout 120_000
  @streaming_timeout 300_000

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    with {:ok, base} <- get_base_url(opts) do
      url = "#{base}/chat/completions"
      headers = build_headers(api_key(opts))
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      HTTP.post(url, params, headers, timeout: timeout)
    end
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    with {:ok, base} <- get_base_url(opts) do
      url = "#{base}/chat/completions"
      headers = build_headers(api_key(opts))
      timeout = Keyword.get(opts, :timeout, @streaming_timeout)

      params = Map.put(params, "stream", true)

      HTTP.stream(url, params, headers, timeout: timeout)
    end
  end

  # Resolve and validate the base URL. The resolved URL goes through
  # `Nous.Tools.UrlGuard` with `allow_private_hosts: true` (LM Studio is
  # local-by-default) to reject malformed schemes (`file://` etc.) while
  # still allowing the localhost default. Returns `{:ok, base}` on success
  # or `{:error, {:invalid_config, reason}}` so callers can pattern-match
  # without rescuing exceptions.
  defp get_base_url(opts) do
    base =
      Keyword.get(opts, :base_url) ||
        System.get_env("LMSTUDIO_BASE_URL") ||
        base_url(opts)

    case Nous.Tools.UrlGuard.validate(base, allow_private_hosts: true) do
      {:ok, _uri} ->
        {:ok, base}

      {:error, reason} ->
        {:error,
         {:invalid_config,
          "LM Studio base_url failed validation: #{reason}. Got: #{inspect(base)}"}}
    end
  end

  # LM Studio doesn't require auth, but we support it if configured.
  # `HTTP.bearer_auth_header/1` returns `[]` for nil / empty / "not-needed".
  defp build_headers(api_key) do
    HTTP.json_headers() ++ HTTP.bearer_auth_header(api_key)
  end
end
