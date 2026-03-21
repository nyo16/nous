defmodule Nous.Hook.RegistryTest do
  use ExUnit.Case, async: true

  alias Nous.Hook
  alias Nous.Hook.Registry

  defp make_hook(event, opts \\ []) do
    %Hook{
      event: event,
      type: :function,
      handler: Keyword.get(opts, :handler, fn _, _ -> :allow end),
      matcher: Keyword.get(opts, :matcher),
      priority: Keyword.get(opts, :priority, 100),
      name: Keyword.get(opts, :name)
    }
  end

  describe "new/0" do
    test "creates empty registry" do
      registry = Registry.new()
      assert registry.hooks == %{}
    end
  end

  describe "register/2" do
    test "adds hook to registry" do
      registry = Registry.new() |> Registry.register(make_hook(:pre_tool_use))
      assert length(Registry.hooks_for(registry, :pre_tool_use)) == 1
    end

    test "sorts hooks by priority" do
      h1 = make_hook(:pre_tool_use, priority: 200, name: "second")
      h2 = make_hook(:pre_tool_use, priority: 50, name: "first")
      h3 = make_hook(:pre_tool_use, priority: 100, name: "middle")

      registry =
        Registry.new() |> Registry.register(h1) |> Registry.register(h2) |> Registry.register(h3)

      hooks = Registry.hooks_for(registry, :pre_tool_use)

      assert Enum.map(hooks, & &1.name) == ["first", "middle", "second"]
    end

    test "keeps hooks separated by event type" do
      h1 = make_hook(:pre_tool_use)
      h2 = make_hook(:post_tool_use)

      registry = Registry.new() |> Registry.register(h1) |> Registry.register(h2)

      assert length(Registry.hooks_for(registry, :pre_tool_use)) == 1
      assert length(Registry.hooks_for(registry, :post_tool_use)) == 1
    end
  end

  describe "from_hooks/1" do
    test "builds registry from hook list" do
      hooks = [
        make_hook(:pre_tool_use, name: "a"),
        make_hook(:pre_tool_use, name: "b"),
        make_hook(:post_tool_use, name: "c")
      ]

      registry = Registry.from_hooks(hooks)
      assert length(Registry.hooks_for(registry, :pre_tool_use)) == 2
      assert length(Registry.hooks_for(registry, :post_tool_use)) == 1
    end
  end

  describe "hooks_for/3 with payload matching" do
    test "filters by tool name matcher" do
      h1 = make_hook(:pre_tool_use, matcher: "delete_file", name: "delete")
      h2 = make_hook(:pre_tool_use, matcher: "read_file", name: "read")
      h3 = make_hook(:pre_tool_use, name: "catchall")

      registry = Registry.from_hooks([h1, h2, h3])

      delete_hooks = Registry.hooks_for(registry, :pre_tool_use, %{tool_name: "delete_file"})
      assert length(delete_hooks) == 2
      assert "delete" in Enum.map(delete_hooks, & &1.name)
      assert "catchall" in Enum.map(delete_hooks, & &1.name)
    end

    test "regex matcher filters correctly" do
      h1 = make_hook(:pre_tool_use, matcher: ~r/^write/, name: "write_hook")
      h2 = make_hook(:pre_tool_use, matcher: "read_file", name: "read_hook")

      registry = Registry.from_hooks([h1, h2])

      hooks = Registry.hooks_for(registry, :pre_tool_use, %{tool_name: "write_data"})
      assert length(hooks) == 1
      assert hd(hooks).name == "write_hook"
    end
  end

  describe "has_hooks?/2" do
    test "returns false for empty registry" do
      refute Registry.has_hooks?(Registry.new(), :pre_tool_use)
    end

    test "returns true when hooks exist" do
      registry = Registry.new() |> Registry.register(make_hook(:pre_tool_use))
      assert Registry.has_hooks?(registry, :pre_tool_use)
      refute Registry.has_hooks?(registry, :post_tool_use)
    end
  end

  describe "count/1" do
    test "counts total hooks" do
      hooks = [make_hook(:pre_tool_use), make_hook(:pre_tool_use), make_hook(:post_tool_use)]
      registry = Registry.from_hooks(hooks)
      assert Registry.count(registry) == 3
    end
  end
end
