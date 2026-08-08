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

  describe "children/0 (P-2)" do
    test "the Finch child spec actually carries the pool configuration" do
      # finch_pools/0 returning the right map is worth nothing if the value
      # never reaches the child spec. Deleting `pools: finch_pools()` restores
      # the exact P-2 bug these tests were written to prevent and leaves both
      # tests above green, because neither looks at what gets configured.
      assert {Finch, opts} = Enum.find(Nous.Application.children(), &match?({Finch, _}, &1))
      assert opts[:name] == Nous.Finch
      assert opts[:pools] == Nous.Application.finch_pools()
    end

    test "children/0 is the list the running supervisor was started with" do
      # Stops children/0 from drifting into a test-only accessor describing a
      # tree nothing starts: every id it declares must be running right now.
      declared = Enum.map(Nous.Application.children(), &Supervisor.child_spec(&1, []).id)
      running = Nous.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

      assert Enum.sort(declared) == Enum.sort(running)
    end
  end

  describe "task_supervisor_max_children/0 (perf F-4)" do
    setup do
      previous = Application.get_env(:nous, :task_supervisor_max_children)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:nous, :task_supervisor_max_children)
          prev -> Application.put_env(:nous, :task_supervisor_max_children, prev)
        end
      end)

      :ok
    end

    test "the running Nous.TaskSupervisor actually carries the ceiling" do
      # Asserting the accessor's return value would pass with the option never
      # reaching the child spec, which is precisely how a bound goes missing.
      # Read it off the live supervisor instead.
      assert %DynamicSupervisor{max_children: max} = :sys.get_state(Nous.TaskSupervisor)

      refute max == :infinity,
             "Nous.TaskSupervisor is unbounded again: per-unit fan-out limits " <>
               "multiply across concurrent runs with nothing above them"

      assert max == Nous.Application.task_supervisor_max_children()
    end

    test "app env overrides the default" do
      Application.delete_env(:nous, :task_supervisor_max_children)
      assert Nous.Application.task_supervisor_max_children() == 1_000

      Application.put_env(:nous, :task_supervisor_max_children, 42)
      assert Nous.Application.task_supervisor_max_children() == 42
    end
  end
end
