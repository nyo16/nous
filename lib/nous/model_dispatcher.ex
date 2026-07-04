defmodule Nous.ModelDispatcher do
  @moduledoc """
  Dispatches model requests to the appropriate provider implementation.

  Routes requests to providers based on the model's provider field:
  - `:anthropic` → `Nous.Providers.Anthropic`
  - `:gemini` → `Nous.Providers.Gemini`
  - `:vertex_ai` → `Nous.Providers.VertexAI`
  - `:mistral` → `Nous.Providers.Mistral`
  - `:lmstudio` → `Nous.Providers.LMStudio`
  - `:llamacpp` → `Nous.Providers.LlamaCpp`
  - `:vllm` → `Nous.Providers.VLLM`
  - `:sglang` → `Nous.Providers.SGLang`
  - `:openai` → `Nous.Providers.OpenAI`
  - `:custom` → `Nous.Providers.Custom`
  - Others → `Nous.Providers.OpenAICompatible`
  """

  alias Nous.{Model, Providers}

  require Logger

  @provider_modules %{
    anthropic: Providers.Anthropic,
    gemini: Providers.Gemini,
    vertex_ai: Providers.VertexAI,
    mistral: Providers.Mistral,
    lmstudio: Providers.LMStudio,
    llamacpp: Providers.LlamaCpp,
    vllm: Providers.VLLM,
    sglang: Providers.SGLang,
    openai: Providers.OpenAI,
    custom: Providers.Custom
  }

  @doc """
  Resolve the provider module for a provider atom.

  Unknown providers fall back to `Nous.Providers.OpenAICompatible`.
  """
  @spec provider_module(atom()) :: module()
  def provider_module(provider) do
    Map.get(@provider_modules, provider, Providers.OpenAICompatible)
  end

  @doc """
  Dispatch request to the appropriate provider implementation.
  """
  @spec request(Model.t(), list(), map()) :: {:ok, map()} | {:error, term()}
  def request(%Model{} = model, messages, settings) do
    provider = provider_module(model.provider)
    Logger.debug("Routing to #{inspect(provider)} for: #{model.provider}:#{model.model}")
    provider.request(model, messages, settings)
  end

  @doc """
  Dispatch streaming request to the appropriate provider implementation.
  """
  @spec request_stream(Model.t(), list(), map()) :: {:ok, Enumerable.t()} | {:error, term()}
  def request_stream(%Model{} = model, messages, settings) do
    provider = provider_module(model.provider)

    Logger.debug(
      "Routing streaming request to #{inspect(provider)} for: #{model.provider}:#{model.model}"
    )

    provider.request_stream(model, messages, settings)
  end

  @doc """
  Count tokens (uses appropriate provider implementation).
  """
  @spec count_tokens(Model.t(), list()) :: integer()
  def count_tokens(%Model{} = model, messages) do
    provider_module(model.provider).count_tokens(messages)
  end
end
