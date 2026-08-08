defmodule Nous.HTTP.BackendTest do
  # Async-safe: each test gets its own Bypass instance.
  use ExUnit.Case, async: true

  # Run the same contract against every backend so a future custom backend
  # gets the same coverage just by adding a row here.
  @backends [
    {Nous.HTTP.Backend.Req, "Req"},
    {Nous.HTTP.Backend.Hackney, "Hackney"}
  ]

  for {backend, name} <- @backends do
    describe "#{name} backend (#{inspect(backend)})" do
      @backend backend

      setup do
        bypass = Bypass.open()
        {:ok, bypass: bypass, url: "http://localhost:#{bypass.port}/v1/test"}
      end

      test "decodes 2xx JSON responses", %{bypass: bypass, url: url} do
        Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert {:ok, %{"hello" => "world"}} = JSON.decode(body)

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(200, ~s({"ok": true, "n": 42}))
        end)

        assert {:ok, %{"ok" => true, "n" => 42}} =
                 @backend.post(url, %{"hello" => "world"}, [], [])
      end

      test "returns 4xx as {:error, %{status, body}}", %{bypass: bypass, url: url} do
        Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(400, ~s({"error": "bad request"}))
        end)

        assert {:error, %{status: 400, body: body}} = @backend.post(url, %{"x" => 1}, [], [])
        # Body may be decoded JSON (Hackney) or raw map via Req's auto-decode
        assert body == %{"error" => "bad request"} or body == ~s({"error": "bad request"})
      end

      test "returns 5xx as {:error, %{status, body}}", %{bypass: bypass, url: url} do
        Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
          Plug.Conn.resp(conn, 503, "service unavailable")
        end)

        assert {:error, %{status: 503}} = @backend.post(url, %{"x" => 1}, [], [])
      end

      test ":timeout is enforced, not just accepted" do
        # A socket that listens and never accepts: the kernel completes the TCP
        # handshake from the backlog, the request goes out, and nothing ever
        # answers. The receive timeout is then the only thing that can end the
        # call — a backend that drops the opt waits out its 180s default and
        # fails on ExUnit's budget instead of passing quietly. The previous
        # version of this test asserted `{:ok, _}` against a normal response,
        # which held whether or not the option was wired to anything.
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen)
        on_exit(fn -> :gen_tcp.close(listen) end)

        started = System.monotonic_time(:millisecond)

        assert {:error, _} =
                 @backend.post("http://127.0.0.1:#{port}/v1/test", %{}, [], timeout: 200)

        assert System.monotonic_time(:millisecond) - started < 5_000
      end

      test "returns transport error on connection refused", %{bypass: bypass, url: url} do
        Bypass.down(bypass)
        assert {:error, _} = @backend.post(url, %{"x" => 1}, [], [])
      end

      test "rejects malformed args via guard with ArgumentError" do
        # This goes through the dispatcher rather than backend directly — the
        # backend's `when` guards would otherwise raise FunctionClauseError.
        assert {:error, %ArgumentError{}} =
                 Nous.Providers.HTTP.post("http://x", "not a map", [], backend: @backend)
      end

      test "surfaces response headers in error tuple (e.g. Retry-After)",
           %{bypass: bypass, url: url} do
        Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "42")
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(429, ~s({"error":{"message":"rate limited"}}))
        end)

        assert {:error, %{status: 429, headers: headers}} =
                 @backend.post(url, %{}, [], [])

        assert is_list(headers)

        retry_after =
          Enum.find_value(headers, fn {k, v} ->
            if String.downcase(to_string(k)) == "retry-after", do: to_string(v)
          end)

        assert retry_after == "42"

        # Must round-trip through Nous.Errors.RetryInfo unchanged.
        assert Nous.Errors.RetryInfo.parse(%{status: 429, headers: headers}) == 42_000
      end

      test "extracts Vertex/Gemini RetryInfo from error body", %{bypass: bypass, url: url} do
        body =
          ~s({"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[) <>
            ~s({"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"7s"}]}})

        Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(429, body)
        end)

        assert {:error, error} = @backend.post(url, %{}, [], [])
        assert Nous.Errors.RetryInfo.parse(error) == 7_000
      end

      test "passes custom headers through", %{bypass: bypass, url: url} do
        Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
          assert ["Bearer test-token"] = Plug.Conn.get_req_header(conn, "authorization")
          assert ["custom-value"] = Plug.Conn.get_req_header(conn, "x-custom")
          Plug.Conn.resp(conn, 200, "{}")
        end)

        headers = [
          {"authorization", "Bearer test-token"},
          {"x-custom", "custom-value"}
        ]

        assert {:ok, _} = @backend.post(url, %{}, headers, [])
      end
    end
  end

  # Only the Hackney backend implements a call-level connect timeout. The Req
  # backend deliberately does not — see `lib/nous/http/backend/req.ex:26-29`:
  # Req rejects `:connect_options` alongside a named `:finch` pool, so connect
  # timeouts are pool-level there. A shared "the opt does not crash" test would
  # report as coverage for a contract Req does not have, so there is no Req
  # counterpart to this one.
  describe "Hackney backend :connect_timeout" do
    test "is enforced against an unroutable address" do
      # TEST-NET-1 (RFC 5737) is reserved and never a real host, so the connect
      # attempt hangs until the option's deadline. Hackney's default is 30s, so
      # dropping the opt blows the bound below. (A network that answers with an
      # immediate ICMP unreachable makes this pass trivially rather than
      # falsely — it can never go green on a backend that ignores the opt while
      # the address blackholes.)
      started = System.monotonic_time(:millisecond)

      assert {:error, _} =
               Nous.HTTP.Backend.Hackney.post("http://192.0.2.1:81/v1/test", %{}, [],
                 connect_timeout: 200
               )

      assert System.monotonic_time(:millisecond) - started < 5_000
    end
  end
end
