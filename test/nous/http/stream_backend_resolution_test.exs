defmodule Nous.HTTP.StreamBackendResolutionTest do
  # async: false — these tests mutate the NOUS_HTTP_STREAM_BACKEND env var
  # and :nous app config, which are global. Keeping them in a single
  # serialized module prevents cross-test interference.
  use ExUnit.Case, async: false

  alias Nous.HTTP.StreamBackend.{Hackney, Req}
  alias Nous.Providers.HTTP

  defmodule CustomStreamBackend do
    @behaviour Nous.HTTP.StreamBackend
    @impl true
    def stream(_url, _body, _headers, _opts) do
      {:ok, [%{"who" => "custom"}, {:stream_done, "stop"}]}
    end
  end

  setup do
    prev_env = System.get_env("NOUS_HTTP_STREAM_BACKEND")
    prev_app = Application.get_env(:nous, :http_stream_backend)

    on_exit(fn ->
      restore_env("NOUS_HTTP_STREAM_BACKEND", prev_env)

      case prev_app do
        nil -> Application.delete_env(:nous, :http_stream_backend)
        v -> Application.put_env(:nous, :http_stream_backend, v)
      end
    end)

    bypass = Bypass.open()
    %{bypass: bypass, url: "http://localhost:#{bypass.port}/v1/stream"}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  defp send_sse(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end

  defp simple_sse_body do
    """
    data: {"text":"hi"}

    data: [DONE]

    """
  end

  describe "precedence" do
    test "per-call :stream_backend opt wins over env, app config, and default", %{
      bypass: bypass,
      url: url
    } do
      System.put_env("NOUS_HTTP_STREAM_BACKEND", "req")
      Application.put_env(:nous, :http_stream_backend, Req)

      Bypass.expect_once(bypass, "POST", "/v1/stream", fn conn ->
        send_sse(conn, simple_sse_body())
      end)

      # Override with custom backend at call time. Bypass plug must NOT
      # be hit; the custom backend short-circuits.
      assert {:ok, stream} =
               HTTP.stream(url, %{}, [], stream_backend: CustomStreamBackend)

      assert Enum.to_list(stream) == [%{"who" => "custom"}, {:stream_done, "stop"}]

      Bypass.pass(bypass)
    end

    test "env var wins over app config", %{bypass: bypass, url: url} do
      Application.put_env(:nous, :http_stream_backend, Hackney)
      System.put_env("NOUS_HTTP_STREAM_BACKEND", "req")

      Bypass.expect_once(bypass, "POST", "/v1/stream", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "req/") or String.contains?(ua, "Req/")
        send_sse(conn, simple_sse_body())
      end)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      events = Enum.to_list(stream)
      assert Enum.any?(events, &match?(%{"text" => "hi"}, &1))
    end

    test "app config wins over default when env var is unset", %{bypass: bypass, url: url} do
      System.delete_env("NOUS_HTTP_STREAM_BACKEND")
      Application.put_env(:nous, :http_stream_backend, Hackney)

      Bypass.expect_once(bypass, "POST", "/v1/stream", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "hackney")
        send_sse(conn, simple_sse_body())
      end)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      events = Enum.to_list(stream)
      assert Enum.any?(events, &match?(%{"text" => "hi"}, &1))
    end

    test "default is Req when nothing is configured", %{bypass: bypass, url: url} do
      System.delete_env("NOUS_HTTP_STREAM_BACKEND")
      Application.delete_env(:nous, :http_stream_backend)

      Bypass.expect_once(bypass, "POST", "/v1/stream", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "req/") or String.contains?(ua, "Req/")
        send_sse(conn, simple_sse_body())
      end)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      events = Enum.to_list(stream)
      assert Enum.any?(events, &match?(%{"text" => "hi"}, &1))
    end
  end

  describe "env var values" do
    test ~s|"req" resolves to Nous.HTTP.StreamBackend.Req|, %{bypass: bypass, url: url} do
      Application.put_env(:nous, :http_stream_backend, Hackney)
      System.put_env("NOUS_HTTP_STREAM_BACKEND", "req")

      Bypass.expect_once(bypass, "POST", "/v1/stream", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "req/") or String.contains?(ua, "Req/")
        send_sse(conn, simple_sse_body())
      end)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      _ = Enum.to_list(stream)
    end

    test ~s|"hackney" resolves to Nous.HTTP.StreamBackend.Hackney|, %{
      bypass: bypass,
      url: url
    } do
      Application.put_env(:nous, :http_stream_backend, Req)
      System.put_env("NOUS_HTTP_STREAM_BACKEND", "hackney")

      Bypass.expect_once(bypass, "POST", "/v1/stream", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "hackney")
        send_sse(conn, simple_sse_body())
      end)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      _ = Enum.to_list(stream)
    end

    test "fully-qualified custom module name resolves via String.to_existing_atom", %{
      bypass: bypass,
      url: _url
    } do
      _ = CustomStreamBackend

      System.put_env(
        "NOUS_HTTP_STREAM_BACKEND",
        "Nous.HTTP.StreamBackendResolutionTest.CustomStreamBackend"
      )

      assert {:ok, stream} =
               HTTP.stream("http://example.invalid/", %{}, [], [])

      assert Enum.to_list(stream) == [%{"who" => "custom"}, {:stream_done, "stop"}]

      Bypass.pass(bypass)
    end

    test "unknown env var value falls back to app config (no atom DoS)", %{
      bypass: bypass,
      url: url
    } do
      Application.put_env(:nous, :http_stream_backend, Hackney)

      System.put_env(
        "NOUS_HTTP_STREAM_BACKEND",
        "Definitely.Not.A.Real.StreamBackend.#{System.unique_integer()}"
      )

      Bypass.expect_once(bypass, "POST", "/v1/stream", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "hackney")
        send_sse(conn, simple_sse_body())
      end)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      _ = Enum.to_list(stream)
    end

    test "module-name without :stream/4 falls back to app config", %{
      bypass: bypass,
      url: url
    } do
      Application.put_env(:nous, :http_stream_backend, Hackney)
      System.put_env("NOUS_HTTP_STREAM_BACKEND", "Enum")

      Bypass.expect_once(bypass, "POST", "/v1/stream", fn conn ->
        ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        assert String.contains?(ua, "hackney")
        send_sse(conn, simple_sse_body())
      end)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      _ = Enum.to_list(stream)
    end
  end
end
