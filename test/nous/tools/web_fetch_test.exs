defmodule Nous.Tools.WebFetchTest do
  # Not async: the UrlGuard escape hatch and the :web_fetch_max_bytes ceiling
  # are read from the global application environment.
  use ExUnit.Case, async: false

  alias Nous.RunContext
  alias Nous.Tools.WebFetch

  @html """
  <html>
    <head><title>Test Page</title></head>
    <body>
      <nav>skip this nav</nav>
      <article><p>Hello world</p></article>
      <script>window.evil = 1</script>
    </body>
  </html>
  """

  setup do
    # Bypass binds 127.0.0.1 and UrlGuard blocks loopback, so without a seam
    # the fetch path can never be exercised at all. The exact-IP escape hatch
    # opens 127.0.0.1 and nothing else: 169.254.169.254 stays blocked, which is
    # precisely what the redirect tests below rely on. Deleted rather than reset
    # to [] on exit so what gets restored is the real default.
    Application.put_env(:nous, :url_guard_allow_ips, [{127, 0, 0, 1}])

    on_exit(fn ->
      Application.delete_env(:nous, :url_guard_allow_ips)
      Application.delete_env(:nous, :web_fetch_max_bytes)
    end)

    {:ok, bypass: Bypass.open()}
  end

  defp url(bypass, path), do: "http://127.0.0.1:#{bypass.port}#{path}"

  defp html(conn, body \\ @html) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.resp(200, body)
  end

  defp redirect(conn, location) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.resp(302, "")
  end

  # The whole body is written before the client aborts, so cancelling the
  # transfer cannot crash the Bypass plug mid-send.
  defp oversized(conn), do: html(conn, String.duplicate("a", 2_000))

  describe "do_fetch/3 happy path" do
    test "extracts the title and the main content", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/page", &html/1)

      assert {:ok, page} = WebFetch.do_fetch(url(bypass, "/page"))
      assert page.title == "Test Page"
      assert page.content == "Hello world"
      assert page.word_count == 2
      assert {:ok, _, _} = DateTime.from_iso8601(page.fetched_at)
    end

    test "honours a CSS selector", %{bypass: bypass} do
      body = ~s(<html><body><p class="a">keep</p><p class="b">drop</p></body></html>)
      Bypass.expect_once(bypass, "GET", "/page", &html(&1, body))

      assert {:ok, %{content: "keep"}} = WebFetch.do_fetch(url(bypass, "/page"), ".a")
    end

    test "accepts text/plain and strips the charset parameter", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/page", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=UTF-8")
        |> Plug.Conn.resp(200, "just some words")
      end)

      assert {:ok, %{content: "just some words"}} = WebFetch.do_fetch(url(bypass, "/page"))
    end
  end

  describe "redirects (SSRF defence)" do
    test "refuses a redirect to cloud metadata and never opens the next hop", %{bypass: bypass} do
      internal = Bypass.open()
      test_pid = self()

      # A stub, not an expectation: it is allowed to receive zero requests. If
      # the guard ever stopped re-validating redirect targets this would fire
      # and the refute_received below would catch it.
      Bypass.stub(internal, "GET", "/pwned", fn conn ->
        send(test_pid, :internal_endpoint_reached)
        Plug.Conn.resp(conn, 200, "credentials")
      end)

      Bypass.expect_once(bypass, "GET", "/start", fn conn ->
        redirect(conn, "http://169.254.169.254:#{internal.port}/pwned")
      end)

      assert {:error, reason} = WebFetch.do_fetch(url(bypass, "/start"))
      assert reason =~ "private/loopback/link-local"
      refute_received :internal_endpoint_reached
    end

    test "refuses a link-local URL handed straight to the tool" do
      assert {:error, reason} = WebFetch.do_fetch("http://169.254.169.254/latest/meta-data/")
      assert reason =~ "private/loopback/link-local"
    end

    test "resolves a relative Location against the current URL", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/start", &redirect(&1, "/final"))
      Bypass.expect_once(bypass, "GET", "/final", &html/1)

      assert {:ok, %{title: "Test Page"}} = WebFetch.do_fetch(url(bypass, "/start"))
    end

    test "re-validates a protocol-relative Location after resolving it", %{bypass: bypass} do
      # "//169.254.169.254/" inherits the http scheme from the current URL; the
      # merged absolute URL must go back through the guard.
      Bypass.expect_once(bypass, "GET", "/start", &redirect(&1, "//169.254.169.254/"))

      assert {:error, reason} = WebFetch.do_fetch(url(bypass, "/start"))
      assert reason =~ "private/loopback/link-local"
    end

    test "gives up on a chain longer than the redirect cap", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/loop", &redirect(&1, "/loop"))

      assert {:error, "Too many redirects"} = WebFetch.do_fetch(url(bypass, "/loop"))
    end

    test "reports a redirect with no Location header", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/start", &Plug.Conn.resp(&1, 302, ""))

      assert {:error, reason} = WebFetch.do_fetch(url(bypass, "/start"))
      assert reason =~ "no Location header"
    end
  end

  describe "response size cap" do
    test "rejects a body past the cap instead of buffering it", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/big", &oversized/1)

      assert {:error, reason} = WebFetch.do_fetch(url(bypass, "/big"), nil, max_bytes: 64)
      assert reason =~ "exceeded the 64 byte limit"
    end

    test "a body under the cap is returned untouched", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/page", &html/1)

      assert {:ok, %{title: "Test Page"}} =
               WebFetch.do_fetch(url(bypass, "/page"), nil, max_bytes: 5_000)
    end

    test "ctx deps set the ceiling", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/big", &oversized/1)
      ctx = RunContext.new(%{web_fetch_max_bytes: 64})

      assert %{success: false, error: error} =
               WebFetch.fetch_page(ctx, %{"url" => url(bypass, "/big")})

      assert error =~ "exceeded the 64 byte limit"
    end

    test "application config is the fallback ceiling", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/big", &oversized/1)
      Application.put_env(:nous, :web_fetch_max_bytes, 64)

      assert %{success: false, error: error} =
               WebFetch.fetch_page(RunContext.new(%{}), %{"url" => url(bypass, "/big")})

      assert error =~ "exceeded the 64 byte limit"
    end

    test "a max_bytes arg may lower the ceiling", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/big", &oversized/1)

      assert %{success: false, error: error} =
               WebFetch.fetch_page(RunContext.new(%{}), %{
                 "url" => url(bypass, "/big"),
                 "max_bytes" => 64
               })

      assert error =~ "exceeded the 64 byte limit"
    end

    test "a max_bytes arg cannot raise it above the host ceiling", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/big", &oversized/1)
      ctx = RunContext.new(%{web_fetch_max_bytes: 64})

      assert %{success: false, error: error} =
               WebFetch.fetch_page(ctx, %{
                 "url" => url(bypass, "/big"),
                 "max_bytes" => 10_000_000
               })

      assert error =~ "exceeded the 64 byte limit"
    end

    test "a junk max_bytes arg falls back to the ceiling", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/page", &html/1)

      assert %{success: true, title: "Test Page"} =
               WebFetch.fetch_page(RunContext.new(%{}), %{
                 "url" => url(bypass, "/page"),
                 "max_bytes" => "not a number"
               })
    end
  end

  describe "content-type allowlist" do
    test "rejects a non-HTML content-type before parsing", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/doc.pdf", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.resp(200, "%PDF-1.7 binary junk")
      end)

      assert {:error, reason} = WebFetch.do_fetch(url(bypass, "/doc.pdf"))
      assert reason =~ "Unsupported content-type"
      assert reason =~ "application/pdf"
    end

    test "fails closed when the header is absent", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/mystery", fn conn ->
        conn
        |> Plug.Conn.delete_resp_header("content-type")
        |> Plug.Conn.resp(200, @html)
      end)

      assert {:error, reason} = WebFetch.do_fetch(url(bypass, "/mystery"))
      assert reason =~ "no content-type header"
    end

    test "accepts application/xhtml+xml", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/page", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xhtml+xml")
        |> Plug.Conn.resp(200, @html)
      end)

      assert {:ok, %{title: "Test Page"}} = WebFetch.do_fetch(url(bypass, "/page"))
    end
  end

  describe "fetch_page/2 envelope" do
    test "wraps a successful fetch", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/page", &html/1)

      assert %{success: true, title: "Test Page", content: "Hello world"} =
               WebFetch.fetch_page(RunContext.new(%{}), %{"url" => url(bypass, "/page")})
    end

    test "wraps a failure with the offending url", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/gone", &Plug.Conn.resp(&1, 404, ""))
      target = url(bypass, "/gone")

      assert %{success: false, error: "HTTP 404", url: ^target} =
               WebFetch.fetch_page(RunContext.new(%{}), %{"url" => target})
    end

    test "requires a url" do
      assert %{success: false, error: "URL is required"} =
               WebFetch.fetch_page(RunContext.new(%{}), %{})
    end

    test "tolerates a context without deps", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/page", &html/1)

      assert %{success: true} = WebFetch.fetch_page(nil, %{"url" => url(bypass, "/page")})
    end
  end
end
