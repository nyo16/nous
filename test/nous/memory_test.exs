defmodule Nous.MemoryTest do
  use ExUnit.Case, async: true

  alias Nous.Memory

  describe "validate_config/1" do
    test "rejects a config without a store" do
      assert {:error, reason} = Memory.validate_config(%{})
      assert reason =~ ":store is required"

      assert {:error, _} = Memory.validate_config(%{store: nil})
    end

    test "fills in every default without touching what the caller set" do
      assert {:ok, config} = Memory.validate_config(%{store: Memory.Store.ETS, inject_limit: 9})

      assert config.store == Memory.Store.ETS
      assert config.inject_limit == 9
      assert config.auto_inject == true
      assert config.inject_strategy == :first_only
      assert config.inject_min_score == 0.3
      assert config.default_search_scope == :agent
      assert config.auto_update_memory == false
      assert config.auto_update_every == 1
      assert Keyword.keys(config.scoring_weights) == [:relevance, :importance, :recency]
    end

    test "preserves keys it does not know about" do
      assert {:ok, config} = Memory.validate_config(%{store: Memory.Store.ETS, my_app: :thing})
      assert config.my_app == :thing
    end

    test "accepts any store module without loading it" do
      # The store is feature-detected at use time, not here: a config pointing
      # at a module that does not exist yet (an app's own backend, compiled
      # later) must still validate.
      assert {:ok, %{store: MyApp.NotCompiled}} =
               Memory.validate_config(%{store: MyApp.NotCompiled})
    end
  end
end
