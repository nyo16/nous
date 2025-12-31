defmodule Nous.Providers.SGLang do
  @moduledoc """
  SGLang provider implementation.

  SGLang (Structured Generation Language) is a framework for efficient
  LLM serving with an OpenAI-compatible API. By default it runs on
  `http://localhost:30000/v1`.

  ## Configuration

  No API key is required for local usage. Configure the base URL if needed:

      config :nous, :sglang,
        base_url: "http://localhost:30000/v1"

  Or use environment variable:

      export SGLANG_BASE_URL="http://localhost:30000/v1"

  ## Usage

      # Via ModelParser
      model = Nous.ModelParser.parse("sglang:meta-llama/Llama-3-8B-Instruct")

      # Direct provider usage
      {:ok, response} = Nous.Providers.SGLang.chat(%{
        "model" => "meta-llama/Llama-3-8B-Instruct",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

  ## Features

  SGLang supports:
  - OpenAI-compatible chat completions
  - Streaming responses
  - RadixAttention for KV cache reuse
  - Constrained decoding (JSON, regex)
  - Speculative decoding
  - Multi-modal inputs

  ## SGLang-Specific Parameters

  Additional parameters supported (pass in params map):
  - `regex` - Constrain output to match a regex pattern
  - `json_schema` - Constrain output to match a JSON schema

  """

  use Nous.Provider,
    id: :sglang,
    default_base_url: "http://localhost:30000/v1",
    default_env_key: "SGLANG_API_KEY"

  alias Nous.Providers.HTTP

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

  # Get base URL, also checking SGLANG_BASE_URL env var
  defp get_base_url(opts) do
    Keyword.get(opts, :base_url) ||
      System.get_env("SGLANG_BASE_URL") ||
      base_url(opts)
  end

  defp build_headers(api_key) do
    headers = [{"content-type", "application/json"}]

    # SGLang doesn't require auth by default, but we support it if configured
    if api_key && api_key != "" do
      [{"authorization", "Bearer #{api_key}"} | headers]
    else
      headers
    end
  end
end
