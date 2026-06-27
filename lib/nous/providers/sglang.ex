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

      # Via Model.parse
      model = Nous.Model.parse("sglang:meta-llama/Llama-3-8B-Instruct")

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

  # SGLang is local-by-default and speaks the OpenAI `/chat/completions` dialect,
  # so `chat/2` and `chat_stream/2` are injected by `Nous.Provider`. The
  # `:local` strategy reads `SGLANG_BASE_URL` and validates via UrlGuard with
  # `allow_private_hosts: true` (rejects `file://` etc. while allowing
  # localhost); auth is optional (`bearer` headers).
  use Nous.Provider,
    id: :sglang,
    display_name: "SGLang",
    default_base_url: "http://localhost:30000/v1",
    default_env_key: "SGLANG_API_KEY",
    chat: [base_url: :local, headers: :bearer, timeout: 120_000, stream_timeout: 300_000]
end
