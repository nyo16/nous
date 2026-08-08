# A memory backend implemented entirely OUTSIDE the Nous namespace, using nothing
# but the public `Nous.Memory.Store` behaviour. It exists to pin the promise that
# `Nous.Memory.Store` makes: a store you write in your own application is a
# first-class backend, because nothing in the memory system knows a backend's name.
#
# Deliberately not ETS-backed either: state here is a plain map threaded back
# through every callback, which also exercises the "opaque state term" half of the
# contract that every shipped backend happens to satisfy trivially (they all return
# the same handle).
defmodule MyApp.Memory.Store.PlainMap do
  @moduledoc false
  @behaviour Nous.Memory.Store

  alias Nous.Memory.Entry

  @impl true
  def init(opts), do: {:ok, %{entries: %{}, tag: Keyword.get(opts, :tag, :none)}}

  @impl true
  def store(state, %Entry{} = entry) do
    {:ok, %{state | entries: Map.put(state.entries, entry.id, entry)}}
  end

  @impl true
  def fetch(state, id) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def delete(state, id), do: {:ok, %{state | entries: Map.delete(state.entries, id)}}

  @impl true
  def update(state, id, updates) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} ->
        updated = struct(entry, Map.put(updates, :updated_at, DateTime.utc_now()))
        {:ok, %{state | entries: Map.put(state.entries, id, updated)}}

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def list(state, opts) do
    {:ok, state.entries |> Map.values() |> in_scope(Keyword.get(opts, :scope, %{}))}
  end

  # Naive substring relevance — enough to be a real backend, small enough to read.
  @impl true
  def search_text(state, query, opts) do
    needles = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    results =
      state.entries
      |> Map.values()
      |> in_scope(Keyword.get(opts, :scope, %{}))
      |> Enum.map(&{&1, score(&1.content, needles)})
      |> Enum.filter(fn {_entry, score} -> score > Keyword.get(opts, :min_score, 0.0) end)
      |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
      |> Enum.take(Keyword.get(opts, :limit, 10))

    {:ok, results}
  end

  # NOTE: no `search_vector/3`. A text-only backend omits the callback entirely
  # rather than defining it and returning an error — `Nous.Memory.Search`
  # feature-detects it and degrades to text-only search.

  defp in_scope(entries, scope) when map_size(scope) == 0, do: entries

  defp in_scope(entries, scope) do
    Enum.filter(entries, fn entry ->
      Enum.all?(scope, fn {key, value} -> Map.get(entry, key) == value end)
    end)
  end

  defp score(content, needles) do
    haystack = String.downcase(content)
    hits = Enum.count(needles, &String.contains?(haystack, &1))
    if needles == [], do: 0.0, else: hits / length(needles)
  end
end

