defmodule Nous.PersistenceTest do
  use ExUnit.Case, async: true

  doctest Nous.Persistence

  describe "decode_keys/1" do
    test "converts top-level string keys to their existing atoms" do
      assert Nous.Persistence.decode_keys(%{"session_id" => "abc", "messages" => []}) ==
               %{session_id: "abc", messages: []}
    end

    # The whole point of the helper: a key written by an older release must not
    # take down every subsequent load of that session.
    test "leaves a key with no existing atom as a binary instead of raising" do
      data = %{"session_id" => "abc", "retired_field_from_an_old_release" => 1}

      assert Nous.Persistence.decode_keys(data) ==
               %{"retired_field_from_an_old_release" => 1, session_id: "abc"}
    end

    test "does not create the atom it declined to resolve" do
      key = "nous_persistence_never_minted_#{System.unique_integer([:positive])}"

      assert Nous.Persistence.decode_keys(%{key => 1}) == %{key => 1}
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "passes atom keys through untouched" do
      assert Nous.Persistence.decode_keys(%{session_id: "abc"}) == %{session_id: "abc"}
    end

    test "only re-keys the top level; nested maps are returned as-is" do
      assert Nous.Persistence.decode_keys(%{"messages" => [%{"role" => "user"}]}) ==
               %{messages: [%{"role" => "user"}]}
    end

    test "an empty map decodes to an empty map" do
      assert Nous.Persistence.decode_keys(%{}) == %{}
    end
  end
end
