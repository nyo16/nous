defmodule Nous.Eval.Optimizer.SearchSpaceTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Optimizer.{Parameter, SearchSpace}

  defp space do
    SearchSpace.from_parameters([
      Parameter.float(:temperature, 0.0, 1.0),
      Parameter.integer(:max_tokens, 1, 10),
      Parameter.choice(:model, ["a", "b", "c"]),
      Parameter.bool(:use_cot)
    ])
  end

  describe "latin_hypercube_sample/2" do
    test "returns n configurations, each carrying every parameter" do
      configs = SearchSpace.latin_hypercube_sample(space(), 7)

      assert length(configs) == 7

      for config <- configs do
        assert Enum.sort(Map.keys(config)) == [:max_tokens, :model, :temperature, :use_cot]
        assert config.temperature >= 0.0 and config.temperature <= 1.0
        assert config.max_tokens in 1..10
        assert config.model in ["a", "b", "c"]
        assert is_boolean(config.use_cot)
      end
    end

    test "each parameter's stratification is used exactly once per column" do
      # LHS divides [1, 10] into 10 intervals of width 1, so 10 trials must draw
      # each integer exactly once regardless of the shuffle.
      space = SearchSpace.from_parameters([Parameter.integer(:max_tokens, 1, 10)])

      drawn =
        space
        |> SearchSpace.latin_hypercube_sample(10)
        |> Enum.map(& &1.max_tokens)
        |> Enum.sort()

      assert drawn == Enum.to_list(1..10)
    end

    test "an empty search space still yields n configurations" do
      assert SearchSpace.latin_hypercube_sample(SearchSpace.from_parameters([]), 3) ==
               [%{}, %{}, %{}]
    end
  end
end
