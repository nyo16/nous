defmodule Nous.Tools.SearchScrapeTest do
  # async: false — the UrlGuard escape hatch and the :web_fetch_max_bytes
  # ceiling are read from the global application environment.
  use ExUnit.Case, async: false

  alias Nous.RunContext
  alias Nous.Tools.SearchScrape

  # ~350 bytes on the wire, comfortably above every ceiling asserted below, but
  # under 50 characters of *extracted* text so Summarize short-circuits instead
  # of reaching for a model. WebFetch strips <script>, so the filler pads the
  # response without reaching the summarizer.
  @html """
  <html>
    <head><title>Test Page</title></head>
    <body>
      <article><p>Hello world</p></article>
      <script>var filler = "#{String.duplicate("f", 200)}";</script>
    </body>
  </html>
  """

  setup do
    # Bypass binds 127.0.0.1 and UrlGuard blocks loopback, so without a seam
    # the fetch path can never be exercised at all. The exact-IP escape hatch
    # opens 127.0.0.1 and nothing else.
    Application.put_env(:nous, :url_guard_allow_ips, [{127, 0, 0, 1}])

    on_exit(fn ->
      Application.delete_env(:nous, :url_guard_allow_ips)
      Application.delete_env(:nous, :web_fetch_max_bytes)
    end)

    {:ok, bypass: Bypass.open()}
  end

  defp url(bypass, path), do: "http://127.0.0.1:#{bypass.port}#{path}"

  defp scrape(ctx, bypass) do
    Bypass.expect_once(bypass, "GET", "/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, @html)
    end)

    SearchScrape.scrape_results(ctx, %{"urls" => [url(bypass, "/page")], "query" => "greeting"})
  end

  # This tool called WebFetch.do_fetch/1 bare, so every scrape used WebFetch's
  # compiled-in 5_000_000 default no matter what the host had declared — and
  # it fetches up to 50 pages per call. The ceilings below are far under the
  # page size, so a regression shows up as a *successful* fetch, not as a
  # different error string.
  describe "host-configured fetch ceiling (sec F-10)" do
    test "honours ctx.deps[:web_fetch_max_bytes]", %{bypass: bypass} do
      assert %{results: [result]} = scrape(RunContext.new(%{web_fetch_max_bytes: 64}), bypass)

      assert result.error =~ "exceeded the 64 byte limit"
      assert result.summary == nil
    end

    test "honours config :nous, :web_fetch_max_bytes", %{bypass: bypass} do
      Application.put_env(:nous, :web_fetch_max_bytes, 128)

      assert %{results: [result]} = scrape(RunContext.new(%{}), bypass)
      assert result.error =~ "exceeded the 128 byte limit"
    end

    test "deps win over application config, matching WebFetch", %{bypass: bypass} do
      Application.put_env(:nous, :web_fetch_max_bytes, 5_000_000)

      assert %{results: [result]} = scrape(RunContext.new(%{web_fetch_max_bytes: 64}), bypass)
      assert result.error =~ "exceeded the 64 byte limit"
    end

    test "with no ceiling configured the same page fetches normally", %{bypass: bypass} do
      assert %{results: [result], total_fetched: 1} = scrape(RunContext.new(%{}), bypass)

      refute Map.has_key?(result, :error)
      assert result.title == "Test Page"
      assert result.summary == "Hello world"
    end
  end

  # `urls`, `concurrency` and `timeout` all arrive from the model. `@max_urls`
  # and the two `clamp_int/3` calls are the only thing between a runaway model
  # and an unbounded parallel fetch, and none of them executed under test.
  describe "resource guards on model-supplied arguments (test F-9)" do
    test "fetches at most 50 URLs however many the model asks for", %{bypass: bypass} do
      tracker = start_tracker()
      Bypass.expect(bypass, tracking_handler(tracker, 0))

      urls = for i <- 1..60, do: url(bypass, "/u#{i}")

      assert %{results: results, total_requested: 50, total_fetched: 50, note: note} =
               SearchScrape.scrape_results(RunContext.new(%{}), %{
                 "urls" => urls,
                 "query" => "greeting"
               })

      assert note =~ "first 50"
      # The cap is a resource guard, so what it has to bound is the requests
      # that leave the node, not the length of the list handed back.
      assert length(requested_paths(tracker)) == 50
      assert Enum.map(results, & &1.url) == Enum.take(urls, 50)
    end

    test "a list within the cap carries no truncation note", %{bypass: bypass} do
      tracker = start_tracker()
      Bypass.expect(bypass, tracking_handler(tracker, 0))

      urls = for i <- 1..3, do: url(bypass, "/u#{i}")

      result =
        SearchScrape.scrape_results(RunContext.new(%{}), %{"urls" => urls, "query" => "greeting"})

      assert %{total_requested: 3, total_fetched: 3} = result
      refute Map.has_key?(result, :note)
      assert length(requested_paths(tracker)) == 3
    end

    test "clamps a model-supplied concurrency down to 20", %{bypass: bypass} do
      tracker = start_tracker()
      # Each page is held open long enough that every task the stream is willing
      # to run at once is observably in flight at the same instant.
      Bypass.expect(bypass, tracking_handler(tracker, 50))

      urls = for i <- 1..40, do: url(bypass, "/u#{i}")

      assert %{total_fetched: 40} =
               SearchScrape.scrape_results(RunContext.new(%{}), %{
                 "urls" => urls,
                 "query" => "greeting",
                 "concurrency" => 1_000
               })

      observed = max_in_flight(tracker)
      # Without real parallelism the ceiling below would hold for any
      # implementation, including a serial one.
      assert observed > 1
      assert observed <= 20, "concurrency clamp let #{observed} fetches run at once"
    end

    test "clamps a model-supplied concurrency up to 1", %{bypass: bypass} do
      tracker = start_tracker()
      Bypass.expect(bypass, tracking_handler(tracker, 20))

      urls = for i <- 1..4, do: url(bypass, "/u#{i}")

      assert %{total_fetched: 4} =
               SearchScrape.scrape_results(RunContext.new(%{}), %{
                 "urls" => urls,
                 "query" => "greeting",
                 "concurrency" => 0
               })

      assert max_in_flight(tracker) == 1
    end

    test "a non-integer concurrency degrades to serial instead of crashing", %{bypass: bypass} do
      tracker = start_tracker()
      Bypass.expect(bypass, tracking_handler(tracker, 20))

      urls = for i <- 1..4, do: url(bypass, "/u#{i}")

      # A model that emits `"20"` reaches `Task.async_stream`'s `max_concurrency`
      # unguarded; the fallback clause is what turns that into slow, not fatal.
      assert %{total_fetched: 4} =
               SearchScrape.scrape_results(RunContext.new(%{}), %{
                 "urls" => urls,
                 "query" => "greeting",
                 "concurrency" => "20"
               })

      assert max_in_flight(tracker) == 1
    end

    test "raises a model-supplied timeout to the one-second floor", %{bypass: bypass} do
      tracker = start_tracker()
      # 400ms of server latency: comfortably inside the 1_000ms floor and
      # comfortably outside the 50ms the model asked for.
      Bypass.expect(bypass, tracking_handler(tracker, 400))

      assert %{total_fetched: 1, results: [result]} =
               SearchScrape.scrape_results(RunContext.new(%{}), %{
                 "urls" => [url(bypass, "/slow")],
                 "query" => "greeting",
                 "timeout" => 50
               })

      assert result.title == "Test Page"
    end

    test "an empty URL list short-circuits without issuing a request", %{bypass: bypass} do
      tracker = start_tracker()
      Bypass.stub(bypass, "GET", "/page", tracking_handler(tracker, 0))

      assert %{results: [], error: "No URLs provided"} =
               SearchScrape.scrape_results(RunContext.new(%{}), %{"urls" => [], "query" => "q"})

      assert requested_paths(tracker) == []
    end

    test "a failed page still yields an entry so the model sees the gap", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        case conn.request_path do
          "/ok" ->
            html_page(conn)

          "/boom" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/pdf")
            |> Plug.Conn.resp(200, "%PDF-1.7")
        end
      end)

      assert %{results: [ok, failed], total_fetched: 2, total_requested: 2} =
               SearchScrape.scrape_results(RunContext.new(%{}), %{
                 "urls" => [url(bypass, "/ok"), url(bypass, "/boom")],
                 "query" => "greeting"
               })

      assert ok.title == "Test Page"

      assert %{title: nil, summary: nil, key_facts: []} = failed
      assert failed.relevance == 0.0
      assert failed.url == url(bypass, "/boom")
      assert failed.error =~ "Unsupported content-type"
    end
  end

  defp start_tracker do
    start_supervised!({Agent, fn -> %{in_flight: 0, max_in_flight: 0, paths: []} end})
  end

  # Records every request path and the peak number of handlers running at once,
  # so the caps can be asserted against traffic rather than return values.
  defp tracking_handler(tracker, hold_ms) do
    fn conn ->
      Agent.update(tracker, fn state ->
        in_flight = state.in_flight + 1

        %{
          state
          | in_flight: in_flight,
            max_in_flight: max(state.max_in_flight, in_flight),
            paths: [conn.request_path | state.paths]
        }
      end)

      if hold_ms > 0, do: Process.sleep(hold_ms)
      Agent.update(tracker, &%{&1 | in_flight: &1.in_flight - 1})

      html_page(conn)
    end
  end

  defp requested_paths(tracker), do: Agent.get(tracker, & &1.paths)
  defp max_in_flight(tracker), do: Agent.get(tracker, & &1.max_in_flight)

  defp html_page(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.resp(200, @html)
  end
end
