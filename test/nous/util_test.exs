defmodule Nous.UtilTest do
  use ExUnit.Case, async: true

  alias Nous.Util

  doctest Nous.Util

  describe "safe_existing_atom/2" do
    test "converts a binary to an existing atom" do
      assert Util.safe_existing_atom("ok") == :ok
    end

    test "returns the fallback for unknown atoms" do
      assert Util.safe_existing_atom("definitely_not_an_atom_xyz9") == nil

      assert Util.safe_existing_atom("definitely_not_an_atom_xyz9", "kept") ==
               "kept"
    end

    test "never mints new atoms" do
      binary = "unminted_atom_#{:erlang.unique_integer([:positive])}"
      assert Util.safe_existing_atom(binary, binary) == binary

      assert_raise ArgumentError, fn -> String.to_existing_atom(binary) end
    end

    test "atoms pass through unchanged" do
      assert Util.safe_existing_atom(:already) == :already
      assert Util.safe_existing_atom(nil) == nil
    end

    test "non-binary, non-atom input returns the fallback" do
      assert Util.safe_existing_atom(123) == nil
      assert Util.safe_existing_atom(%{}, :fallback) == :fallback
    end
  end

  describe "atomize_keys/1" do
    test "converts keys that are existing atoms" do
      assert Util.atomize_keys(%{"name" => "a", "id" => 1}) == %{name: "a", id: 1}
    end

    test "leaves unknown keys as binaries" do
      binary = "unknown_key_#{:erlang.unique_integer([:positive])}"
      assert Util.atomize_keys(%{binary => 1}) == %{binary => 1}
    end

    test "leaves values untouched and handles mixed keys" do
      assert Util.atomize_keys(%{"name" => %{"nested" => true}, already: :atom}) ==
               %{name: %{"nested" => true}, already: :atom}
    end
  end
end
