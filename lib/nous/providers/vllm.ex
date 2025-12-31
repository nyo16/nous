defmodule Nous.Providers.VLLM do
  @moduledoc """
  vLLM provider implementation.

  vLLM is a high-performance inference engine that provides an
  OpenAI-compatible API. By default it runs on `http://localhost:8000/v1`.

  ## Configuration

  No API key is required for local usage. Configure the base URL if needed:

      config :nous, :vllm,
        base_url: "http://localhost:8000/v1"

  Or use environment variable:

      export VLLM_BASE_URL="http://localhost:8000/v1"

  ## Usage

      # Via Model.parse
      model = Nous.Model.parse("vllm:meta-llama/Llama-3-8B-Instruct")

      # Direct provider usage
      {:ok, response} = Nous.Providers.VLLM.chat(%{
        "model" => "meta-llama/Llama-3-8B-Instruct",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

  ## Features

  vLLM supports:
  - OpenAI-compatible chat completions
  - Streaming responses
  - High-throughput batched inference
  - PagedAttention for memory efficiency
  - Tensor parallelism for multi-GPU

  ## vLLM-Specific Parameters

  Additional parameters supported (pass in params map):
  - `best_of` - Number of outputs to generate and return the best
  - `use_beam_search` - Use beam search instead of sampling
  - `ignore_eos` - Ignore end-of-sequence token
  - `skip_special_tokens` - Skip special tokens in output

  """

  use Nous.Provider,
    id: :vllm,
    default_base_url: "http://localhost:8000/v1",
    default_env_key: "VLLM_API_KEY"

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

  # Get base URL, also checking VLLM_BASE_URL env var
  defp get_base_url(opts) do
    Keyword.get(opts, :base_url) ||
      System.get_env("VLLM_BASE_URL") ||
      base_url(opts)
  end

  defp build_headers(api_key) do
    headers = [{"content-type", "application/json"}]

    # vLLM doesn't require auth by default, but we support it if configured
    if api_key && api_key != "" do
      [{"authorization", "Bearer #{api_key}"} | headers]
    else
      headers
    end
  end
end
