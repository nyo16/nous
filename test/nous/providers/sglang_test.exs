defmodule Nous.Providers.SGLangTest do
  # async: false — manipulates the SGLANG_BASE_URL env var.
  use ExUnit.Case, async: false

  alias Nous.Providers.SGLang

  setup do
    prev = System.get_env("SGLANG_BASE_URL")
    on_exit(fn -> restore("SGLANG_BASE_URL", prev) end)

    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}/v1"}
  end

  defp restore(k, nil), do: System.delete_env(k)
  defp restore(k, v), do: System.put_env(k, v)

  describe "macro-injected metadata" do
    test "exposes provider_id, default_base_url, and default_env_key" do
      assert SGLang.provider_id() == :sglang
      assert SGLang.default_base_url() == "http://localhost:30000/v1"
      assert SGLang.default_env_key() == "SGLANG_API_KEY"
    end
  end

  describe "chat/2" do
    test "POSTs to <base_url>/chat/completions with JSON body", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"id": "x", "choices": []}))
      end)

      params = %{"model" => "meta-llama/Llama-3-8B", "messages" => []}
      assert {:ok, %{"id" => "x"}} = SGLang.chat(params, base_url: base)
    end
  end

  describe "chat_stream/2" do
    test "consumes SSE and emits SGLang `reasoning_content` field through normalizer", %{
      bypass: bypass,
      base: base
    } do
      # SGLang emits `reasoning_content` (different key from vLLM's `reasoning`).
      # The OpenAI stream normalizer maps this to a thinking_delta in higher-
      # level consumers; here we just assert the raw stream carries it
      # through unmolested.
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        body = """
        data: {"choices":[{"delta":{"reasoning_content":"step 1"}}]}

        data: {"choices":[{"delta":{"content":"answer"}}]}

        data: [DONE]

        """

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.resp(200, body)
      end)

      params = %{"model" => "m", "messages" => []}
      assert {:ok, stream} = SGLang.chat_stream(params, base_url: base)
      events = Enum.to_list(stream)

      assert [
               %{"choices" => [%{"delta" => %{"reasoning_content" => "step 1"}}]},
               %{"choices" => [%{"delta" => %{"content" => "answer"}}]},
               {:stream_done, "stop"}
             ] = events
    end
  end

  describe "base_url precedence" do
    test "opts wins over env var", %{bypass: bypass, base: base} do
      System.put_env("SGLANG_BASE_URL", "http://127.0.0.1:9/decoy/v1")

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = SGLang.chat(%{"model" => "m", "messages" => []}, base_url: base)
    end

    test "env var wins over default", %{bypass: bypass, base: base} do
      System.put_env("SGLANG_BASE_URL", base)

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, _} = SGLang.chat(%{"model" => "m", "messages" => []})
    end

    test "rejects non-http schemes via UrlGuard" do
      assert_raise ArgumentError, ~r/failed validation/, fn ->
        SGLang.chat(%{"model" => "m", "messages" => []}, base_url: "file:///etc/passwd")
      end
    end
  end
end
