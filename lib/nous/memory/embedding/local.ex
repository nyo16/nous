defmodule Nous.Memory.Embedding.Local do
  @moduledoc """
  Generic local embedding provider for OpenAI-compatible endpoints.

  Works with Ollama, vLLM, LMStudio, or any OpenAI-compatible embeddings API.

  ## Options

    * `:base_url` - API base URL (default: "http://localhost:11434/v1" for Ollama)
    * `:model` - Model name (default: "nomic-embed-text")
    * `:dimension` - Embedding dimension (default: 768)
    * `:api_key` - API key if needed (default: nil)
  """

  @behaviour Nous.Memory.Embedding

  @default_base_url "http://localhost:11434/v1"
  @default_model "nomic-embed-text"
  @default_dimension 768

  @impl true
  def embed(text, opts \\ []) do
    base_url = opts[:base_url] || @default_base_url
    model = opts[:model] || @default_model
    url = "#{base_url}/embeddings"

    body = %{input: text, model: model}

    headers = [{"content-type", "application/json"}]

    headers =
      if opts[:api_key],
        do: [{"authorization", "Bearer #{opts[:api_key]}"} | headers],
        else: headers

    case Req.post(url, json: body, headers: headers, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
        {:ok, embedding}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def dimension, do: @default_dimension
end
