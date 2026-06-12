defmodule Nous.Plugins.InputGuard.Strategies.SemanticTest do
  use ExUnit.Case, async: true

  alias Nous.Plugins.InputGuard.Result
  alias Nous.Plugins.InputGuard.Strategies.Semantic

  # Stub embedding provider: maps known inputs to fixed vectors so cosine
  # similarity against the attack vector [1.0, 0.0] is fully deterministic.
  defmodule StubEmbedding do
    @behaviour Nous.Memory.Embedding

    @near_y :math.sqrt(0.19)

    @impl true
    # cosine([1,0],[1,0]) = 1.0  → blocked (>= threshold + 0.1)
    def embed("exact attack", _opts), do: {:ok, [1.0, 0.0]}
    # cosine([0.9, sqrt(0.19)],[1,0]) = 0.9 → suspicious (between threshold and +0.1)
    def embed("near attack", _opts), do: {:ok, [0.9, @near_y]}
    # cosine([0,1],[1,0]) = 0.0 → safe
    def embed("benign", _opts), do: {:ok, [0.0, 1.0]}
    # zero vector → cosine guard returns 0.0, must not crash
    def embed("zero", _opts), do: {:ok, [0.0, 0.0]}
    def embed("boom", _opts), do: {:error, :provider_down}

    @impl true
    def embed_batch(texts, opts), do: {:ok, Enum.map(texts, fn t -> elem(embed(t, opts), 1) end)}

    @impl true
    def dimension, do: 2
  end

  @attacks [{"jailbreak", [1.0, 0.0]}]

  defp config(extra \\ []) do
    Keyword.merge(
      [embedding_provider: StubEmbedding, attack_embeddings: @attacks, threshold: 0.85],
      extra
    )
  end

  describe "check/3 similarity classification" do
    test "exact match on an attack vector is blocked" do
      assert {:ok, %Result{severity: :blocked} = r} =
               Semantic.check("exact attack", config(), %{})

      assert r.reason =~ "jailbreak"
      assert r.strategy == Semantic
      assert r.metadata.top_match == "jailbreak"
    end

    test "a near match (between threshold and threshold+0.1) is suspicious" do
      assert {:ok, %Result{severity: :suspicious} = r} =
               Semantic.check("near attack", config(), %{})

      assert r.metadata.top_similarity >= 0.85
      assert r.metadata.top_similarity < 0.95
    end

    test "an orthogonal (benign) input is safe" do
      assert {:ok, %Result{severity: :safe}} = Semantic.check("benign", config(), %{})
    end

    test "a zero-magnitude embedding does not crash and is safe" do
      assert {:ok, %Result{severity: :safe}} = Semantic.check("zero", config(), %{})
    end

    test "threshold is configurable — a high threshold lets the near match pass as safe" do
      assert {:ok, %Result{severity: :safe}} =
               Semantic.check("near attack", config(threshold: 0.95), %{})
    end
  end

  describe "embedding failure handling" do
    test "fails open (:safe) by default" do
      assert {:ok, %Result{severity: :safe} = r} = Semantic.check("boom", config(), %{})
      assert r.reason =~ "fail-safe"
    end

    test "fails closed (:blocked) when on_error: :blocked" do
      assert {:ok, %Result{severity: :blocked} = r} =
               Semantic.check("boom", config(on_error: :blocked), %{})

      assert r.reason =~ "fail-blocked"
    end
  end

  describe "required config" do
    test "raises when embedding_provider is missing" do
      assert_raise KeyError, fn ->
        Semantic.check("x", [attack_embeddings: @attacks], %{})
      end
    end

    test "raises when attack_embeddings is missing" do
      assert_raise KeyError, fn ->
        Semantic.check("x", [embedding_provider: StubEmbedding], %{})
      end
    end
  end
end
