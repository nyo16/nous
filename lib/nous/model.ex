defmodule Nous.Model do
  @moduledoc """
  Model configuration for LLM providers.

  This module defines the model configuration structure used by all
  model adapters to connect to various LLM providers.

  ## Example

      model = Model.new(:openai, "gpt-4",
        api_key: "sk-...",
        default_settings: %{temperature: 0.7}
      )

  """

  @type provider :: :openai | :anthropic | :gemini | :groq | :ollama | :lmstudio | :openrouter | :together | :vllm | :mistral | :custom

  @type t :: %__MODULE__{
          provider: provider(),
          model: String.t(),
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          organization: String.t() | nil,
          receive_timeout: non_neg_integer(),
          default_settings: map(),
          stream_normalizer: module() | nil
        }

  @enforce_keys [:provider, :model]
  defstruct [
    :provider,
    :model,
    :base_url,
    :api_key,
    :organization,
    :stream_normalizer,
    receive_timeout: 60_000,  # 60 seconds default (OpenaiEx default is 15s which is too short for local models)
    default_settings: %{}
  ]

  @doc """
  Create a new model configuration.

  ## Parameters

    * `provider` - Provider atom (`:openai`, `:groq`, `:ollama`, etc.)
    * `model` - Model name string
    * `opts` - Optional configuration

  ## Options

    * `:base_url` - Custom API base URL
    * `:api_key` - API key (defaults to environment config)
    * `:organization` - Organization ID (for OpenAI)
    * `:receive_timeout` - HTTP receive timeout in milliseconds (default: 60000).
      Increase this for local models that may take longer to respond.
    * `:default_settings` - Default model settings (temperature, max_tokens, etc.)
    * `:stream_normalizer` - Custom stream normalizer module implementing `Nous.StreamNormalizer` behaviour

  ## Example

      model = Model.new(:openai, "gpt-4",
        api_key: "sk-...",
        default_settings: %{temperature: 0.7, max_tokens: 1000}
      )

      # For slow local models, increase the timeout
      model = Model.new(:lmstudio, "qwen/qwen3-4b",
        receive_timeout: 120_000  # 2 minutes
      )

  """
  @spec new(provider(), String.t(), keyword()) :: t()
  def new(provider, model, opts \\ []) do
    %__MODULE__{
      provider: provider,
      model: model,
      base_url: Keyword.get(opts, :base_url, default_base_url(provider)),
      api_key: Keyword.get(opts, :api_key, default_api_key(provider)),
      organization: Keyword.get(opts, :organization),
      receive_timeout: Keyword.get(opts, :receive_timeout, default_receive_timeout(provider)),
      default_settings: Keyword.get(opts, :default_settings, %{}),
      stream_normalizer: Keyword.get(opts, :stream_normalizer)
    }
  end

  # Private functions

  @spec default_base_url(provider()) :: String.t()
  defp default_base_url(:openai), do: "https://api.openai.com/v1"
  defp default_base_url(:anthropic), do: "https://api.anthropic.com"
  defp default_base_url(:gemini), do: "https://generativelanguage.googleapis.com"
  defp default_base_url(:groq), do: "https://api.groq.com/openai/v1"
  defp default_base_url(:ollama), do: "http://localhost:11434/v1"
  defp default_base_url(:lmstudio), do: "http://localhost:1234/v1"
  defp default_base_url(:openrouter), do: "https://openrouter.ai/api/v1"
  defp default_base_url(:together), do: "https://api.together.xyz/v1"
  defp default_base_url(:mistral), do: "https://api.mistral.ai/v1"
  defp default_base_url(:vllm), do: nil  # vLLM requires explicit base_url
  defp default_base_url(:custom), do: nil

  @spec default_api_key(provider()) :: String.t() | nil
  defp default_api_key(:openai), do: Application.get_env(:nous, :openai_api_key)
  defp default_api_key(:anthropic), do: Application.get_env(:nous, :anthropic_api_key)
  defp default_api_key(:gemini), do: Application.get_env(:nous, :google_ai_api_key)
  defp default_api_key(:groq), do: Application.get_env(:nous, :groq_api_key)
  defp default_api_key(:openrouter), do: Application.get_env(:nous, :openrouter_api_key)
  defp default_api_key(:together), do: Application.get_env(:nous, :together_api_key)
  defp default_api_key(:mistral), do: Application.get_env(:nous, :mistral_api_key)
  defp default_api_key(:ollama), do: "ollama"
  defp default_api_key(:lmstudio), do: "not-needed"
  defp default_api_key(:vllm), do: nil  # vLLM API key is optional
  defp default_api_key(:custom), do: nil

  # Default receive timeouts per provider
  # Local providers get longer timeouts since they're typically slower
  @spec default_receive_timeout(provider()) :: non_neg_integer()
  defp default_receive_timeout(:ollama), do: 120_000     # 2 minutes for local Ollama
  defp default_receive_timeout(:lmstudio), do: 120_000   # 2 minutes for local LM Studio
  defp default_receive_timeout(:vllm), do: 120_000       # 2 minutes for local vLLM
  defp default_receive_timeout(:custom), do: 120_000     # 2 minutes for custom endpoints
  defp default_receive_timeout(_provider), do: 60_000    # 60 seconds for cloud providers
end
