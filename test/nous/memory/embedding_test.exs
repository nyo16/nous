defmodule Nous.Memory.EmbeddingTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Embedding

  @moduletag :capture_log

  # Exercises the concurrent fallback: no embed_batch/2 exported, so
  # Embedding.embed_batch/3 must fan out over embed/2 itself.
  defmodule FallbackOnly do
    @moduledoc false
    @behaviour Nous.Memory.Embedding

    @impl true
    def embed("crash " <> _rest, _opts), do: raise("provider exploded")
    def embed("error " <> tag, _opts), do: {:error, {:embed_failed, tag}}
    def embed(text, _opts), do: {:ok, [String.length(text) * 1.0]}

    @impl true
    def dimension, do: 1
  end

  defmodule BatchCapable do
    @moduledoc false
    @behaviour Nous.Memory.Embedding

    @impl true
    def embed(_text, _opts), do: {:ok, [:per_text_path_must_not_run]}

    @impl true
    def embed_batch(texts, _opts), do: {:ok, Enum.map(texts, fn _ -> [42.0] end)}

    @impl true
    def dimension, do: 1
  end

  describe "embed_batch/3 fallback (provider without embed_batch/2)" do
    test "embeds every text via embed/2, preserving input order" do
      assert {:ok, [[1.0], [2.0], [3.0]]} =
               Embedding.embed_batch(FallbackOnly, ["a", "bb", "ccc"])
    end

    test "returns the first error in input order" do
      texts = ["ok", "error one", "error two"]

      assert {:error, {:embed_failed, "one"}} = Embedding.embed_batch(FallbackOnly, texts)
    end

    test "a crashing provider surfaces as {:error, {:exit, _}} instead of crashing the caller" do
      # async_stream_nolink is load-bearing here: a linked Task.async_stream
      # would take this test process down with the raising worker.
      assert {:error, {:exit, {%RuntimeError{message: "provider exploded"}, _stack}}} =
               Embedding.embed_batch(FallbackOnly, ["fine", "crash now"])
    end
  end

  describe "embed_batch/3 with a batch-capable provider" do
    test "uses the provider's embed_batch/2 verbatim, never the per-text path" do
      assert {:ok, [[42.0], [42.0]]} = Embedding.embed_batch(BatchCapable, ["a", "b"])
    end
  end
end
