defmodule Nous.ModelDispatcher do
  @moduledoc """
  Dispatches model requests to the appropriate provider implementation.

  Routes requests to providers based on the model's provider field:
  - `:anthropic` → `Nous.Providers.Anthropic`
  - `:gemini` → `Nous.Providers.Gemini`
  - `:mistral` → `Nous.Providers.Mistral`
  - `:lmstudio` → `Nous.Providers.LMStudio`
  - `:vllm` → `Nous.Providers.VLLM`
  - `:sglang` → `Nous.Providers.SGLang`
  - `:openai` → `Nous.Providers.OpenAI`
  - Others → `Nous.Providers.OpenAICompatible`
  """

  alias Nous.{Model, Providers}

  require Logger

  @doc """
  Dispatch request to the appropriate provider implementation.
  """
  @spec request(Model.t(), list(), map()) :: {:ok, map()} | {:error, term()}
  def request(%Model{provider: :anthropic} = model, messages, settings) do
    Logger.debug("Routing to Anthropic provider for model: #{model.model}")
    Providers.Anthropic.request(model, messages, settings)
  end

  def request(%Model{provider: :gemini} = model, messages, settings) do
    Logger.debug("Routing to Gemini provider for model: #{model.model}")
    Providers.Gemini.request(model, messages, settings)
  end

  def request(%Model{provider: :mistral} = model, messages, settings) do
    Logger.debug("Routing to Mistral provider for model: #{model.model}")
    Providers.Mistral.request(model, messages, settings)
  end

  def request(%Model{provider: :lmstudio} = model, messages, settings) do
    Logger.debug("Routing to LMStudio provider for model: #{model.model}")
    Providers.LMStudio.request(model, messages, settings)
  end

  def request(%Model{provider: :vllm} = model, messages, settings) do
    Logger.debug("Routing to vLLM provider for model: #{model.model}")
    Providers.VLLM.request(model, messages, settings)
  end

  def request(%Model{provider: :sglang} = model, messages, settings) do
    Logger.debug("Routing to SGLang provider for model: #{model.model}")
    Providers.SGLang.request(model, messages, settings)
  end

  def request(%Model{provider: :openai} = model, messages, settings) do
    Logger.debug("Routing to OpenAI provider for model: #{model.model}")
    Providers.OpenAI.request(model, messages, settings)
  end

  def request(%Model{} = model, messages, settings) do
    # All other providers use OpenAI-compatible API
    Logger.debug("Routing to OpenAI-compatible provider for: #{model.provider}:#{model.model}")
    Providers.OpenAICompatible.request(model, messages, settings)
  end

  @doc """
  Dispatch streaming request to the appropriate provider implementation.
  """
  @spec request_stream(Model.t(), list(), map()) :: {:ok, Enumerable.t()} | {:error, term()}
  def request_stream(%Model{provider: :anthropic} = model, messages, settings) do
    Logger.debug("Routing streaming request to Anthropic provider for model: #{model.model}")
    Providers.Anthropic.request_stream(model, messages, settings)
  end

  def request_stream(%Model{provider: :gemini} = model, messages, settings) do
    Logger.debug("Routing streaming request to Gemini provider for model: #{model.model}")
    Providers.Gemini.request_stream(model, messages, settings)
  end

  def request_stream(%Model{provider: :mistral} = model, messages, settings) do
    Logger.debug("Routing streaming request to Mistral provider for model: #{model.model}")
    Providers.Mistral.request_stream(model, messages, settings)
  end

  def request_stream(%Model{provider: :lmstudio} = model, messages, settings) do
    Logger.debug("Routing streaming request to LMStudio provider for model: #{model.model}")
    Providers.LMStudio.request_stream(model, messages, settings)
  end

  def request_stream(%Model{provider: :vllm} = model, messages, settings) do
    Logger.debug("Routing streaming request to vLLM provider for model: #{model.model}")
    Providers.VLLM.request_stream(model, messages, settings)
  end

  def request_stream(%Model{provider: :sglang} = model, messages, settings) do
    Logger.debug("Routing streaming request to SGLang provider for model: #{model.model}")
    Providers.SGLang.request_stream(model, messages, settings)
  end

  def request_stream(%Model{provider: :openai} = model, messages, settings) do
    Logger.debug("Routing streaming request to OpenAI provider for model: #{model.model}")
    Providers.OpenAI.request_stream(model, messages, settings)
  end

  def request_stream(%Model{} = model, messages, settings) do
    Logger.debug(
      "Routing streaming request to OpenAI-compatible provider for: #{model.provider}:#{model.model}"
    )

    Providers.OpenAICompatible.request_stream(model, messages, settings)
  end

  @doc """
  Count tokens (uses appropriate provider implementation).
  """
  @spec count_tokens(Model.t(), list()) :: integer()
  def count_tokens(%Model{provider: :anthropic}, messages) do
    Providers.Anthropic.count_tokens(messages)
  end

  def count_tokens(%Model{provider: :gemini}, messages) do
    Providers.Gemini.count_tokens(messages)
  end

  def count_tokens(%Model{provider: :mistral}, messages) do
    Providers.Mistral.count_tokens(messages)
  end

  def count_tokens(%Model{provider: :lmstudio}, messages) do
    Providers.LMStudio.count_tokens(messages)
  end

  def count_tokens(%Model{provider: :vllm}, messages) do
    Providers.VLLM.count_tokens(messages)
  end

  def count_tokens(%Model{provider: :sglang}, messages) do
    Providers.SGLang.count_tokens(messages)
  end

  def count_tokens(%Model{provider: :openai}, messages) do
    Providers.OpenAI.count_tokens(messages)
  end

  def count_tokens(%Model{}, messages) do
    Providers.OpenAICompatible.count_tokens(messages)
  end
end
