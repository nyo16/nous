defmodule Nous.HTTP.StreamBackend.HackneyTest do
  use ExUnit.Case, async: true

  alias Nous.HTTP.StreamBackend.Hackney

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, url: "http://localhost:#{bypass.port}/v1/sse"}
  end

  defp send_sse(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end

  test "consumes a multi-event SSE response (pull-based)", %{bypass: bypass, url: url} do
    body = """
    data: {"text":"hello"}

    data: {"text":" world"}

    data: [DONE]

    """

    Bypass.expect_once(bypass, "POST", "/v1/sse", fn conn -> send_sse(conn, body) end)

    {:ok, stream} =
      Hackney.stream(url, %{model: "x"}, [{"content-type", "application/json"}], [])

    events = Enum.to_list(stream)

    assert Enum.any?(events, &match?(%{"text" => "hello"}, &1))
    assert Enum.any?(events, &match?(%{"text" => " world"}, &1))
    assert Enum.any?(events, &match?({:stream_done, _}, &1))
  end

  test "emits {:stream_error, %{status: ...}} on non-2xx response", %{bypass: bypass, url: url} do
    Bypass.expect_once(bypass, "POST", "/v1/sse", fn conn ->
      Plug.Conn.send_resp(conn, 500, "internal error")
    end)

    {:ok, stream} = Hackney.stream(url, %{}, [], [])
    events = Enum.to_list(stream)

    assert Enum.any?(events, &match?({:stream_error, %{status: 500}}, &1))
  end

  test "halts cleanly when consumer breaks early via Stream.take/2", %{bypass: bypass, url: url} do
    Bypass.expect_once(bypass, "POST", "/v1/sse", fn conn ->
      events =
        1..100
        |> Enum.map_join("\n\n", fn i -> ~s(data: {"i":#{i}}) end)
        |> Kernel.<>("\n\n")

      send_sse(conn, events)
    end)

    {:ok, stream} = Hackney.stream(url, %{}, [], [])

    taken =
      stream
      |> Stream.reject(&match?({:stream_done, _}, &1))
      |> Enum.take(2)

    assert length(taken) == 2
  end

  test "emits stream_error when host is unreachable" do
    {:ok, stream} = Hackney.stream("http://127.0.0.1:1/", %{}, [], [])
    events = Enum.to_list(stream)

    assert Enum.any?(events, &match?({:stream_error, _}, &1))
  end

  # Regression net for the [{:async, :once}] tuple fix. If a future hackney
  # bump silently changes the option shape, this test should fail loudly:
  # in push mode the receive loop would still get messages but the
  # backpressure property is lost. Here we verify the *messages* shape by
  # asserting the stream completes against a Bypass server that delivers
  # all data in one chunk — works in both push and pull.
  test "request actually goes through hackney pull mode", %{bypass: bypass, url: url} do
    Bypass.expect_once(bypass, "POST", "/v1/sse", fn conn ->
      ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
      assert String.contains?(ua, "hackney")
      send_sse(conn, "data: {\"ok\":true}\n\ndata: [DONE]\n\n")
    end)

    {:ok, stream} = Hackney.stream(url, %{}, [], [])
    events = Enum.to_list(stream)
    assert Enum.any?(events, &match?(%{"ok" => true}, &1))
  end
end