# The same store plus the OPTIONAL callback, so the feature detection can be
# observed resolving both ways.
defmodule MyApp.Memory.Store.PlainMapWithVectors do
  @moduledoc false
  @behaviour Nous.Memory.Store

  alias MyApp.Memory.Store.PlainMap

  @impl true
  def init(opts), do: PlainMap.init(opts)
  @impl true
  def store(state, entry), do: PlainMap.store(state, entry)
  @impl true
  def fetch(state, id), do: PlainMap.fetch(state, id)
  @impl true
  def delete(state, id), do: PlainMap.delete(state, id)
  @impl true
  def update(state, id, updates), do: PlainMap.update(state, id, updates)
  @impl true
  def list(state, opts), do: PlainMap.list(state, opts)
  @impl true
  def search_text(state, query, opts), do: PlainMap.search_text(state, query, opts)

  # A similarity, not a distance: larger is better, because `Nous.Memory.Search`
  # applies `:min_score` and the scoring weights to whatever number comes back.
  @impl true
  def search_vector(state, embedding, opts) do
    results =
      state.entries
      |> Map.values()
      |> Enum.filter(& &1.embedding)
      |> Enum.map(&{&1, cosine(embedding, &1.embedding)})
      |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
      |> Enum.take(Keyword.get(opts, :limit, 10))

    {:ok, results}
  end

  defp cosine(a, b) do
    dot = a |> Enum.zip(b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()

    mag =
      :math.sqrt(Enum.sum(Enum.map(a, &(&1 * &1)))) *
        :math.sqrt(Enum.sum(Enum.map(b, &(&1 * &1))))

    if mag == 0, do: 0.0, else: dot / mag
  end
end

# Reports rather than explodes: `Nous.Memory.Search` runs the embedder in a
# supervised Task and CONTAINS a crash there (it degrades to text-only and logs),
# so a raising stub proves nothing to the caller. The test pid arrives through
# `:embedding_opts`, which `Search` passes straight through.
defmodule ProbeEmbedder do
  @moduledoc false
  @behaviour Nous.Memory.Embedding

  @impl true
  def embed(_text, opts) do
    send(Keyword.fetch!(opts, :reply_to), :embed_called)
    {:ok, [1.0, 0.0, 0.0]}
  end

  @impl true
  def dimension, do: 3
end

# The shipped conformance kit, used from outside Nous exactly as a host would.
# This is the reason the kit lives in `lib/` rather than `test/support/`.
defmodule MyApp.Memory.Store.PlainMapConformanceTest do
  @moduledoc false
  use Nous.Memory.Store.Conformance, store: MyApp.Memory.Store.PlainMap, init_opts: [tag: :probe]
end

defmodule Nous.Memory.OutOfTreeStoreTest do
  use ExUnit.Case, async: true

  alias MyApp.Memory.Store.PlainMap
  alias MyApp.Memory.Store.PlainMapWithVectors
  alias Nous.Memory.Entry

  describe "a store defined outside Nous is a first-class backend" do
    test "the Memory plugin initialises it and the tools drive it end to end" do
      # The real path: Plugins.Memory.init/2 calls store_mod.init/1, and the tools
      # dispatch on the module from deps. No branch anywhere knows this module.
      ctx =
        Nous.Agent.Context.new(
          deps: %{memory_config: %{store: PlainMap, store_opts: [tag: :e2e]}}
        )

      ctx = Nous.Plugins.Memory.init(nil, ctx)

      assert %{store: PlainMap, store_state: %{tag: :e2e}} = ctx.deps[:memory_config]

      assert {:ok, %{status: "remembered"}, update} =
               Nous.Memory.Tools.remember(ctx, %{"content" => "the user prefers dark mode"})

      # Applied through the same seam the tool executor uses, so the state the
      # store returned is threaded back exactly as it would be mid-run.
      ctx = Nous.Tool.ContextUpdate.apply(update, ctx)

      assert {:ok, %{status: "found", memories: [memory]}, _} =
               Nous.Memory.Tools.recall(ctx, %{"query" => "dark mode"})

      assert memory.content == "the user prefers dark mode"
    end

    test "search does not even embed when the optional callback is absent" do
      {:ok, state} = PlainMap.init([])
      {:ok, state} = PlainMap.store(state, Entry.new(%{content: "otp supervision trees"}))

      # An embedding provider IS supplied, so `Search` reaches the feature check
      # rather than short-circuiting on a nil provider — without that this would
      # pass for any implementation, which is the shape this file exists to avoid.
      refute function_exported?(PlainMap, :search_vector, 3)

      assert {:ok, [{entry, score}]} =
               Nous.Memory.Search.search(PlainMap, state, "otp supervision", ProbeEmbedder,
                 limit: 5,
                 embedding_opts: [reply_to: self()]
               )

      assert entry.content == "otp supervision trees"
      assert score > 0.0
      # Degradation is free: a text-only backend must not cost an embedding
      # round-trip. Asserted, not assumed.
      refute_receive :embed_called, 100
    end

    test "control: the same search DOES embed when the backend defines the callback" do
      # Same call, same probe, one difference — the store implements
      # `search_vector/3`. Without this, "feature detection stopped resolving at
      # all" would read as a pass above.
      {:ok, state} = PlainMapWithVectors.init([])
      {:ok, state} = PlainMapWithVectors.store(state, Entry.new(%{content: "otp trees"}))

      assert function_exported?(PlainMapWithVectors, :search_vector, 3)

      assert {:ok, _results} =
               Nous.Memory.Search.search(PlainMapWithVectors, state, "otp", ProbeEmbedder,
                 limit: 5,
                 embedding_opts: [reply_to: self()]
               )

      assert_receive :embed_called, 500
    end

    test "the optional callback is used when the backend does define it" do
      {:ok, state} = PlainMapWithVectors.init([])

      near = Entry.new(%{content: "near", embedding: [1.0, 0.0, 0.0]})
      far = Entry.new(%{content: "far", embedding: [0.0, 1.0, 0.0]})
      {:ok, state} = PlainMapWithVectors.store(state, near)
      {:ok, state} = PlainMapWithVectors.store(state, far)

      assert function_exported?(PlainMapWithVectors, :search_vector, 3)

      assert {:ok, [{top, _} | _]} =
               PlainMapWithVectors.search_vector(state, [1.0, 0.0, 0.0], limit: 2)

      # Larger is better: the nearest vector ranks first. A distance would invert
      # this while every callback still looked correct.
      assert top.content == "near"
    end
  end
end
