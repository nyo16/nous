defmodule Nous.Persistence.ETSTest do
  use ExUnit.Case, async: false

  alias Nous.Persistence.ETS

  setup do
    # Clean up the ETS table between tests
    if :ets.whereis(:nous_persistence) != :undefined do
      :ets.delete_all_objects(:nous_persistence)
    end

    :ok
  end

  describe "save/2" do
    test "saves data successfully" do
      assert :ok = ETS.save("session_1", %{version: 1, messages: []})
    end

    test "overwrites existing data" do
      ETS.save("session_1", %{version: 1, messages: ["old"]})
      ETS.save("session_1", %{version: 1, messages: ["new"]})

      {:ok, data} = ETS.load("session_1")
      assert data.messages == ["new"]
    end
  end

  describe "load/1" do
    test "loads saved data" do
      ETS.save("session_1", %{version: 1, system_prompt: "Be helpful"})

      {:ok, data} = ETS.load("session_1")
      assert data.version == 1
      assert data.system_prompt == "Be helpful"
    end

    test "returns :not_found for missing session" do
      assert {:error, :not_found} = ETS.load("nonexistent")
    end
  end

  describe "delete/1" do
    test "deletes saved data" do
      ETS.save("session_1", %{version: 1})
      assert :ok = ETS.delete("session_1")
      assert {:error, :not_found} = ETS.load("session_1")
    end

    test "succeeds even if session does not exist" do
      assert :ok = ETS.delete("nonexistent")
    end
  end

  describe "list/0" do
    test "lists all saved session IDs" do
      ETS.save("session_a", %{version: 1})
      ETS.save("session_b", %{version: 1})
      ETS.save("session_c", %{version: 1})

      {:ok, sessions} = ETS.list()
      assert Enum.sort(sessions) == ["session_a", "session_b", "session_c"]
    end

    test "returns empty list when no sessions exist" do
      {:ok, sessions} = ETS.list()
      assert sessions == []
    end
  end

  describe "lazy table creation" do
    test "creates table on first use" do
      # Delete the table if it exists
      if :ets.whereis(:nous_persistence) != :undefined do
        :ets.delete(:nous_persistence)
      end

      # First operation should create the table
      assert :ok = ETS.save("test", %{version: 1})
      assert :ets.whereis(:nous_persistence) != :undefined
    end
  end
end
