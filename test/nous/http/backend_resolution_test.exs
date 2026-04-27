defmodule Nous.HTTP.BackendResolutionTest do
  # async: false — these tests mutate the NOUS_HTTP_BACKEND env var and
  # :nous app config, which are global. Keeping them in a single
  # serialized module prevents cross-test interference without forcing
  # the rest of the suite to go sync.
  use ExUnit.Case, async: false

  alias Nous.HTTP.Backend.{Hackney, Req}
  alias Nous.Providers.HTTP

  # A custom backend installed only inside this test module to exercise the
  # `Elixir.<Name>` env-var path without polluting the rest of the codebase.
  defmodule CustomBackend do
    @behaviour Nous.HTTP.Backend
    @impl true
    def post(_url, _body, _headers, _opts), do: {:ok, %{"who" => "custom"}}
  end

  setup do
    prev_env = System.get_env("NOUS_HTTP_BACKEND")
    prev_app = Application.get_env(:nous, :http_backend)

    on_exit(fn ->
      restore_env("NOUS_HTTP_BACKEND", prev_env)

      case prev_app do
        nil -> Application.delete_env(:nous, :http_backend)
        v -> Application.put_env(:nous, :http_backend, v)
      end
    end)

    bypass = Bypass.open()
    %{bypass: bypass, url: "http://localhost:#{bypass.port}/v1/x"}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  describe "precedence" do
    test "per-call :backend opt wins over env var, app config, and default", %{
      bypass: bypass,
      url: url
    } do
      System.put_env("NOUS_HTTP_BACKEND", "req")
      Application.put_env(:nous, :http_backend, Req)

      Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"who": "asked"}))
      end)

      # Override with the custom backend at call time. The bypass plug must
      # NOT be hit; the custom backend short-circuits and returns directly.
      assert {:ok, %{"who" => "custom"}} =
               HTTP.post(url, %{}, [], backend: CustomBackend)

      Bypass.pass(bypass)
    end

    test "env var wins over app config", %{bypass: bypass, url: url} do
      # App config says Hackney, env var says req — env var should win.
      Application.put_env(:nous, :http_backend, Hackney)
      System.put_env("NOUS_HTTP_BACKEND", "req")

      Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
        # Req sets a distinctive user-agent prefix; hackney sends "hackney/...".
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "req/") or String.contains?(ua, "Req/")
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end

    test "app config wins over default when env var is unset", %{bypass: bypass, url: url} do
      System.delete_env("NOUS_HTTP_BACKEND")
      Application.put_env(:nous, :http_backend, Hackney)

      Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "hackney")
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end

    test "default is Req when nothing is configured", %{bypass: bypass, url: url} do
      System.delete_env("NOUS_HTTP_BACKEND")
      Application.delete_env(:nous, :http_backend)

      Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "req/") or String.contains?(ua, "Req/")
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end
  end

  describe "env var values" do
    test ~s|"req" resolves to Nous.HTTP.Backend.Req|, %{bypass: bypass, url: url} do
      Application.put_env(:nous, :http_backend, Hackney)
      System.put_env("NOUS_HTTP_BACKEND", "req")

      Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "req/") or String.contains?(ua, "Req/")
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end

    test ~s|"hackney" resolves to Nous.HTTP.Backend.Hackney|, %{bypass: bypass, url: url} do
      Application.put_env(:nous, :http_backend, Req)
      System.put_env("NOUS_HTTP_BACKEND", "hackney")

      Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "hackney")
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end

    test "fully-qualified custom module name resolves via String.to_existing_atom", %{
      bypass: bypass,
      url: url
    } do
      # Force the atom to exist by referencing the module first (it would
      # already exist anyway since this file compiles it, but the explicit
      # reference documents the contract).
      _ = CustomBackend
      System.put_env("NOUS_HTTP_BACKEND", "Nous.HTTP.BackendResolutionTest.CustomBackend")

      assert {:ok, %{"who" => "custom"}} = HTTP.post(url, %{}, [], [])

      # Bypass was opened in setup but not expected — pass it.
      Bypass.pass(bypass)
    end

    test "unknown env var value falls back to app config (no atom DoS)", %{
      bypass: bypass,
      url: url
    } do
      # The string "Definitely.Not.A.Real.Module.#{rand}" must NOT crash via
      # `String.to_atom/1`. The resolver uses `String.to_existing_atom/1`
      # with rescue, then falls back to app config / default.
      Application.put_env(:nous, :http_backend, Hackney)

      System.put_env(
        "NOUS_HTTP_BACKEND",
        "Definitely.Not.A.Real.Module.#{System.unique_integer()}"
      )

      Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "hackney")
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end

    test "module-name without :post/4 falls back to app config", %{bypass: bypass, url: url} do
      # Atom exists but the module is not a backend.
      Application.put_env(:nous, :http_backend, Hackney)
      System.put_env("NOUS_HTTP_BACKEND", "Enum")

      Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "hackney")
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end
  end
end
