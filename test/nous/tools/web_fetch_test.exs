defmodule Nous.Tools.WebFetchTest do
  # Not async: the UrlGuard escape hatch and the :web_fetch_max_bytes ceiling
  # are read from the global application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  describe "connection pooling" do
    test "distinct hostnames leave no pool behind", %{bypass: bypass} do
      hosts = for i <- 1..5, do: "nous-pool-probe-#{i}"
      stub_hosts(hosts)
      Bypass.expect(bypass, "GET", "/page", &html/1)

      # brave_search and friends also use Req's :connect_options, so the
      # baseline is whatever is already parked there, not zero.
      before = length(DynamicSupervisor.which_children(Req.FinchSupervisor))

      for host <- hosts do
        assert {:ok, %{title: "Test Page"}} =
                 WebFetch.do_fetch("http://#{host}:#{bypass.port}/page")
      end

      # Req's :connect_options path starts a Finch supervision tree keyed by a
      # hash of those options — which carry the hostname — and never stops it.
      # Five model-chosen hostnames used to mean five permanent trees (and five
      # permanent atoms). web_fetch owns its pool now, so this stays flat.
      assert length(DynamicSupervisor.which_children(Req.FinchSupervisor)) == before
      assert live_pinned_pools() == []
    end

    test "every hop of a redirect chain gives its slot back", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/start", &redirect(&1, "/middle"))
      Bypass.expect_once(bypass, "GET", "/middle", &redirect(&1, "/final"))
      Bypass.expect_once(bypass, "GET", "/final", &html/1)

      assert {:ok, %{title: "Test Page"}} = WebFetch.do_fetch(url(bypass, "/start"))
      assert live_pinned_pools() == []
    end

    test "a failed fetch gives its slot back", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/gone", &Plug.Conn.resp(&1, 404, ""))

      assert {:error, "HTTP 404"} = WebFetch.do_fetch(url(bypass, "/gone"))
      assert live_pinned_pools() == []
    end

    test "concurrent fetches take distinct slots and return them all", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/page", &html/1)

      results =
        1..8
        |> Task.async_stream(fn _ -> WebFetch.do_fetch(url(bypass, "/page")) end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %{title: "Test Page"}}, &1))
      assert live_pinned_pools() == []
    end

    # claim_pinned_pool/2's third clause. Finch.start_link/1 is a
    # Supervisor.start_link/3 underneath, so besides {:already_started, _} —
    # the contention answer, produced when the *supervisor* name is taken — it
    # can answer {:error, {:shutdown, {:failed_to_start_child, ...}}} when one
    # of Finch's own children refuses to start. Occupying the slot's registry
    # name (Finch names its duplicate-key Registry after the instance itself,
    # and the supervisor "<instance>.Supervisor") produces exactly that shape.
    #
    # The failing supervisor is linked, so a caller that does not trap exits is
    # killed by the signal before it can act on the return value; a host that
    # runs its agent from a trapping GenServer sees the tuple, and that is the
    # process this clause protects. Before it existed the tuple fell off the
    # case as a CaseClauseError, which fetch_url/2's rescue laundered into
    # "Request error: no case clause matching..." with the real reason gone.
    test "an unexpected pool start failure is reported with its reason and logged", %{
      bypass: bypass
    } do
      Process.flag(:trap_exit, true)

      slot = Module.concat([WebFetch, Finch, "Slot0"])
      {:ok, blocker} = Agent.start(fn -> :ok end, name: slot)
      on_exit(fn -> if Process.alive?(blocker), do: Agent.stop(blocker) end)

      log =
        capture_log(fn ->
          assert {:error, reason} = WebFetch.do_fetch(url(bypass, "/page"))

          # The real reason survives, rather than being rewritten as a rescue
          # of a CaseClauseError or mislabelled as slot exhaustion.
          assert reason =~ "Could not start a pinned connection pool"
          assert reason =~ "failed_to_start_child"
          refute reason =~ "Too many concurrent web fetches"
          refute reason =~ "no case clause"
        end)

      assert log =~ "pinned connection pool"
      assert log =~ "Slot0"
    end
  end

  describe "retry policy" do
    test "a transient failure is fetched exactly once", %{bypass: bypass} do
      attempts = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/flaky", fn conn ->
        :counters.add(attempts, 1, 1)
        Plug.Conn.resp(conn, 503, "")
      end)

      assert {:error, "HTTP 503"} = WebFetch.do_fetch(url(bypass, "/flaky"))

      # Req's default `retry: :safe_transient` would make this 4 — four full
      # body transfers and four DNS resolutions against a model-supplied URL,
      # only the first of which the SSRF guard validated.
      assert :counters.get(attempts, 1) == 1
    end
  end

  # The nil-pin clause is unreachable from do_fetch/3 by construction —
  # UrlGuard only returns a nil pin under `allow_private_hosts: true`, which
  # web_fetch never passes — and that is exactly how the one branch of this
  # SSRF defence with no test stayed untested through two audits while the
  # battery around it grew to 22 cases. pin_connection/2 is `@doc false`
  # public so the branch has a seam.
  describe "pin_connection/2 fail-closed" do
    test "refuses to build a request when host validation produced no pinned IP" do
      assert {:error, reason} = WebFetch.pin_connection(URI.parse("https://example.com/x"), nil)
      assert reason =~ "pinned IP"
      assert reason =~ "host validation was skipped"
    end

    test "an IPv4 pin replaces the host and keeps the hostname for TLS" do
      # Negative control for the clause above: a blanket
      # `pin_connection(_, _), do: {:error, _}` would satisfy the fail-closed
      # test and break every fetch, and nothing else here calls this directly.
      assert {:ok, {"https://93.184.216.34:8443/a/b?q=1", "example.com"}} =
               WebFetch.pin_connection(
                 URI.parse("https://example.com:8443/a/b?q=1"),
                 {93, 184, 216, 34}
               )
    end

    test "an IPv6 pin is bracketed in the authority" do
      assert {:ok, {"https://[2606:4700::1111]:443/x", "example.com"}} =
               WebFetch.pin_connection(
                 URI.parse("https://example.com/x"),
                 {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}
               )
    end
  end

  describe "the request path still routes through the DNS pin" do
    test "the connection targets the pinned IP while Host carries the hostname",
         %{bypass: bypass} do
      # The pin is the only part of this SSRF battery that closes the DNS-
      # rebinding window, and it had three tests exercising it in ISOLATION and
      # none that would notice if `do_get/3` stopped calling it — a control with
      # excellent-looking coverage, not wired to the thing it guards.
      #
      # `[:finch, :connect, :start]`'s `:host` is the address Mint is about to
      # open a socket to, so this is the transport target itself rather than a
      # helper's return value. (Finch skips the event on a reused connection;
      # web_fetch starts a fresh instance per fetch, so it always fires.)
      test_pid = self()
      stub_hosts(["pinned.test"])

      handler_id = {__MODULE__, :connect_probe, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:finch, :connect, :start],
        fn _event, _measurements, meta, _config ->
          send(test_pid, {:connect_to, to_string(meta.host), meta.port})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Bypass.expect_once(bypass, "GET", "/page", fn conn ->
        # ...and the request must still present the HOSTNAME. Mint's `:hostname`
        # option drives the Host header, SNI and certificate verification off one
        # value; the Host header is the half observable over plaintext Bypass.
        # Connecting to a bare IP and announcing that IP is how a pinned fetch
        # breaks vhosts and TLS verification at the same time.
        send(test_pid, {:host_header, conn.host})
        html(conn)
      end)

      assert {:ok, %{title: "Test Page"}} =
               WebFetch.do_fetch("http://pinned.test:#{bypass.port}/page")

      assert_receive {:connect_to, "127.0.0.1", connected_port}
      assert connected_port == bypass.port
      assert_receive {:host_header, "pinned.test"}
    end
  end

  # Each pinned Finch instance registers its supervisor, registries and pool
  # manager under the slot name, so "no process left with that prefix" is the
  # reclamation assertion. No hardcoded slot count, no atoms minted here.
  defp live_pinned_pools do
    Enum.filter(Process.registered(), fn name ->
      String.starts_with?(Atom.to_string(name), "Elixir.Nous.Tools.WebFetch.Finch.")
    end)
  end

  # The pool is keyed by hostname (web_fetch connects to the pinned IP and
  # hands Mint the hostname separately), so exercising the leak needs several
  # names — all resolving to the 127.0.0.1 Bypass listens on. `:inet_db`'s
  # hosts table is the seam; `:file` has to precede `:native` in the lookup
  # order for it to be consulted at all.
  defp stub_hosts(hosts) do
    previous_lookup = :inet_db.res_option(:lookup)

    # `del_host/1` drops EVERY name registered for the address, not just the ones
    # added here, and `:inet_db` exposes no per-name delete. On a host whose
    # resolver already carries 127.0.0.1 entries, the teardown used to delete
    # them for the rest of the run — a test that quietly reconfigures name
    # resolution for everything after it. Snapshot and put them back. The ETS
    # table is where `add_host/2` writes; there is no public read for it.
    previous_names =
      case :ets.lookup(:inet_hosts_byaddr, {:inet, {127, 0, 0, 1}}) do
        [{_key, names}] -> names
        _ -> []
      end

    :inet_db.set_lookup([:file, :native])
    :inet_db.add_host({127, 0, 0, 1}, Enum.map(hosts, &String.to_charlist/1))

    on_exit(fn ->
      :inet_db.del_host({127, 0, 0, 1})
      if previous_names != [], do: :inet_db.add_host({127, 0, 0, 1}, previous_names)
      :inet_db.set_lookup(previous_lookup)
    end)
  end
end
