defmodule Nous.Workflow.Phase3Test do
  use ExUnit.Case, async: true

  alias Nous.Workflow
  alias Nous.Workflow.{Graph, State}
  alias Nous.Workflow.Engine.StateMerger

  defp tf(fun), do: %{transform_fn: fun}

  # =========================================================================
  # StateMerger
  # =========================================================================

  describe "StateMerger.merge/4" do
    test "deep_merge combines map results" do
      state = State.new(%{existing: true})

      results = [
        {"web", %{web_data: [1, 2, 3]}},
        {"papers", %{paper_data: [4, 5]}}
      ]

      merged = StateMerger.merge(results, state, :deep_merge)

      assert merged.data.existing == true
      assert merged.data.web_data == [1, 2, 3]
      assert merged.data.paper_data == [4, 5]
      assert merged.node_results["web"] == %{web_data: [1, 2, 3]}
      assert merged.node_results["papers"] == %{paper_data: [4, 5]}
    end

    test "deep_merge handles nested maps" do
      state = State.new(%{config: %{a: 1, b: 2}})

      results = [{"branch", %{config: %{b: 99, c: 3}}}]
      merged = StateMerger.merge(results, state, :deep_merge)

      assert merged.data.config == %{a: 1, b: 99, c: 3}
    end

    test "list_collect gathers results into a list" do
      state = State.new()

      results = [
        {"b1", "result_1"},
        {"b2", "result_2"},
        {"b3", "result_3"}
      ]

      merged = StateMerger.merge(results, state, :list_collect, result_key: :outputs)

      assert merged.data.outputs == ["result_1", "result_2", "result_3"]
    end

    test "custom merge function" do
      state = State.new()

      results = [
        {"b1", 10},
        {"b2", 20},
        {"b3", 30}
      ]

      merge_fn = fn results, state ->
        total = Enum.reduce(results, 0, fn {_id, val}, acc -> acc + val end)
        State.update_data(state, &Map.put(&1, :total, total))
      end

      merged = StateMerger.merge(results, state, merge_fn)
      assert merged.data.total == 60
    end

    test "non-map results skip deep_merge data update" do
      state = State.new()
      results = [{"b1", "just a string"}]
      merged = StateMerger.merge(results, state, :deep_merge)

      assert merged.node_results["b1"] == "just a string"
    end
  end

  # =========================================================================
  # Static parallel (:parallel node)
  # =========================================================================

  describe "static parallel execution" do
    test "runs branches concurrently and merges results" do
      graph =
        Graph.new("multi_source")
        |> Graph.add_node(:start, :transform, tf(fn data -> Map.put(data, :query, "test") end))
        |> Graph.add_node(:search, :parallel, %{
          branches: [:web, :papers],
          merge: :list_collect,
          result_key: :search_results
        })
        |> Graph.add_node(
          :web,
          :transform,
          tf(fn data ->
            Map.put(data, :source, "web: #{data.query}")
          end)
        )
        |> Graph.add_node(
          :papers,
          :transform,
          tf(fn data ->
            Map.put(data, :source, "papers: #{data.query}")
          end)
        )
        |> Graph.add_node(:done, :transform, tf(&Function.identity/1))
        |> Graph.connect(:start, :search)
        |> Graph.connect(:search, :done)

      assert {:ok, state} = Workflow.run(graph)

      assert state.node_results["search"] == :parallel_complete
      assert is_list(state.data.search_results)
      assert length(state.data.search_results) == 2
    end

    test "deep_merge combines branch map outputs" do
      graph =
        Graph.new("deep_merge_test")
        |> Graph.add_node(:fan_out, :parallel, %{
          branches: [:a, :b],
          merge: :deep_merge
        })
        |> Graph.add_node(:a, :transform, tf(fn _data -> %{from_a: true} end))
        |> Graph.add_node(:b, :transform, tf(fn _data -> %{from_b: true} end))

      assert {:ok, state} = Workflow.run(graph)

      assert state.data.from_a == true
      assert state.data.from_b == true
    end

    test "continues on branch failure with continue_others" do
      graph =
        Graph.new("partial_fail")
        |> Graph.add_node(:fan_out, :parallel, %{
          branches: [:good, :bad],
          merge: :list_collect,
          on_branch_error: :continue_others,
          result_key: :results
        })
        |> Graph.add_node(:good, :transform, tf(fn _data -> %{ok: true} end))
        |> Graph.add_node(:bad, :transform, tf(fn _data -> raise "boom" end))

      assert {:ok, state} = Workflow.run(graph)

      # Should have partial results
      assert length(state.data.results) == 1
      assert length(state.errors) > 0
    end

    test "fails fast on branch failure with fail_fast" do
      graph =
        Graph.new("fail_fast_parallel")
        |> Graph.add_node(:fan_out, :parallel, %{
          branches: [:good, :bad],
          merge: :list_collect,
          on_branch_error: :fail_fast
        })
        |> Graph.add_node(:good, :transform, tf(fn _data -> %{ok: true} end))
        |> Graph.add_node(:bad, :transform, tf(fn _data -> raise "boom" end))

      assert {:error, {_node_id, {:parallel_branch_failed, "bad", _}}} = Workflow.run(graph)
    end
  end

  # =========================================================================
  # Dynamic parallel (:parallel_map node)
  # =========================================================================

  describe "dynamic parallel_map execution" do
    test "maps over runtime list and collects results" do
      graph =
        Graph.new("map_test")
        |> Graph.add_node(
          :setup,
          :transform,
          tf(fn data ->
            Map.put(data, :urls, ["a.com", "b.com", "c.com"])
          end)
        )
        |> Graph.add_node(:fetch_all, :parallel_map, %{
          items: fn state -> state.data.urls end,
          handler: fn url, _state -> "fetched:#{url}" end,
          result_key: :fetched
        })
        |> Graph.add_node(:done, :transform, tf(&Function.identity/1))
        |> Graph.chain([:setup, :fetch_all, :done])

      assert {:ok, state} = Workflow.run(graph)

      assert state.data.fetched == ["fetched:a.com", "fetched:b.com", "fetched:c.com"]

      assert state.node_results["fetch_all"] == [
               "fetched:a.com",
               "fetched:b.com",
               "fetched:c.com"
             ]
    end

    test "handles empty items list" do
      graph =
        Graph.new("empty_map")
        |> Graph.add_node(:fetch, :parallel_map, %{
          items: fn _state -> [] end,
          handler: fn item, _state -> item end,
          result_key: :results
        })

      assert {:ok, state} = Workflow.run(graph)
      assert state.data.results == []
    end

    test "preserves order of results" do
      graph =
        Graph.new("order_test")
        |> Graph.add_node(:process, :parallel_map, %{
          items: fn _state -> [3, 1, 4, 1, 5, 9, 2, 6] end,
          handler: fn n, _state ->
            # Sleep varying amounts to test ordering
            Process.sleep(Enum.random(1..5))
            n * 2
          end,
          result_key: :doubled
        })

      assert {:ok, state} = Workflow.run(graph)
      assert state.data.doubled == [6, 2, 8, 2, 10, 18, 4, 12]
    end

    test "collects errors with on_error: :collect" do
      graph =
        Graph.new("collect_errors")
        |> Graph.add_node(:process, :parallel_map, %{
          items: fn _state -> [1, 2, 3, 4, 5] end,
          handler: fn n, _state ->
            if rem(n, 2) == 0, do: raise("even number: #{n}"), else: n
          end,
          on_error: :collect,
          result_key: :odds
        })

      assert {:ok, state} = Workflow.run(graph)

      # Only odd numbers succeed
      assert state.data.odds == [1, 3, 5]
      assert length(state.errors) == 2
    end

    test "fails fast with on_error: :fail_fast" do
      graph =
        Graph.new("fail_fast_map")
        |> Graph.add_node(:process, :parallel_map, %{
          items: fn _state -> [1, 2, 3] end,
          handler: fn n, _state ->
            if n == 2, do: raise("bad"), else: n
          end,
          on_error: :fail_fast,
          result_key: :results
        })

      assert {:error, {_node_id, {:parallel_map_failed, _}}} = Workflow.run(graph)
    end

    test "respects max_concurrency" do
      # Track max concurrent tasks using atomics
      counter = :atomics.new(1, [])
      max_seen = :atomics.new(1, [])

      graph =
        Graph.new("concurrency_test")
        |> Graph.add_node(:process, :parallel_map, %{
          items: fn _state -> Enum.to_list(1..10) end,
          handler: fn _n, _state ->
            current = :atomics.add_get(counter, 1, 1)

            # Update max seen
            old_max = :atomics.get(max_seen, 1)
            if current > old_max, do: :atomics.put(max_seen, 1, current)

            Process.sleep(10)
            :atomics.sub(counter, 1, 1)
            :ok
          end,
          max_concurrency: 3,
          result_key: :results
        })

      assert {:ok, _state} = Workflow.run(graph)
      assert :atomics.get(max_seen, 1) <= 3
    end

    test "handler returning {:error, _} is collected as failure (not silent success)" do
      # Previously safely_run_handler unconditionally wrapped the return in
      # :ok, so a handler that returned {:error, reason} silently landed in
      # successful_results as the literal tuple - :fail_fast never tripped.
      graph =
        Graph.new("err_returns")
        |> Graph.add_node(:process, :parallel_map, %{
          items: fn _state -> [:a, :b, :c] end,
          handler: fn item, _state ->
            if item == :b, do: {:error, :nope}, else: {:ok, item}
          end,
          on_error: :fail_fast,
          result_key: :results
        })

      assert {:error, {_node, {:parallel_map_failed, _}}} = Workflow.run(graph)
    end
  end

  # =========================================================================
  # Integration: parallel in pipeline
  # =========================================================================

  describe "parallel nodes in a pipeline" do
    test "discover → parallel_map(fetch) → summarize pipeline" do
      graph =
        Workflow.new("scraper_pipeline")
        |> Workflow.add_node(
          :discover,
          :transform,
          tf(fn data ->
            Map.put(data, :urls, ["page1", "page2", "page3"])
          end)
        )
        |> Workflow.add_node(:fetch, :parallel_map, %{
          items: fn state -> state.data.urls end,
          handler: fn url, _state -> "content_of_#{url}" end,
          result_key: :pages
        })
        |> Workflow.add_node(
          :summarize,
          :transform,
          tf(fn data ->
            Map.put(data, :summary, "Processed #{length(data.pages)} pages")
          end)
        )
        |> Workflow.chain([:discover, :fetch, :summarize])

      assert {:ok, state} = Workflow.run(graph)
      assert state.data.summary == "Processed 3 pages"
      assert length(state.data.pages) == 3
    end
  end
end
