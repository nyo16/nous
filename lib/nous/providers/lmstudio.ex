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

  # LM Studio is local-by-default and speaks the OpenAI `/chat/completions`
  # dialect, so `chat/2` and `chat_stream/2` are injected by `Nous.Provider`.
  # The `:local` strategy reads `LMSTUDIO_BASE_URL` and validates via UrlGuard
  # with `allow_private_hosts: true` (rejects `file://` etc. while allowing
  # localhost); auth is optional (`bearer` headers). Local models may be slower,
  # hence the longer timeouts.
  use Nous.Provider,
    id: :lmstudio,
    display_name: "LM Studio",
    default_base_url: "http://localhost:1234/v1",
    default_env_key: "LMSTUDIO_API_KEY",
    chat: [base_url: :local, headers: :bearer, timeout: 120_000, stream_timeout: 300_000]
end
