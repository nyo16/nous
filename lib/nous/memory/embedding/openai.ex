defmodule Nous.Memory.Embedding.OpenAI do
  @moduledoc """
  OpenAI embedding provider.

  Uses text-embedding-3-small by default. Configurable model and base_url.

  ## Options

    * `:api_key` - OpenAI API key (required, or set OPENAI_API_KEY env var)
    * `:model` - Model name (default: "text-embedding-3-small")
    * `:base_url` - API base URL (default: "https://api.openai.com/v1")
  """

  @behaviour Nous.Memory.Embedding

  @default_model "text-embedding-3-small"
  @default_base_url "https://api.openai.com/v1"
  @default_dimension 1536

  @impl true
  def embed(text, opts \\ []) do
    api_key = opts[:api_key] || System.get_env("OPENAI_API_KEY")
    model = opts[:model] || @default_model
    base_url = opts[:base_url] || @default_base_url

    unless api_key do
      {:error, "OpenAI API key required. Set :api_key option or OPENAI_API_KEY env var."}
    else
      url = "#{base_url}/embeddings"

      body = %{
        input: text,
        model: model
      }

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      case Req.post(url, json: body, headers: headers) do
        {:ok, %Req.Response{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
          {:ok, embedding}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def embed_batch(texts, opts \\ []) do
    api_key = opts[:api_key] || System.get_env("OPENAI_API_KEY")
    model = opts[:model] || @default_model
    base_url = opts[:base_url] || @default_base_url

    unless api_key do
      {:error, "OpenAI API key required. Set :api_key option or OPENAI_API_KEY env var."}
    else
      url = "#{base_url}/embeddings"

      body = %{
        input: texts,
        model: model
      }

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      case Req.post(url, json: body, headers: headers) do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
          embeddings =
            data
            |> Enum.sort_by(& &1["index"])
            |> Enum.map(& &1["embedding"])

          {:ok, embeddings}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def dimension, do: @default_dimension
end
