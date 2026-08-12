# `muninn` and `zvec` are commented out in mix.exs, so the module compiled into
# this project is the deps-unavailable branch of lib/nous/memory/store/hybrid.ex.
# Every callback on that branch must return a friendly {:error, reason} instead
# of raising UndefinedFunctionError at the call site.
unless Code.ensure_loaded?(Muninn) and Code.ensure_loaded?(Zvec) do
  defmodule Nous.Memory.Store.HybridTest do
    use ExUnit.Case, async: true

    alias Nous.Memory.Store.Hybrid

    describe "deps-unavailable branch" do
      test "init/1 returns an error tuple rather than raising" do
        assert {:error, reason} = Hybrid.init([])
        assert reason =~ "not available"
      end

      test "search_text/3 returns an error tuple rather than raising" do
        assert {:error, reason} = Hybrid.search_text(%{}, "query", [])
        assert reason =~ "not available"
      end

      test "search_vector/3 returns an error tuple rather than raising" do
        assert {:error, reason} = Hybrid.search_vector(%{}, [0.1, 0.2, 0.3], [])
        assert reason =~ "not available"
      end

      test "exports every Nous.Memory.Store callback the available branch does" do
        exports = Hybrid.__info__(:functions)

        for {fun, arity} <- [
              init: 1,
              store: 2,
              fetch: 2,
              delete: 2,
              update: 3,
              search_text: 3,
              search_vector: 3,
              list: 2
            ] do
          assert {fun, arity} in exports,
                 "Nous.Memory.Store.Hybrid is missing #{fun}/#{arity} on the fallback branch"
        end
      end
    end
  end
end
