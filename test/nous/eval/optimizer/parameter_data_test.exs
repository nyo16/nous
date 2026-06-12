defmodule Nous.Eval.Optimizer.ParameterDataTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Optimizer.Parameter

  # These existing-atom names must be referenced so they exist at runtime for
  # String.to_existing_atom/1 (the safe-by-design guard in from_map/1).
  @known [:temperature, :max_tokens, :model, :use_cot]

  setup_all do
    # Force the known parameter-name atoms to exist.
    Enum.each(@known, &is_atom/1)
    :ok
  end

  describe "from_map/1 (safe data parsing — no code eval)" do
    test "builds a float parameter from string-keyed map" do
      assert {:ok, param} =
               Parameter.from_map(%{
                 "type" => "float",
                 "name" => "temperature",
                 "min" => 0.0,
                 "max" => 1.0,
                 "step" => 0.1
               })

      assert param.type == :float
      assert param.name == :temperature
      assert param.min == 0.0
      assert param.max == 1.0
      assert param.step == 0.1
    end

    test "builds an integer parameter" do
      assert {:ok, param} =
               Parameter.from_map(%{
                 "type" => "integer",
                 "name" => "max_tokens",
                 "min" => 256,
                 "max" => 2048,
                 "step" => 256
               })

      assert param.type == :integer
      assert param.name == :max_tokens
      assert param.step == 256
    end

    test "builds a choice parameter" do
      assert {:ok, param} =
               Parameter.from_map(%{
                 "type" => "choice",
                 "name" => "model",
                 "choices" => ["gpt-4", "gpt-4o"]
               })

      assert param.type == :choice
      assert param.choices == ["gpt-4", "gpt-4o"]
      assert param.default == "gpt-4"
    end

    test "builds a bool parameter with default" do
      assert {:ok, param} =
               Parameter.from_map(%{"type" => "bool", "name" => "use_cot", "default" => true})

      assert param.type == :bool
      assert param.default == true
    end

    test "accepts atom keys too" do
      assert {:ok, param} =
               Parameter.from_map(%{type: :float, name: :temperature, min: 0.0, max: 1.0})

      assert param.name == :temperature
    end

    test "rejects an unknown parameter name without minting an atom" do
      novel = "definitely_not_a_known_param_#{System.unique_integer([:positive])}"
      assert {:error, reason} = Parameter.from_map(%{"type" => "float", "name" => novel})
      assert reason =~ "unknown parameter name"
    end

    test "rejects an invalid type" do
      assert {:error, reason} =
               Parameter.from_map(%{"type" => "evil", "name" => "temperature"})

      assert reason =~ "invalid parameter type"
    end

    test "rejects a choice parameter with no choices" do
      assert {:error, reason} =
               Parameter.from_map(%{"type" => "choice", "name" => "model", "choices" => []})

      assert reason =~ "non-empty"
    end

    test "rejects non-map input" do
      assert {:error, _} = Parameter.from_map("not a map")
      assert {:error, _} = Parameter.from_map([1, 2, 3])
    end
  end
end
