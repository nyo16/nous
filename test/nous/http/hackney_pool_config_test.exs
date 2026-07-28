defmodule Nous.HTTP.HackneyPoolConfigTest do
  # async: false — mutates the global :default hackney pool.
  use ExUnit.Case, async: false

  # `:hackney_pool.set_timeout/2` and `set_max_connections/2` are casts, so the
  # pool gen_server applies them asynchronously. Poll to a deadline instead of
  # sleeping a fixed budget and hoping (the previous `Process.sleep(20)` was an
  # acknowledged race).
  @deadline_ms 1_000

  defp eventually(fun, remaining \\ @deadline_ms) do
    cond do
      fun.() ->
        true

      remaining <= 0 ->
        false

      true ->
        Process.sleep(5)
        eventually(fun, remaining - 5)
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:hackney)

    prev_config = Application.fetch_env(:nous, :hackney_pool)
    pool_existed? = :hackney_pool.max_connections(:default) != 0
    prev_max = :hackney_pool.max_connections(:default)
    prev_timeout = :hackney_pool.timeout(:default)

    on_exit(fn ->
      if pool_existed? do
        :hackney_pool.set_max_connections(:default, prev_max)
        :hackney_pool.set_timeout(:default, prev_timeout)
      else
        # We started the pool; leave hackney as we found it so the lazy-start
        # path is still the one the rest of the suite exercises.
        :hackney_pool.stop_pool(:default)
      end

      case prev_config do
        {:ok, value} -> Application.put_env(:nous, :hackney_pool, value)
        :error -> Application.delete_env(:nous, :hackney_pool)
      end
    end)

    %{pool_existed?: pool_existed?}
  end

  describe "Nous.Application.configure_hackney_pool/0" do
    # This is the boot-time case, and it used to silently do nothing: hackney
    # creates the `:default` pool lazily on first checkout, `set_max_connections/2`
    # is a cast to `find_pool(:default)`, and a cast to an unregistered name
    # succeeds. Deleting the `start_pool/2` call from Nous.Application turns this
    # test red instead of shipping a config knob that has no effect.
    test "creates the :default pool and applies the configured values", %{
      pool_existed?: pool_existed?
    } do
      if pool_existed?, do: :hackney_pool.stop_pool(:default)
      assert :hackney_pool.max_connections(:default) == 0, "expected no :default pool"

      # hackney 4 caps the keepalive timeout at 2s, so 1500ms is a value the
      # pool reports back verbatim.
      Application.put_env(:nous, :hackney_pool, max_connections: 137, timeout: 1_500)

      assert :ok = Nous.Application.configure_hackney_pool()

      assert eventually(fn -> :hackney_pool.max_connections(:default) == 137 end),
             "expected max_connections 137, got #{:hackney_pool.max_connections(:default)}"

      assert eventually(fn -> :hackney_pool.timeout(:default) == 1_500 end),
             "expected timeout 1500, got #{:hackney_pool.timeout(:default)}"
    end

    test "reconfigures a pool that is already running" do
      :hackney_pool.start_pool(:default, [])
      Application.put_env(:nous, :hackney_pool, max_connections: 88, timeout: 1_300)

      assert :ok = Nous.Application.configure_hackney_pool()

      assert eventually(fn -> :hackney_pool.max_connections(:default) == 88 end)
      assert eventually(fn -> :hackney_pool.timeout(:default) == 1_300 end)
    end

    test "applies only the keys that are present" do
      :hackney_pool.start_pool(:default, [])
      :hackney_pool.set_timeout(:default, 1_200)
      assert eventually(fn -> :hackney_pool.timeout(:default) == 1_200 end)

      Application.put_env(:nous, :hackney_pool, max_connections: 91)

      assert :ok = Nous.Application.configure_hackney_pool()
      assert eventually(fn -> :hackney_pool.max_connections(:default) == 91 end)

      # A partial config must not reset the untouched knob to a default.
      assert :hackney_pool.timeout(:default) == 1_200
    end

    test "is a no-op when :nous, :hackney_pool is unset" do
      # Move the pool to distinctive values first, so "unchanged" is a claim
      # that can actually be violated — the helper writing any default, or
      # starting/restarting the pool, would overwrite these.
      :hackney_pool.start_pool(:default, [])
      :hackney_pool.set_max_connections(:default, 73)
      :hackney_pool.set_timeout(:default, 1_100)
      assert eventually(fn -> :hackney_pool.max_connections(:default) == 73 end)
      assert eventually(fn -> :hackney_pool.timeout(:default) == 1_100 end)

      Application.delete_env(:nous, :hackney_pool)

      assert :ok = Nous.Application.configure_hackney_pool()

      assert :hackney_pool.max_connections(:default) == 73
      assert :hackney_pool.timeout(:default) == 1_100
    end
  end
end
