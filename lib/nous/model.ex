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

  @type provider ::
          :openai
          | :anthropic
          | :gemini
          | :vertex_ai
          | :groq
          | :ollama
          | :lmstudio
          | :llamacpp
          | :openrouter
          | :together
          | :vllm
          | :sglang
          | :mistral
          | :custom

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
    # 3 minutes default — LLMs with reasoning/long completions routinely
    # exceed shorter timeouts; local models can be slower still.
    receive_timeout: 180_000,
    default_settings: %{}
  ]

  @doc """
  Parse a model string into a Model struct.

  Supports the format `"provider:model-name"` for convenient model specification.

  ## Supported Formats

    * `"openai:gpt-4"` - OpenAI models
    * `"anthropic:claude-3-5-sonnet-20241022"` - Anthropic Claude
    * `"gemini:gemini-1.5-pro"` - Google Gemini
    * `"vertex_ai:gemini-2.0-flash"` - Google Vertex AI
    * `"groq:llama-3.1-70b-versatile"` - Groq models
    * `"mistral:mistral-large-latest"` - Mistral models
    * `"ollama:llama2"` - Local Ollama
    * `"lmstudio:qwen3-vl-4b-thinking-mlx"` - Local LM Studio
    * `"llamacpp:local"` - Local LlamaCpp NIF (requires `:llamacpp_model` option)
    * `"vllm:qwen3-vl-4b-thinking-mlx"` - vLLM server
    * `"sglang:meta-llama/Llama-3-8B"` - SGLang server
    * `"openrouter:anthropic/claude-3.5-sonnet"` - OpenRouter
    * `"together:meta-llama/Llama-3-70b-chat-hf"` - Together AI
    * `"custom:my-model"` - Custom OpenAI-compatible endpoint (requires `:base_url` option)

  > **Note**: The `"custom:"` prefix is the recommended approach for any OpenAI-compatible
  > endpoint. The legacy `"openai_compatible:"` prefix still works for backward compatibility.

  ## Examples

      iex> %Model{provider: provider, model: model} = Model.parse("openai:gpt-4")
      iex> {provider, model}
      {:openai, "gpt-4"}

      iex> %Model{provider: provider, model: model} = Model.parse("ollama:llama2")
      iex> {provider, model}
      {:ollama, "llama2"}

      iex> model = Model.parse("custom:my-model", base_url: "http://localhost:8080/v1")
      iex> {model.provider, model.model, model.base_url}
      {:custom, "my-model", "http://localhost:8080/v1"}

  ## Custom Providers with base_url

  The `custom:` prefix works with any OpenAI-compatible endpoint:

      # Groq
      Model.parse("custom:llama-3.1-70b",
        base_url: "https://api.groq.com/openai/v1",
        api_key: System.get_env("GROQ_API_KEY")
      )

      # Together AI
      Model.parse("custom:meta-llama/Llama-3-70b",
        base_url: "https://api.together.xyz/v1",
        api_key: System.get_env("TOGETHER_API_KEY")
      )

      # Local server (LM Studio, Ollama, etc.)
      Model.parse("custom:qwen3", base_url: "http://localhost:1234/v1")

  Also supports `CUSTOM_API_KEY` and `CUSTOM_BASE_URL` environment variables
  as defaults (can be overridden per-call).

  """
  @spec parse(String.t(), keyword()) :: t()
  def parse(model_string, opts \\ [])

  def parse("openai:" <> model_name, opts), do: new(:openai, model_name, opts)
  def parse("anthropic:" <> model_name, opts), do: new(:anthropic, model_name, opts)
  def parse("gemini:" <> model_name, opts), do: new(:gemini, model_name, opts)
  def parse("vertex_ai:" <> model_name, opts), do: new(:vertex_ai, model_name, opts)
  def parse("groq:" <> model_name, opts), do: new(:groq, model_name, opts)
  def parse("mistral:" <> model_name, opts), do: new(:mistral, model_name, opts)
  def parse("ollama:" <> model_name, opts), do: new(:ollama, model_name, opts)
  def parse("lmstudio:" <> model_name, opts), do: new(:lmstudio, model_name, opts)
  def parse("openrouter:" <> model_name, opts), do: new(:openrouter, model_name, opts)
  def parse("together:" <> model_name, opts), do: new(:together, model_name, opts)

  def parse("vllm:" <> model_name, opts) do
    unless Keyword.has_key?(opts, :base_url) do
      raise ArgumentError,
            "vllm provider requires :base_url option. " <>
              "Example: parse(\"vllm:my-model\", base_url: \"http://localhost:8000/v1\")"
    end

    new(:vllm, model_name, opts)
  end

  def parse("sglang:" <> model_name, opts), do: new(:sglang, model_name, opts)

  def parse("llamacpp:" <> model_name, opts) do
    {llamacpp_model, opts} = Keyword.pop(opts, :llamacpp_model)

    opts =
      if llamacpp_model do
        default_settings = Keyword.get(opts, :default_settings, %{})

        Keyword.put(
          opts,
          :default_settings,
          Map.put(default_settings, :llamacpp_model, llamacpp_model)
        )
      else
        opts
      end

    new(:llamacpp, model_name, opts)
  end

  def parse("custom:" <> model_name, opts) do
    # Check for base_url in opts, env var, or application config
    base_url =
      Keyword.get(opts, :base_url) ||
        System.get_env("CUSTOM_BASE_URL") ||
        get_in(Application.get_env(:nous, :custom, []), [:base_url])

    unless base_url do
      raise ArgumentError,
            "custom provider requires :base_url option. " <>
              "Example: parse(\"custom:my-model\", base_url: \"http://localhost:8080/v1\")"
    end

    new(:custom, model_name, opts)
  end

  # Backward compatibility: openai_compatible: is now custom:
  # Note: The `custom:` prefix is the recommended approach going forward.
  def parse("openai_compatible:" <> model_name, opts) do
    # Check for base_url in opts, env var, or application config
    base_url =
      Keyword.get(opts, :base_url) ||
        System.get_env("CUSTOM_BASE_URL") ||
        get_in(Application.get_env(:nous, :custom, []), [:base_url])

    unless base_url do
      raise ArgumentError,
            "openai_compatible provider requires :base_url option. " <>
              "Example: parse(\"openai_compatible:my-model\", base_url: \"http://localhost:8080/v1\")"
    end

    new(:custom, model_name, opts)
  end

  def parse(invalid_string, _opts) do
    raise ArgumentError,
          "Invalid model string format: #{inspect(invalid_string)}. " <>
            "Expected format: \"provider:model-name\". " <>
            "Supported providers: openai, anthropic, gemini, vertex_ai, groq, mistral, ollama, lmstudio, llamacpp, openrouter, together, vllm, sglang, custom"
  end

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
    * `:receive_timeout` - HTTP receive timeout in milliseconds (default: 180000).
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
  defp default_base_url(:gemini), do: "https://generativelanguage.googleapis.com/v1beta"

  # Vertex AI URL is built at request time by the provider (with proper v1/v1beta1 selection)
  defp default_base_url(:vertex_ai), do: nil

  defp default_base_url(:groq), do: "https://api.groq.com/openai/v1"
  defp default_base_url(:ollama), do: "http://localhost:11434/v1"
  defp default_base_url(:lmstudio), do: "http://localhost:1234/v1"
  defp default_base_url(:openrouter), do: "https://openrouter.ai/api/v1"
  defp default_base_url(:together), do: "https://api.together.xyz/v1"
  defp default_base_url(:mistral), do: "https://api.mistral.ai/v1"
  # vLLM requires explicit base_url
  defp default_base_url(:vllm), do: nil
  defp default_base_url(:sglang), do: "http://localhost:30000/v1"
  defp default_base_url(:llamacpp), do: "local"
  # CUSTOM_BASE_URL env var takes precedence; explicit opts override this
  defp default_base_url(:custom), do: System.get_env("CUSTOM_BASE_URL")

  @spec default_api_key(provider()) :: String.t() | nil
  defp default_api_key(:openai), do: Application.get_env(:nous, :openai_api_key)
  defp default_api_key(:anthropic), do: Application.get_env(:nous, :anthropic_api_key)
  defp default_api_key(:gemini), do: Application.get_env(:nous, :google_ai_api_key)
  defp default_api_key(:vertex_ai), do: Application.get_env(:nous, :vertex_ai_api_key)
  defp default_api_key(:groq), do: Application.get_env(:nous, :groq_api_key)
  defp default_api_key(:openrouter), do: Application.get_env(:nous, :openrouter_api_key)
  defp default_api_key(:together), do: Application.get_env(:nous, :together_api_key)
  defp default_api_key(:mistral), do: Application.get_env(:nous, :mistral_api_key)
  defp default_api_key(:ollama), do: "ollama"
  defp default_api_key(:lmstudio), do: "not-needed"
  # vLLM API key is optional
  defp default_api_key(:vllm), do: nil
  # SGLang API key is optional
  defp default_api_key(:sglang), do: nil
  # LlamaCpp runs locally via NIFs, no API key needed
  defp default_api_key(:llamacpp), do: nil
  # CUSTOM_API_KEY env var takes precedence; explicit opts override this
  defp default_api_key(:custom), do: System.get_env("CUSTOM_API_KEY")

  # Default receive timeouts per provider
  # Local providers get longer timeouts since they're typically slower
  @spec default_receive_timeout(provider()) :: non_neg_integer()
  # 2 minutes for local Ollama
  defp default_receive_timeout(:ollama), do: 120_000
  # 2 minutes for local LM Studio
  defp default_receive_timeout(:lmstudio), do: 120_000
  # 2 minutes for local vLLM
  defp default_receive_timeout(:vllm), do: 120_000
  # 2 minutes for local SGLang
  defp default_receive_timeout(:sglang), do: 120_000
  # 5 minutes for local LlamaCpp (slow first-token on cold weights)
  defp default_receive_timeout(:llamacpp), do: 300_000
  # 3 minutes for custom endpoints
  defp default_receive_timeout(:custom), do: 180_000
  # 3 minutes for cloud providers (reasoning models can take a while)
  defp default_receive_timeout(_provider), do: 180_000
end
