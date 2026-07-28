defmodule Nous.Persistence.ETSTest do
  use ExUnit.Case, async: false

  alias Nous.Persistence.ETS

  setup do
    # Clean up the ETS table between tests via the owner (table is :protected).
    ETS.clear()
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
      # Assert membership, not exact equality: :nous_persistence is a supervised
      # singleton table, so another test sharing it could otherwise make an
      # exact-list assertion flaky.
      assert "session_a" in sessions
      assert "session_b" in sessions
      assert "session_c" in sessions
    end

    test "returns empty list when no sessions exist" do
      {:ok, sessions} = ETS.list()
      assert sessions == []
    end
  end

  describe "table ownership" do
    test "save/load operate against the supervised owner's protected table" do
      assert :ok = ETS.save("test", %{version: 1})
      assert {:ok, %{version: 1}} = ETS.load("test")
      assert :ets.whereis(:nous_persistence) != :undefined
    end

    test "table is :protected (not writable by arbitrary processes)" do
      # A foreign process must not be able to write/delete directly.
      assert :protected = :ets.info(:nous_persistence, :protection)
    end
  end

  describe "eviction bounds (P-2)" do
    test "max_entries caps the table, evicting the oldest writes first" do
      with_persistence_config!(max_entries: 20, ttl: :infinity)

      for i <- 1..5, do: :ok = ETS.save("old_#{i}", %{version: 1})

      # saved_at has millisecond resolution; a gap makes eviction order
      # unambiguous rather than tie-broken by session id.
      Process.sleep(5)

      for i <- 1..20, do: :ok = ETS.save("new_#{i}", %{version: 1})

      assert :ets.info(:nous_persistence, :size) <= 20

      for i <- 1..5 do
        assert {:error, :not_found} == ETS.load("old_#{i}")
      end

      assert {:ok, %{version: 1}} = ETS.load("new_20")
    end

    test "the ttl sweep drops entries that have aged out" do
      with_persistence_config!(ttl: 100, sweep_interval: 30, max_entries: :infinity)

      :ok = ETS.save("stale", %{version: 1})
      assert {:ok, %{version: 1}} = ETS.load("stale")

      # ttl plus several sweep intervals.
      Process.sleep(250)

      assert {:error, :not_found} == ETS.load("stale")

      :ok = ETS.save("fresh", %{version: 1})
      assert {:ok, %{version: 1}} = ETS.load("fresh")
    end

    test "both bounds can be disabled with :infinity" do
      with_persistence_config!(ttl: :infinity, max_entries: :infinity)

      for i <- 1..50, do: :ok = ETS.save("unbounded_#{i}", %{version: 1})

      assert :ets.info(:nous_persistence, :size) == 50
      assert {:ok, %{version: 1}} = ETS.load("unbounded_1")
    end

    test "defaults evict nothing a normal run writes" do
      # No app env: 10_000 entries / 24h, so the defaults are invisible.
      for i <- 1..100, do: :ok = ETS.save("default_#{i}", %{version: 1})

      assert :ets.info(:nous_persistence, :size) == 100
      assert {:ok, %{version: 1}} = ETS.load("default_1")
    end
  end

  # The owner is a supervised singleton that reads its bounds from app env at
  # init, so exercising them means restarting it. terminate_child +
  # restart_child is deterministic (no monitors, no restart-intensity churn),
  # and this file is async: false — nothing else touches :nous_persistence
  # while it runs.
  defp with_persistence_config!(config) do
    previous = Application.get_env(:nous, :persistence_ets)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:nous, :persistence_ets)
        prev -> Application.put_env(:nous, :persistence_ets, prev)
      end

      restart_owner!()
    end)

    Application.put_env(:nous, :persistence_ets, config)
    restart_owner!()
  end

  defp restart_owner! do
    :ok = Supervisor.terminate_child(Nous.Supervisor, Nous.Persistence.ETS)

    case Supervisor.restart_child(Nous.Supervisor, Nous.Persistence.ETS) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
    end
  end
end
