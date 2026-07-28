defmodule Nous.ApplicationTest do
  use ExUnit.Case, async: false

  describe "finch_pools/0 (P-2)" do
    setup do
      previous = Application.get_env(:nous, :finch_pools)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:nous, :finch_pools)
          prev -> Application.put_env(:nous, :finch_pools, prev)
        end
      end)

      :ok
    end

    test "defaults to Finch's own pool size, sharded across pool processes" do
      Application.delete_env(:nous, :finch_pools)

      assert %{default: default} = Nous.Application.finch_pools()

      # Was size: 10, count: 1 — a node-wide ceiling of 10 in-flight requests
      # per provider host, below Finch's own default of 50, with every checkout
      # funnelled through a single pool process.
      assert default[:size] == 50
      assert default[:count] == min(System.schedulers_online(), 4)
      assert default[:count] >= 1
    end

    test "app env overrides the defaults, including per-host pools" do
      override = %{
        "https://api.openai.com" => [size: 200, count: 8],
        default: [size: 25, count: 2]
      }

      Application.put_env(:nous, :finch_pools, override)

      assert Nous.Application.finch_pools() == override
    end
  end
end
