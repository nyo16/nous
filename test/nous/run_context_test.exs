defmodule Nous.RunContextTest do
  use ExUnit.Case, async: true

  alias Nous.{RunContext, Usage}

  doctest RunContext

  describe "new/2" do
    test "creates context with dependencies" do
      deps = %{database: :my_db, api_key: "secret"}

      ctx = RunContext.new(deps)

      assert ctx.deps == deps
      assert ctx.retry == 0
      assert ctx.usage == %Usage{}
    end

    test "accepts retry option" do
      ctx = RunContext.new(:deps, retry: 3)

      assert ctx.retry == 3
    end

    test "accepts usage option" do
      usage = %Usage{total_tokens: 100}

      ctx = RunContext.new(:deps, usage: usage)

      assert ctx.usage == usage
    end

    test "accepts all options" do
      deps = %{database: :db}
      usage = %Usage{requests: 5}

      ctx = RunContext.new(deps, retry: 2, usage: usage)

      assert ctx.deps == deps
      assert ctx.retry == 2
      assert ctx.usage == usage
    end
  end

  describe "struct access" do
    test "allows accessing deps" do
      deps = %{database: MyApp.Database}
      ctx = RunContext.new(deps)

      assert ctx.deps.database == MyApp.Database
    end

    test "allows pattern matching" do
      deps = %{value: 42}
      ctx = RunContext.new(deps)

      assert %RunContext{deps: %{value: 42}} = ctx
    end
  end
end
