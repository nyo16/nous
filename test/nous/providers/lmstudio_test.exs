defmodule Nous.Providers.LMStudioTest do
  # async: false — manipulates the LMSTUDIO_BASE_URL env var.
  use ExUnit.Case, async: false

  alias Nous.Providers.LMStudio

  setup do
    prev = System.get_env("LMSTUDIO_BASE_URL")
    on_exit(fn -> restore("LMSTUDIO_BASE_URL", prev) end)

    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}/v1"}
  end

  defp restore(k, nil), do: System.delete_env(k)
  defp restore(k, v), do: System.put_env(k, v)

  describe "macro-injected metadata" do
    test "exposes provider_id, default_base_url, and default_env_key" do
      assert LMStudio.provider_id() == :lmstudio
      assert LMStudio.default_base_url() == "http://localhost:1234/v1"
      assert LMStudio.default_env_key() == "LMSTUDIO_API_KEY"
    end
  end

  describe "chat/2" do
    test "POSTs to <base_url>/chat/completions with JSON body and content-type", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert {:ok, %{"model" => "test-model", "messages" => [_]}} = JSON.decode(raw)

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"id": "x", "choices": []}))
      end)

      params = %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "hi"}]}
      assert {:ok, %{"id" => "x"}} = LMStudio.chat(params, base_url: base)
    end
  end

  describe "chat_stream/2" do
    test "consumes a Bypass-served SSE stream", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        body = """
        data: {"choices":[{"delta":{"content":"hello"}}]}

        data: {"choices":[{"delta":{"content":" world"}}]}

        data: [DONE]

        """

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.resp(200, body)
      end)

      params = %{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}
      assert {:ok, stream} = LMStudio.chat_stream(params, base_url: base)
      events = Enum.to_list(stream)

      assert [
               %{"choices" => [%{"delta" => %{"content" => "hello"}}]},
               %{"choices" => [%{"delta" => %{"content" => " world"}}]},
               {:stream_done, "stop"}
             ] = events
    end
  end

  describe "base_url precedence" do
    test "opts wins over env var", %{bypass: bypass, base: base} do
      System.put_env("LMSTUDIO_BASE_URL", "http://127.0.0.1:9/decoy/v1")

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = LMStudio.chat(%{"model" => "m", "messages" => []}, base_url: base)
    end

    test "env var wins over default", %{bypass: bypass, base: base} do
      System.put_env("LMSTUDIO_BASE_URL", base)

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = LMStudio.chat(%{"model" => "m", "messages" => []})
    end

    test "rejects non-http schemes via UrlGuard" do
      assert_raise ArgumentError, ~r/failed validation/, fn ->
        LMStudio.chat(%{"model" => "m", "messages" => []}, base_url: "file:///etc/passwd")
      end
    end
  end
end
