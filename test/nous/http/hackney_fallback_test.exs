defmodule Nous.HTTP.HackneyFallbackTest do
  # async: false — this module makes the `:hackney` module genuinely
  # unloadable for its duration, which is VM-global, and it mutates the
  # NOUS_HTTP_BACKEND* env vars and :nous app config.
  use ExUnit.Case, async: false

  alias Nous.Providers.HTTP

  setup do
    prev_backend_env = System.get_env("NOUS_HTTP_BACKEND")
    prev_stream_env = System.get_env("NOUS_HTTP_STREAM_BACKEND")
    prev_backend_app = Application.fetch_env(:nous, :http_backend)
    prev_stream_app = Application.fetch_env(:nous, :http_stream_backend)

    # `Code.ensure_loaded?(:hackney)` is the guard under test, and hackney is a
    # dev/test dep of nous itself — so it is always loadable here, and the
    # missing-dep path an app *without* `{:hackney, "~> 4.0"}` hits is
    # unreachable unless we take the module away. Dropping its ebin from the
    # code path and purging the module is the only honest way to reproduce it:
    # stubbing the guard would test the stub.
    ebin = :code.lib_dir(:hackney) ++ ~c"/ebin"
    :code.del_path(ebin)
    :code.purge(:hackney)
    :code.delete(:hackney)
    :code.purge(:hackney)

    refute Code.ensure_loaded?(:hackney),
           "precondition failed: :hackney is still loadable, the tests below prove nothing"

    on_exit(fn ->
      :code.add_pathz(ebin)
      Code.ensure_loaded?(:hackney)
      restore_env("NOUS_HTTP_BACKEND", prev_backend_env)
      restore_env("NOUS_HTTP_STREAM_BACKEND", prev_stream_env)
      restore_app(:http_backend, prev_backend_app)
      restore_app(:http_stream_backend, prev_stream_app)
    end)

    System.delete_env("NOUS_HTTP_BACKEND")
    System.delete_env("NOUS_HTTP_STREAM_BACKEND")
    Application.delete_env(:nous, :http_backend)
    Application.delete_env(:nous, :http_stream_backend)

    bypass = Bypass.open()
    %{bypass: bypass, url: "http://localhost:#{bypass.port}/v1/x"}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app(key, :error), do: Application.delete_env(:nous, key)
  defp restore_app(key, {:ok, value}), do: Application.put_env(:nous, key, value)

  # Bypass fails the test if the request never arrives, which is exactly the
  # pre-fix symptom: the hackney backend blew up inside the node and nothing
  # went out. The user-agent pins *which* backend served it.
  defp expect_req_post(bypass) do
    Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
      assert_req_user_agent(conn)
      Plug.Conn.resp(conn, 200, "{}")
    end)
  end

  defp expect_req_stream(bypass) do
    Bypass.expect_once(bypass, "POST", "/v1/x", fn conn ->
      assert_req_user_agent(conn)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: {\"text\":\"hi\"}\n\ndata: [DONE]\n\n")
    end)
  end

  defp assert_req_user_agent(conn) do
    ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")

    assert String.contains?(ua, "req/") or String.contains?(ua, "Req/"),
           "expected the Req backend to serve this request, got user-agent #{inspect(ua)}"
  end

  describe "post/4 with :hackney unavailable" do
    test "the per-call :backend opt degrades instead of raising", %{bypass: bypass, url: url} do
      expect_req_post(bypass)

      assert {:ok, _} = HTTP.post(url, %{}, [], backend: Nous.HTTP.Backend.Hackney)
    end

    test "app config degrades instead of raising", %{bypass: bypass, url: url} do
      Application.put_env(:nous, :http_backend, Nous.HTTP.Backend.Hackney)
      expect_req_post(bypass)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end

    test "the per-call opt degrades even when app config also names hackney", %{
      bypass: bypass,
      url: url
    } do
      # The env-var route used to fall back *to app config* — which can itself
      # be hackney. Degrading has to terminate at the shipped default.
      Application.put_env(:nous, :http_backend, Nous.HTTP.Backend.Hackney)
      expect_req_post(bypass)

      assert {:ok, _} = HTTP.post(url, %{}, [], backend: Nous.HTTP.Backend.Hackney)
    end

    test "the env-var route still degrades", %{bypass: bypass, url: url} do
      System.put_env("NOUS_HTTP_BACKEND", "hackney")
      expect_req_post(bypass)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end

    test "the env var degrades past an app config that also names hackney", %{
      bypass: bypass,
      url: url
    } do
      System.put_env("NOUS_HTTP_BACKEND", "hackney")
      Application.put_env(:nous, :http_backend, Nous.HTTP.Backend.Hackney)
      expect_req_post(bypass)

      assert {:ok, _} = HTTP.post(url, %{}, [], [])
    end
  end

  describe "stream/4 with :hackney unavailable" do
    test "the per-call :stream_backend opt degrades instead of raising", %{
      bypass: bypass,
      url: url
    } do
      expect_req_stream(bypass)

      assert {:ok, stream} =
               HTTP.stream(url, %{}, [], stream_backend: Nous.HTTP.StreamBackend.Hackney)

      assert %{"text" => "hi"} in Enum.to_list(stream)
    end

    test "app config degrades instead of raising", %{bypass: bypass, url: url} do
      Application.put_env(:nous, :http_stream_backend, Nous.HTTP.StreamBackend.Hackney)
      expect_req_stream(bypass)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      assert %{"text" => "hi"} in Enum.to_list(stream)
    end

    test "the env-var route still degrades", %{bypass: bypass, url: url} do
      System.put_env("NOUS_HTTP_STREAM_BACKEND", "hackney")
      expect_req_stream(bypass)

      assert {:ok, stream} = HTTP.stream(url, %{}, [], [])
      assert %{"text" => "hi"} in Enum.to_list(stream)
    end
  end
end
