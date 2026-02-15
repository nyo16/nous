defmodule Nous.Providers.OpenAICompatible do
  @moduledoc """
  Generic OpenAI-compatible provider implementation.

  Works with any server that implements the OpenAI Chat Completions API:
  - Groq (api.groq.com)
  - Together (api.together.xyz)
  - OpenRouter (openrouter.ai)
  - LM Studio (localhost)
  - Ollama (localhost)
  - vLLM (localhost)
  - SGLang (localhost)
  - Mistral (api.mistral.ai)
  - Any other OpenAI-compatible endpoint

  For OpenAI-specific features (Responses API, Assistants, etc.), use `Nous.Providers.OpenAI`.

  ## Usage

      # Using with Groq
      {:ok, response} = Nous.Providers.OpenAICompatible.chat(
        %{model: "llama-3.1-70b", messages: messages},
        base_url: "https://api.groq.com/openai/v1",
        api_key: System.get_env("GROQ_API_KEY")
      )

      # Using with local LM Studio
      {:ok, response} = Nous.Providers.OpenAICompatible.chat(
        %{model: "qwen2", messages: messages},
        base_url: "http://localhost:1234/v1"
      )

      # Streaming
      {:ok, stream} = Nous.Providers.OpenAICompatible.chat_stream(params, opts)
      Enum.each(stream, fn event -> IO.inspect(event) end)
  """

  use Nous.Provider,
    id: :openai_compatible,
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
    headers =
      if api_key && api_key != "" && api_key != "not-needed" do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    # Add organization header if provided
    case Keyword.get(opts, :organization) do
      nil -> headers
      org -> [{"openai-organization", org} | headers]
    end
  end
end
