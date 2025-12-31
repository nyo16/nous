defmodule Nous.Providers.Mistral do
  @moduledoc """
  Mistral AI provider implementation.

  Uses the OpenAI-compatible API with Mistral-specific extensions:
  - `reasoning_mode` - Enable reasoning mode for complex tasks
  - `prediction_mode` - Enable prediction mode
  - `safe_prompt` - Enable safe prompt filtering

  ## Configuration

  Set your API key via environment variable:

      export MISTRAL_API_KEY="your-mistral-api-key-here"

  Or in config:

      config :nous, :mistral,
        api_key: "your-mistral-api-key-here"

  ## Usage

      # Via Model.parse
      model = Nous.Model.parse("mistral:mistral-large-latest")

      # Direct provider usage
      {:ok, response} = Nous.Providers.Mistral.chat(%{
        "model" => "mistral-large-latest",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

      # With reasoning mode
      {:ok, response} = Nous.Providers.Mistral.chat(%{
        "model" => "mistral-large-latest",
        "messages" => messages,
        "reasoning_mode" => true
      })

  """

  use Nous.Provider,
    id: :mistral,
    default_base_url: "https://api.mistral.ai/v1",
    default_env_key: "MISTRAL_API_KEY"

  alias Nous.Providers.HTTP

  @default_timeout 60_000
  @streaming_timeout 120_000

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    url = "#{base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts))
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    HTTP.post(url, params, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    url = "#{base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts))
    timeout = Keyword.get(opts, :timeout, @streaming_timeout)
    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    params = Map.put(params, "stream", true)

    HTTP.stream(url, params, headers, timeout: timeout, finch_name: finch_name)
  end

  defp build_headers(api_key) do
    headers = [{"content-type", "application/json"}]

    if api_key && api_key != "" do
      [{"authorization", "Bearer #{api_key}"} | headers]
    else
      headers
    end
  end
end
