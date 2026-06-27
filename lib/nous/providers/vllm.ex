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

  # vLLM is local-by-default and speaks the OpenAI `/chat/completions` dialect,
  # so `chat/2` and `chat_stream/2` are injected by `Nous.Provider`. The
  # `:local` strategy reads `VLLM_BASE_URL` and validates via UrlGuard with
  # `allow_private_hosts: true` (rejects `file://` etc. while allowing
  # localhost); auth is optional (`bearer` headers).
  use Nous.Provider,
    id: :vllm,
    display_name: "vLLM",
    default_base_url: "http://localhost:8000/v1",
    default_env_key: "VLLM_API_KEY",
    chat: [base_url: :local, headers: :bearer, timeout: 120_000, stream_timeout: 300_000]
end
