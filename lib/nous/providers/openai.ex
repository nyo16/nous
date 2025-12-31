defmodule Nous.Providers.OpenAI do
  @moduledoc """
  OpenAI-compatible provider implementation.

  Supports OpenAI and all OpenAI-compatible APIs:
  - OpenAI (api.openai.com)
  - Groq (api.groq.com)
  - Together (api.together.xyz)
  - OpenRouter (openrouter.ai)
  - LM Studio (localhost)
  - Ollama (localhost)
  - vLLM (localhost)
  - SGLang (localhost)
  - Any other OpenAI-compatible endpoint

  ## Usage

      # Using defaults (OpenAI)
      {:ok, response} = Nous.Providers.OpenAI.chat(%{
        model: "gpt-4",
        messages: [%{"role" => "user", "content" => "Hello"}]
      })

      # Using a different provider
      {:ok, response} = Nous.Providers.OpenAI.chat(
        %{model: "llama-3.1-70b", messages: messages},
        base_url: "https://api.groq.com/openai/v1",
        api_key: System.get_env("GROQ_API_KEY")
      )

      # Streaming
      {:ok, stream} = Nous.Providers.OpenAI.chat_stream(params)
      Enum.each(stream, fn event -> IO.inspect(event) end)
  """

  use Nous.Provider,
    id: :openai,
    default_base_url: "https://api.openai.com/v1",
    default_env_key: "OPENAI_API_KEY"

  alias Nous.Providers.HTTP

  @default_timeout 60_000
  @streaming_timeout 120_000

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    url = "#{base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    HTTP.post(url, params, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    url = "#{base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @streaming_timeout)
    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    # Ensure stream is enabled
    params = Map.put(params, "stream", true)

    HTTP.stream(url, params, headers, timeout: timeout, finch_name: finch_name)
  end

  # Build headers for the request
  defp build_headers(api_key, opts) do
    headers = [
      {"content-type", "application/json"}
    ]

    # Add authorization if API key provided
    headers = if api_key && api_key != "" && api_key != "not-needed" do
      [{"authorization", "Bearer #{api_key}"} | headers]
    else
      headers
    end

    # Add organization header if provided
    headers = case Keyword.get(opts, :organization) do
      nil -> headers
      org -> [{"openai-organization", org} | headers]
    end

    headers
  end
end
