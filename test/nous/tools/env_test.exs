defmodule Nous.Tools.EnvTest do
  use ExUnit.Case, async: false

  alias Nous.Tools.Env

  describe "scrubbed/0" do
    test "forwards only allowlisted variables" do
      System.put_env("NOUS_FAKE_API_KEY", "secret")
      on_exit(fn -> System.delete_env("NOUS_FAKE_API_KEY") end)

      env = Env.scrubbed()
      names = Enum.map(env, fn {name, _} -> name end)

      refute "NOUS_FAKE_API_KEY" in names
      assert Enum.all?(names, &(&1 in ~w(PATH HOME LANG LC_ALL TZ USER SHELL TERM)))
    end

    test "includes set allowlisted variables with their values" do
      System.put_env("TZ", "UTC")
      on_exit(fn -> System.delete_env("TZ") end)

      assert {"TZ", "UTC"} in Env.scrubbed()
    end

    test "drops unset allowlisted variables instead of emitting nil" do
      original = System.get_env("LC_ALL")
      System.delete_env("LC_ALL")

      on_exit(fn ->
        if original, do: System.put_env("LC_ALL", original)
      end)

      refute Enum.any?(Env.scrubbed(), fn {name, _} -> name == "LC_ALL" end)
      refute Enum.any?(Env.scrubbed(), fn {_, value} -> is_nil(value) end)
    end
  end
end
