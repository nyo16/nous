defmodule Nous.Workflow.Engine.ParallelExecutorTest do
  use ExUnit.Case, async: true

  alias Nous.Workflow.Engine.ParallelExecutor
  alias Nous.Workflow.{Node, State}

  # NOTE: `:parallel` (static fan-out) is covered end-to-end via `Workflow.run`
  # in workflow/phase3_test.exs. These tests target `execute_parallel_map`
  # directly — its handler-outcome classification and ordering are subtle and
  # were the site of a past bug (error tuples silently treated as success).

  defp map_node(config) do
    Node.new(%{id: "map", type: :parallel_map, label: "map", config: config})
  end

  describe "execute_parallel_map/2 happy path" do
    test "maps over items and stores ordered results under the result key" do
      node =
        map_node(%{
          items: fn _state -> [1, 2, 3] end,
          handler: fn item, _state -> {:ok, item * 2} end
        })

      assert {:ok, [2, 4, 6], state} = ParallelExecutor.execute_parallel_map(node, State.new())
      assert state.data[:map_results] == [2, 4, 6]
    end

    test "preserves input order even when later items finish first" do
      # Item 0 sleeps longest, item 4 returns immediately — concurrent
      # completion order is reversed, but results must come back in input order.
      node =
        map_node(%{
          items: fn _state -> [0, 1, 2, 3, 4] end,
          handler: fn item, _state ->
            Process.sleep((4 - item) * 5)
            {:ok, item}
          end
        })

      assert {:ok, [0, 1, 2, 3, 4], _state} =
               ParallelExecutor.execute_parallel_map(node, State.new())
    end

    test "honors a custom result_key" do
      node =
        map_node(%{
          items: fn _ -> [1] end,
          handler: fn i, _ -> {:ok, i} end,
          result_key: :custom
        })

      assert {:ok, [1], state} = ParallelExecutor.execute_parallel_map(node, State.new())
      assert state.data[:custom] == [1]
    end

    test "a bare (non-tuple) handler return is treated as success" do
      node =
        map_node(%{
          items: fn _ -> [1, 2] end,
          handler: fn i, _ -> i * 10 end
        })

      assert {:ok, [10, 20], _state} = ParallelExecutor.execute_parallel_map(node, State.new())
    end
  end

  describe "execute_parallel_map/2 empty input" do
    test "returns an empty result list and sets the result key to []" do
      node = map_node(%{items: fn _ -> [] end, handler: fn i, _ -> {:ok, i} end})

      assert {:ok, [], state} = ParallelExecutor.execute_parallel_map(node, State.new())
      assert state.data[:map_results] == []
    end
  end

  describe "execute_parallel_map/2 failure handling (:collect default)" do
    test "a handler returning {:error, _} is collected as a failure, not a success" do
      node =
        map_node(%{
          items: fn _ -> [1, 2, 3] end,
          handler: fn
            2, _ -> {:error, :boom}
            i, _ -> {:ok, i}
          end
        })

      assert {:ok, results, state} = ParallelExecutor.execute_parallel_map(node, State.new())
      # The error tuple must NOT appear in successful results.
      assert Enum.sort(results) == [1, 3]
      # The failure is recorded against the failing item's index.
      assert Enum.any?(state.errors, fn {key, reason} ->
               key == "map_item_1" and reason == :boom
             end)
    end

    test "a raising handler is caught and collected as a failure" do
      node =
        map_node(%{
          items: fn _ -> [1, 2] end,
          handler: fn
            2, _ -> raise "kaboom"
            i, _ -> {:ok, i}
          end
        })

      assert {:ok, [1], state} = ParallelExecutor.execute_parallel_map(node, State.new())
      assert Enum.any?(state.errors, fn {key, _reason} -> key == "map_item_1" end)
    end
  end

  describe "execute_parallel_map/2 with on_error: :fail_fast" do
    test "returns an error tuple when any item fails" do
      node =
        map_node(%{
          items: fn _ -> [1, 2, 3] end,
          on_error: :fail_fast,
          handler: fn
            2, _ -> {:error, :boom}
            i, _ -> {:ok, i}
          end
        })

      assert {:error, {:parallel_map_failed, _}} =
               ParallelExecutor.execute_parallel_map(node, State.new())
    end
  end
end
