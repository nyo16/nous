defmodule Nous.Eval.Evaluators.SchemaAtomSafetyTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Evaluators.Schema

  defmodule Sample do
    defstruct [:name, :email]
  end

  describe "required_fields from arbitrary YAML" do
    test "an unknown field name is treated as missing and is NOT interned as an atom" do
      # Simulates a YAML `expected.required_fields:` entry the author controls.
      bogus = "totally_unknown_field_#{System.unique_integer([:positive])}"
      actual = %Sample{name: "x", email: nil}
      expected = %{schema: Sample, required_fields: [bogus]}

      result = Schema.evaluate(actual, expected, %{validate_changeset: false})

      assert result.passed == false
      assert result.reason =~ "Missing required fields"

      # The DoS guard: a novel field name must never create a new atom. If the
      # evaluator had used String.to_atom/1, this would now succeed.
      assert_raise ArgumentError, fn -> String.to_existing_atom(bogus) end
    end

    test "a known field name still resolves and passes when present" do
      actual = %Sample{name: "x", email: "y@example.com"}
      expected = %{schema: Sample, required_fields: ["name", "email"]}

      result = Schema.evaluate(actual, expected, %{validate_changeset: false})

      assert result.passed == true
    end
  end

  describe "field_values from arbitrary YAML" do
    test "an unknown field name is a mismatch and is NOT interned as an atom" do
      bogus = "phantom_value_field_#{System.unique_integer([:positive])}"
      actual = %Sample{name: "x"}
      expected = %{schema: Sample, field_values: %{bogus => "expected"}}

      result = Schema.evaluate(actual, expected, %{validate_changeset: false})

      assert result.passed == false
      assert_raise ArgumentError, fn -> String.to_existing_atom(bogus) end
    end
  end
end
