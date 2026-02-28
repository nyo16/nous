defmodule Nous.Memory.Embedding do
  @moduledoc """
  Behaviour for embedding providers.

  Implement this behaviour to use any embedding provider with the memory system.
  If no embedding provider is configured, the memory system falls back to keyword-only search.
  """

  @callback embed(text :: String.t(), opts :: keyword()) :: {:ok, [float()]} | {:error, term()}
  @callback embed_batch(texts :: [String.t()], opts :: keyword()) ::
              {:ok, [[float()]]} | {:error, term()}
  @callback dimension() :: pos_integer()

  @optional_callbacks [embed_batch: 2]

  @doc """
  Embed a single text using the given provider module and options.
  Returns {:ok, embedding} or {:error, reason}.
  """
  def embed(provider, text, opts \\ []) when is_atom(provider) do
    provider.embed(text, opts)
  end

  @doc """
  Embed a batch of texts. Falls back to sequential embed/2 calls if embed_batch/2 is not implemented.
  """
  def embed_batch(provider, texts, opts \\ []) when is_atom(provider) do
    if function_exported?(provider, :embed_batch, 2) do
      provider.embed_batch(texts, opts)
    else
      results = Enum.map(texts, &provider.embed(&1, opts))

      case Enum.split_with(results, &match?({:ok, _}, &1)) do
        {successes, []} ->
          {:ok, Enum.map(successes, fn {:ok, emb} -> emb end)}

        {_, [{:error, reason} | _]} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Get the embedding dimension for a provider.
  """
  def dimension(provider) when is_atom(provider) do
    provider.dimension()
  end
end
