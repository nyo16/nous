defmodule Nous.Tools.Search.CommonTest do
  use ExUnit.Case, async: false

  alias Nous.Tools.Search.Common

  defp ctx(deps \\ %{}), do: Nous.RunContext.new(deps)

  describe "api_key/3" do
    test "context deps win" do
      assert Common.api_key(ctx(%{fake_search_key: "from-deps"}), :fake_search_key, "NOUS_X") ==
               "from-deps"
    end

    test "application env is the second choice" do
      Application.put_env(:nous, :fake_search_key, "from-config")
      on_exit(fn -> Application.delete_env(:nous, :fake_search_key) end)

      assert Common.api_key(ctx(), :fake_search_key, "NOUS_X") == "from-config"
    end

    test "system env is the fallback" do
      System.put_env("NOUS_FAKE_SEARCH_KEY", "from-env")
      on_exit(fn -> System.delete_env("NOUS_FAKE_SEARCH_KEY") end)

      assert Common.api_key(ctx(), :fake_search_key, "NOUS_FAKE_SEARCH_KEY") == "from-env"
    end
  end

  describe "query/1" do
    test "accepts \"query\", falls back to \"q\", defaults to empty" do
      assert Common.query(%{"query" => "elixir"}) == "elixir"
      assert Common.query(%{"q" => "beam"}) == "beam"
      assert Common.query(%{}) == ""
    end
  end

  describe "run_search/4" do
    @opts [
      missing_key_error: "KEY not configured",
      log_label: "Fake search",
      error_prefix: "Search failed"
    ]

    test "missing or empty key returns the error envelope without running" do
      for key <- [nil, ""] do
        assert Common.run_search("q", key, @opts, fn -> flunk("should not run") end) ==
                 %{query: "q", error: "KEY not configured", success: false}
      end
    end

    test "success merges query and success into the envelope" do
      result =
        Common.run_search("q", "key", @opts, fn ->
          {:ok, %{results: [1], result_count: 1}}
        end)

      assert result == %{query: "q", results: [1], result_count: 1, success: true}
    end

    test "errors become the failure envelope" do
      result = Common.run_search("q", "key", @opts, fn -> {:error, :timeout} end)

      assert result == %{query: "q", error: "Search failed: :timeout", success: false}
    end
  end

  describe "tool integration (no network)" do
    test "BraveSearch returns the missing-key envelope" do
      # An empty-string dep short-circuits key resolution deterministically,
      # regardless of the machine's BRAVE_API_KEY.
      ctx = ctx(%{brave_api_key: ""})

      assert %{success: false, query: "elixir", error: error} =
               Nous.Tools.BraveSearch.web_search(ctx, %{"query" => "elixir"})

      assert error =~ "BRAVE_API_KEY not configured"

      assert %{success: false, error: "BRAVE_API_KEY not configured"} =
               Nous.Tools.BraveSearch.news_search(ctx, %{"q" => "elixir"})
    end

    test "TavilySearch returns the missing-key envelope" do
      ctx = ctx(%{tavily_api_key: ""})

      assert %{success: false, query: "beam", error: error} =
               Nous.Tools.TavilySearch.search(ctx, %{"query" => "beam"})

      assert error =~ "TAVILY_API_KEY not configured"
    end
  end

  describe "map_results/2" do
    test "maps fields with and without defaults" do
      results = [%{"title" => "T", "url" => "U"}]

      mapped =
        Common.map_results(results,
          title: {"title", ""},
          url: {"url", ""},
          age: "age"
        )

      assert mapped == [%{title: "T", url: "U", age: nil}]
    end

    test "non-list input maps to an empty list" do
      assert Common.map_results(%{"unexpected" => true}, title: {"title", ""}) == []
      assert Common.map_results(nil, title: {"title", ""}) == []
    end
  end
end
