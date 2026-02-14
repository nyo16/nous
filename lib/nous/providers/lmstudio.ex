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
    url = "#{get_base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts))
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    HTTP.post(url, params, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    url = "#{get_base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts))
    timeout = Keyword.get(opts, :timeout, @streaming_timeout)
    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    params = Map.put(params, "stream", true)

    HTTP.stream(url, params, headers, timeout: timeout, finch_name: finch_name)
  end

  # Get base URL, also checking LMSTUDIO_BASE_URL env var
  defp get_base_url(opts) do
    Keyword.get(opts, :base_url) ||
      System.get_env("LMSTUDIO_BASE_URL") ||
      base_url(opts)
  end

  defp build_headers(api_key) do
    headers = [{"content-type", "application/json"}]

    # LM Studio doesn't require auth, but we support it if configured
    if api_key && api_key != "" do
      [{"authorization", "Bearer #{api_key}"} | headers]
    else
      headers
    end
  end
end
