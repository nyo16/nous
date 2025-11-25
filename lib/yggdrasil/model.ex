defmodule Yggdrasil.Model do
  @moduledoc """
  Model configuration for OpenAI-compatible APIs.

  This module defines the model configuration structure and provides
  utilities for converting the configuration to an OpenaiEx client.

  ## Example

      model = Model.new(:openai, "gpt-4",
        api_key: "sk-...",
        default_settings: %{temperature: 0.7}
      )

      client = Model.to_client(model)

  """

  @type provider :: :openai | :anthropic | :gemini | :groq | :ollama | :lmstudio | :openrouter | :together | :vllm | :custom

  @type t :: %__MODULE__{
          provider: provider(),
          model: String.t(),
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          organization: String.t() | nil,
          default_settings: map()
        }

  @enforce_keys [:provider, :model]
  defstruct [
    :provider,
    :model,
    :base_url,
    :api_key,
    :organization,
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
    * `:default_settings` - Default model settings (temperature, max_tokens, etc.)

  ## Example

      model = Model.new(:openai, "gpt-4",
        api_key: "sk-...",
        default_settings: %{temperature: 0.7, max_tokens: 1000}
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
      default_settings: Keyword.get(opts, :default_settings, %{})
    }
  end

  @doc """
  Convert model configuration to OpenaiEx client.

  Creates an OpenaiEx.Client configured with the model's
  base URL, API key, and HTTP options.

  ## Example

      model = Model.new(:openai, "gpt-4")
      client = Model.to_client(model)
      # Use client with OpenaiEx.Chat.Completions

  """
  @spec to_client(t()) :: struct()
  def to_client(%__MODULE__{} = model) do
    # OpenaiEx.new(token, organization \\ nil, project \\ nil)
    # It uses simple positional arguments, not keyword opts
    # We'll need to set base_url and finch separately

    client = OpenaiEx.new(
      model.api_key || "not-needed",
      model.organization
    )

    # Override base_url if different from default
    client = if model.base_url do
      %{client | base_url: model.base_url}
    else
      client
    end

    # Set finch pool name
    client = %{client | finch_name: Application.get_env(:yggdrasil, :finch, Yggdrasil.Finch)}

    client
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
  defp default_base_url(:vllm), do: nil  # vLLM requires explicit base_url
  defp default_base_url(:custom), do: nil

  @spec default_api_key(provider()) :: String.t() | nil
  defp default_api_key(:openai), do: Application.get_env(:yggdrasil, :openai_api_key)
  defp default_api_key(:anthropic), do: Application.get_env(:yggdrasil, :anthropic_api_key)
  defp default_api_key(:gemini), do: Application.get_env(:yggdrasil, :google_ai_api_key)
  defp default_api_key(:groq), do: Application.get_env(:yggdrasil, :groq_api_key)
  defp default_api_key(:openrouter), do: Application.get_env(:yggdrasil, :openrouter_api_key)
  defp default_api_key(:together), do: Application.get_env(:yggdrasil, :together_api_key)
  defp default_api_key(:ollama), do: "ollama"
  defp default_api_key(:lmstudio), do: "not-needed"
  defp default_api_key(:vllm), do: nil  # vLLM API key is optional
  defp default_api_key(:custom), do: nil
end
