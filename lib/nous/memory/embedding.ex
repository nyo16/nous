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

  # Per-text task timeout for the sequential fallback. Providers' own request
  # timeouts are at most 60s (Bumblebee run_timeout; HTTP providers use 30s),
  # so this only fires if a provider hangs past its own deadline.
  @fallback_batch_timeout 60_000

  @doc """
  Embed a single text using the given provider module and options.
  Returns {:ok, embedding} or {:error, reason}.
  """
  @spec embed(module(), String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(provider, text, opts \\ []) when is_atom(provider) do
    provider.embed(text, opts)
  end

  @doc """
  Embed a batch of texts. Falls back to concurrent embed/2 calls (max concurrency 4,
  order preserved) if embed_batch/2 is not implemented.
  """
  @spec embed_batch(module(), [String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(provider, texts, opts \\ []) when is_atom(provider) do
    if function_exported?(provider, :embed_batch, 2) do
      provider.embed_batch(texts, opts)
    else
      # async_stream_nolink under Nous.TaskSupervisor (the in-tree convention
      # for fan-out): a plain Task.async_stream/3 LINKS workers to the caller,
      # so a raising provider.embed/2 would crash the caller instead of ever
      # reaching the {:exit, reason} clause below. Unlinked, crashes surface
      # as {:exit, reason} and become {:error, _} for the caller's fallback.
      results =
        Nous.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(texts, &provider.embed(&1, opts),
          max_concurrency: 4,
          ordered: true,
          timeout: @fallback_batch_timeout,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> {:error, {:exit, reason}}
        end)

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
  @spec dimension(module()) :: pos_integer()
  def dimension(provider) when is_atom(provider) do
    provider.dimension()
  end
end
