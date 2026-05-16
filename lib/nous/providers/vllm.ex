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
  # `Nous.Tools.UrlGuard` with `allow_private_hosts: true` (vLLM is
  # local-by-default) to reject malformed schemes (`file://` etc.) while
  # still allowing the localhost default. Returns `{:ok, base}` on success
  # or `{:error, {:invalid_config, reason}}` so callers can pattern-match
  # without rescuing exceptions.
  defp get_base_url(opts) do
    base =
      Keyword.get(opts, :base_url) ||
        System.get_env("VLLM_BASE_URL") ||
        base_url(opts)

    case Nous.Tools.UrlGuard.validate(base, allow_private_hosts: true) do
      {:ok, _uri} ->
        {:ok, base}

      {:error, reason} ->
        {:error,
         {:invalid_config, "vLLM base_url failed validation: #{reason}. Got: #{inspect(base)}"}}
    end
  end

  # vLLM doesn't require auth by default, but we support it if configured.
  # `HTTP.bearer_auth_header/1` returns `[]` for nil / empty / "not-needed".
  defp build_headers(api_key) do
    HTTP.json_headers() ++ HTTP.bearer_auth_header(api_key)
  end
end
