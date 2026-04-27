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

      test "accepts :timeout opt without crashing", %{bypass: bypass, url: url} do
        # Pure passthrough — Bypass-with-sleep timeout testing is racy
        # (the plug crashes when the client closes mid-sleep, taking the
        # Bypass instance with it). The actual timeout enforcement is the
        # underlying lib's responsibility; here we just verify the opt is
        # accepted and a normal request still succeeds.
        Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
          Plug.Conn.resp(conn, 200, "{}")
        end)

        assert {:ok, _} = @backend.post(url, %{}, [], timeout: 5_000)
      end

      test "accepts :connect_timeout opt without crashing", %{bypass: bypass, url: url} do
        # Connect-timeout passthrough: a real network test for connect-only
        # timeouts is flaky on loopback (always connects fast). We assert
        # the opt is accepted and a normal request still succeeds.
        Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
          Plug.Conn.resp(conn, 200, "{}")
        end)

        assert {:ok, _} = @backend.post(url, %{}, [], connect_timeout: 5_000)
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
end
