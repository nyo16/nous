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

  # Mistral is a hosted OpenAI-compatible endpoint, so `chat/2` and
  # `chat_stream/2` are injected by `Nous.Provider` (`:plain` base URL,
  # `bearer` auth). Mistral-specific params (`reasoning_mode`, `safe_prompt`,
  # …) are passed through in the request body unchanged.
  use Nous.Provider,
    id: :mistral,
    default_base_url: "https://api.mistral.ai/v1",
    default_env_key: "MISTRAL_API_KEY",
    chat: [base_url: :plain, headers: :bearer, timeout: 180_000, stream_timeout: 300_000]
end
