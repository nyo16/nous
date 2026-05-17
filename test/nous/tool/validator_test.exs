defmodule Nous.Tool.ValidatorTest do
  use ExUnit.Case, async: true

  alias Nous.Tool.Validator

  describe "validate_types/2" do
    test "accepts values matching the declared type" do
      props = %{"count" => %{"type" => "integer"}}
      assert :ok = Validator.validate_types(%{"count" => 5}, props)
    end

    test "rejects values whose type does not match" do
      props = %{"count" => %{"type" => "integer"}}

      assert {:error, {:type_mismatch, [{"count", "integer", "string"}]}} =
               Validator.validate_types(%{"count" => "five"}, props)
    end

    test "enforces enum even when type is also declared" do
      # Before fix: %{"type" => _} clause matched before %{"enum" => _} so the
      # enum constraint was silently dropped — a tool restricted to
      # ["low", "high"] would accept any other string.
      props = %{"level" => %{"type" => "string", "enum" => ["low", "high"]}}

      assert :ok = Validator.validate_types(%{"level" => "low"}, props)

      assert {:error, {:type_mismatch, _}} =
               Validator.validate_types(%{"level" => "weird"}, props)
    end

    test "enforces enum when type is absent" do
      props = %{"level" => %{"enum" => [:a, :b]}}
      assert :ok = Validator.validate_types(%{"level" => :a}, props)
      assert {:error, _} = Validator.validate_types(%{"level" => :c}, props)
    end

    test "reports type and enum violations independently" do
      props = %{"level" => %{"type" => "string", "enum" => ["a", "b"]}}
      # Integer value violates BOTH the string type AND the enum.
      assert {:error, {:type_mismatch, errors}} =
               Validator.validate_types(%{"level" => 1}, props)

      keys = Enum.map(errors, fn {k, _, _} -> k end)
      assert "level" in keys
      # Two failures for the same field — once for type, once for enum.
      assert length(Enum.filter(errors, fn {k, _, _} -> k == "level" end)) == 2
    end

    test "ignores keys not declared in properties (additionalProperties: true)" do
      props = %{"declared" => %{"type" => "string"}}
      assert :ok = Validator.validate_types(%{"undeclared" => 123}, props)
    end
  end
end
