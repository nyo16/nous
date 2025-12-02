defmodule Yggdrasil.ModelDispatcher do
  @moduledoc """
  Dispatches model requests to the appropriate implementation.

  Routes requests to either:
  - OpenAICompatible (for OpenAI-compatible APIs)
  - Anthropic (for native Anthropic API via Anthropix)
  - Gemini (for native Google Gemini API)
  - Mistral (for native Mistral API via Req)
  """

  alias Yggdrasil.{Model, Models}

  require Logger

  @doc """
  Dispatch request to the appropriate model implementation.
  """
  @spec request(Model.t(), list(), map()) :: {:ok, map()} | {:error, term()}
  def request(%Model{provider: :anthropic} = model, messages, settings) do
    Logger.debug("Routing to Anthropic adapter for model: #{model.model}")
    Models.Anthropic.request(model, messages, settings)
  end

  def request(%Model{provider: :gemini} = model, messages, settings) do
    Logger.debug("Routing to Gemini adapter for model: #{model.model}")
    Models.Gemini.request(model, messages, settings)
  end

  def request(%Model{provider: :mistral} = model, messages, settings) do
    Logger.debug("Routing to Mistral adapter for model: #{model.model}")
    Models.Mistral.request(model, messages, settings)
  end

  def request(%Model{} = model, messages, settings) do
    # All other providers use OpenAI-compatible API
    Logger.debug("Routing to OpenAI-compatible adapter for provider: #{model.provider}, model: #{model.model}")
    Models.OpenAICompatible.request(model, messages, settings)
  end

  @doc """
  Dispatch streaming request to the appropriate model implementation.
  """
  @spec request_stream(Model.t(), list(), map()) :: {:ok, Enumerable.t()} | {:error, term()}
  def request_stream(%Model{provider: :anthropic} = model, messages, settings) do
    Logger.debug("Routing streaming request to Anthropic adapter for model: #{model.model}")
    Models.Anthropic.request_stream(model, messages, settings)
  end

  def request_stream(%Model{provider: :gemini} = model, messages, settings) do
    Logger.debug("Routing streaming request to Gemini adapter for model: #{model.model}")
    Models.Gemini.request_stream(model, messages, settings)
  end

  def request_stream(%Model{provider: :mistral} = model, messages, settings) do
    Logger.debug("Routing streaming request to Mistral adapter for model: #{model.model}")
    Models.Mistral.request_stream(model, messages, settings)
  end

  def request_stream(%Model{} = model, messages, settings) do
    Logger.debug("Routing streaming request to OpenAI-compatible adapter for provider: #{model.provider}")
    Models.OpenAICompatible.request_stream(model, messages, settings)
  end

  @doc """
  Count tokens (uses appropriate implementation).
  """
  @spec count_tokens(Model.t(), list()) :: integer()
  def count_tokens(%Model{provider: :anthropic} = _model, messages) do
    Models.Anthropic.count_tokens(messages)
  end

  def count_tokens(%Model{provider: :gemini} = _model, messages) do
    Models.Gemini.count_tokens(messages)
  end

  def count_tokens(%Model{provider: :mistral} = _model, messages) do
    Models.Mistral.count_tokens(messages)
  end

  def count_tokens(%Model{} = _model, messages) do
    Models.OpenAICompatible.count_tokens(messages)
  end
end
