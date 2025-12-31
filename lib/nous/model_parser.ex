defmodule Nous.ModelParser do
  @moduledoc """
  Parses model strings into Model configurations.

  Supports the format `"provider:model-name"` and creates appropriate
  Model structs with provider-specific defaults.

  ## Supported Formats

    * `"openai:gpt-4"` - OpenAI models
    * `"anthropic:claude-3-5-sonnet-20241022"` - Anthropic Claude (native API)
    * `"groq:llama-3.1-70b-versatile"` - Groq models
    * `"mistral:mistral-large-latest"` - Mistral models
    * `"ollama:llama2"` - Local Ollama
    * `"lmstudio:qwen/qwen3-30b-a3b-2507"` - Local LM Studio
    * `"vllm:qwen/qwen3-30b"` - vLLM server
    * `"sglang:meta-llama/Llama-3-8B"` - SGLang server
    * `"openrouter:anthropic/claude-3.5-sonnet"` - OpenRouter
    * `"together:meta-llama/Llama-3-70b-chat-hf"` - Together AI
    * `"custom:my-model"` - Custom endpoint (requires `:base_url` option)

  ## Examples

      # OpenAI
      model = ModelParser.parse("openai:gpt-4")
      # %Model{provider: :openai, model: "gpt-4", ...}

      # Groq
      model = ModelParser.parse("groq:llama-3.1-8b-instant")
      # %Model{provider: :groq, model: "llama-3.1-8b-instant", ...}

      # Custom endpoint
      model = ModelParser.parse("custom:my-model",
        base_url: "https://my-server.com/v1",
        api_key: "my-key"
      )

  """

  alias Nous.Model

  @doc """
  Parse a model string into a Model struct.

  ## Parameters

    * `model_string` - String in format "provider:model-name"
    * `opts` - Options to override defaults (`:base_url`, `:api_key`, etc.)

  ## Examples

      iex> %Model{provider: provider, model: model} = ModelParser.parse("openai:gpt-4")
      iex> {provider, model}
      {:openai, "gpt-4"}

      iex> %Model{provider: provider, model: model} = ModelParser.parse("ollama:llama2")
      iex> {provider, model}
      {:ollama, "llama2"}

      iex> model = ModelParser.parse("custom:my-model", base_url: "http://localhost:8080/v1")
      iex> {model.provider, model.model, model.base_url}
      {:custom, "my-model", "http://localhost:8080/v1"}

  """
  @spec parse(String.t(), keyword()) :: Model.t()
  def parse(model_string, opts \\ [])

  def parse("openai:" <> model_name, opts) do
    Model.new(:openai, model_name, opts)
  end

  def parse("anthropic:" <> model_name, opts) do
    Model.new(:anthropic, model_name, opts)
  end

  def parse("gemini:" <> model_name, opts) do
    Model.new(:gemini, model_name, opts)
  end

  def parse("groq:" <> model_name, opts) do
    Model.new(:groq, model_name, opts)
  end

  def parse("mistral:" <> model_name, opts) do
    Model.new(:mistral, model_name, opts)
  end

  def parse("ollama:" <> model_name, opts) do
    Model.new(:ollama, model_name, opts)
  end

  def parse("lmstudio:" <> model_name, opts) do
    Model.new(:lmstudio, model_name, opts)
  end

  def parse("openrouter:" <> model_name, opts) do
    Model.new(:openrouter, model_name, opts)
  end

  def parse("together:" <> model_name, opts) do
    Model.new(:together, model_name, opts)
  end

  def parse("vllm:" <> model_name, opts) do
    unless Keyword.has_key?(opts, :base_url) do
      raise ArgumentError,
            "vllm provider requires :base_url option. " <>
              "Example: parse(\"vllm:qwen/qwen3-30b\", base_url: \"http://localhost:8000/v1\")"
    end

    Model.new(:vllm, model_name, opts)
  end

  def parse("sglang:" <> model_name, opts) do
    Model.new(:sglang, model_name, opts)
  end

  def parse("custom:" <> model_name, opts) do
    unless Keyword.has_key?(opts, :base_url) do
      raise ArgumentError,
            "custom provider requires :base_url option. " <>
              "Example: parse(\"custom:my-model\", base_url: \"http://localhost:8080/v1\")"
    end

    Model.new(:custom, model_name, opts)
  end

  def parse(invalid_string, _opts) do
    raise ArgumentError,
          "Invalid model string format: #{inspect(invalid_string)}. " <>
            "Expected format: \"provider:model-name\". " <>
            "Supported providers: openai, anthropic, gemini, groq, mistral, ollama, lmstudio, openrouter, together, vllm, sglang, custom"
  end
end
