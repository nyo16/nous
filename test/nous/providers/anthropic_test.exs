defmodule Nous.Providers.AnthropicTest do
  # async: true — this suite never touches the process environment. Anthropic
  # resolves its base URL from opts/app-config only (there is no
  # `ANTHROPIC_BASE_URL` lookup in `Nous.Provider.base_url/1`), and every test
  # passes `:api_key` explicitly so `ANTHROPIC_API_KEY` is never read.
  use ExUnit.Case, async: true

  alias Nous.Errors.ProviderError
  alias Nous.Message
  alias Nous.Model
  alias Nous.Providers.Anthropic
  alias Nous.Tool
  alias Nous.ToolSchema

  @api_key "sk-ant-test-key"
  @api_version "2023-06-01"

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  # Built through `ToolSchema.to_anthropic/1` rather than hand-written so a
  # regression in the conversion (e.g. emitting OpenAI's `parameters` envelope
  # instead of `input_schema`) fails here instead of passing against a fixture.
  defp weather_tool_schema do
    ToolSchema.to_anthropic(%Tool{
      name: "get_weather",
      description: "Look up the current weather for a city",
      parameters: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      },
      function: fn _args -> {:ok, "sunny"} end
    })
  end

  defp model(base) do
    %Model{
      provider: :anthropic,
      model: "claude-sonnet-4-20250514",
      base_url: base,
      api_key: @api_key,
      # Generous: the peer is a local Bypass server, so this bound exists only
      # to stop a hung test hanging forever — it is never the thing under test.
      receive_timeout: 30_000
    }
  end

  defp read_json_body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {JSON.decode!(raw), conn}
  end

  defp respond_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  defp text_response(text) do
    %{
      "id" => "msg_01",
      "model" => "claude-sonnet-4-20250514",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 3, "output_tokens" => 4}
    }
  end

  describe "macro-injected metadata" do
    test "exposes provider_id, default_base_url, and default_env_key" do
      assert Anthropic.provider_id() == :anthropic
      assert Anthropic.default_base_url() == "https://api.anthropic.com"
      assert Anthropic.default_env_key() == "ANTHROPIC_API_KEY"
    end
  end

  describe "chat/2 URL and auth" do
    test "POSTs to /v1/messages with x-api-key and anthropic-version", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/messages"

        # Anthropic authenticates with `x-api-key`, NOT `authorization: Bearer`,
        # and rejects any request without `anthropic-version`.
        assert Plug.Conn.get_req_header(conn, "x-api-key") == [@api_key]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == [@api_version]
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")

        # No beta opted in for this call.
        assert Plug.Conn.get_req_header(conn, "anthropic-beta") == []

        {body, conn} = read_json_body(conn)
        assert body["model"] == "claude-sonnet-4-20250514"
        assert body["max_tokens"] == 1024

        respond_json(conn, 200, text_response("hello"))
      end)

      params = %{
        "model" => "claude-sonnet-4-20250514",
        "max_tokens" => 1024,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      assert {:ok, %{"id" => "msg_01"}} =
               Anthropic.chat(params, base_url: base, api_key: @api_key)
    end

    test "omits x-api-key entirely when no key is configured", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        # An empty `x-api-key: ` header would be a confusing 401 from the API;
        # HTTP.api_key_header/2 drops it instead.
        assert Plug.Conn.get_req_header(conn, "x-api-key") == []
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == [@api_version]
        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, _} =
               Anthropic.chat(%{"model" => "claude", "messages" => []},
                 base_url: base,
                 api_key: ""
               )
    end

    test "enable_long_context and :beta both emit anthropic-beta headers", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        # `anthropic_beta_headers/1` emits one header per beta, but HTTP/1.1
        # field-value combining (RFC 9110 §5.3) folds repeated field lines
        # into one comma-separated value on the wire — so the module comment
        # at anthropic.ex:83-86 about each beta staying "independently
        # inspectable" does not survive the transport. What the API contract
        # actually requires is that every requested beta arrives, in order.
        betas =
          conn
          |> Plug.Conn.get_req_header("anthropic-beta")
          |> Enum.join(",")
          |> String.split(",")
          |> Enum.map(&String.trim/1)

        assert betas == [
                 "context-1m-2025-08-07",
                 "token-counting-2024-11-01",
                 "pdfs-2024-09-25"
               ]

        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, _} =
               Anthropic.chat(%{"model" => "claude", "messages" => []},
                 base_url: base,
                 api_key: @api_key,
                 enable_long_context: true,
                 beta: ["token-counting-2024-11-01", "pdfs-2024-09-25"]
               )
    end
  end

  describe "chat_stream/2" do
    test "forces stream: true in the body and consumes the SSE events", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.request_path == "/v1/messages"
        assert Plug.Conn.get_req_header(conn, "x-api-key") == [@api_key]

        {body, conn} = read_json_body(conn)
        # The caller did not ask for streaming; chat_stream/2 must set it.
        assert body["stream"] == true

        sse = """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hel"}}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}

        data: [DONE]

        """

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.resp(200, sse)
      end)

      params = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      assert {:ok, stream} = Anthropic.chat_stream(params, base_url: base, api_key: @api_key)

      texts =
        stream
        |> Enum.filter(&is_map/1)
        |> Enum.map(&get_in(&1, ["delta", "text"]))

      assert texts == ["hel", "lo"]
    end
  end

  describe "request/3 body shape" do
    test "hoists the system prompt to a top-level \"system\" key", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        # Anthropic has no "system" role in `messages`; the prompt is a
        # sibling of `messages`. (Gemini hoists it too, but into
        # `systemInstruction` — the two dialects must not be crossed.)
        assert body["system"] == "You are terse."
        refute Map.has_key?(body, "systemInstruction")

        assert body["messages"] == [%{"role" => "user", "content" => "Weather in Athens?"}]
        refute Enum.any?(body["messages"], &(&1["role"] == "system"))

        assert body["model"] == "claude-sonnet-4-20250514"
        assert body["temperature"] == 0.2
        assert body["max_tokens"] == 256

        respond_json(conn, 200, text_response("Sunny."))
      end)

      messages = [Message.system("You are terse."), Message.user("Weather in Athens?")]

      assert {:ok, %Message{role: :assistant, content: "Sunny."}} =
               Anthropic.request(model(base), messages, %{temperature: 0.2, max_tokens: 256})
    end

    test "sends tools with input_schema and no OpenAI/Gemini envelope", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        assert [tool] = body["tools"]
        assert tool["name"] == "get_weather"
        assert tool["description"] == "Look up the current weather for a city"

        # Anthropic's schema key is `input_schema`, flat on the tool object.
        assert tool["input_schema"]["type"] == "object"
        assert tool["input_schema"]["properties"] == %{"city" => %{"type" => "string"}}
        assert tool["input_schema"]["required"] == ["city"]

        # Not OpenAI's `{"type": "function", "function": {...}}` envelope,
        # not OpenAI's `parameters`, and not Gemini's `functionDeclarations`.
        refute Map.has_key?(tool, "type")
        refute Map.has_key?(tool, "function")
        refute Map.has_key?(tool, "parameters")
        refute Map.has_key?(tool, "functionDeclarations")

        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, %Message{}} =
               Anthropic.request(
                 model(base),
                 [Message.user("Weather in Athens?")],
                 %{tools: [weather_tool_schema()], max_tokens: 512}
               )
    end

    test "merges model default_settings under per-request settings", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        # default_settings supplies max_tokens; the per-request temperature
        # overrides the model default rather than being dropped.
        assert body["max_tokens"] == 4096
        assert body["temperature"] == 0.9

        respond_json(conn, 200, text_response("ok"))
      end)

      configured = %{model(base) | default_settings: %{max_tokens: 4096, temperature: 0.1}}

      assert {:ok, %Message{}} =
               Anthropic.request(configured, [Message.user("hi")], %{temperature: 0.9})
    end
  end

  describe "request_stream/3" do
    test "normalizes SSE through the Anthropic normalizer", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.request_path == "/v1/messages"

        {body, conn} = read_json_body(conn)
        assert body["stream"] == true
        assert body["system"] == "You are terse."

        sse = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hel"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

        data: [DONE]

        """

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.resp(200, sse)
      end)

      messages = [Message.system("You are terse."), Message.user("hi")]

      assert {:ok, stream} = Anthropic.request_stream(model(base), messages, %{})

      # request_stream/3 must pick Nous.StreamNormalizer.Anthropic (not the
      # OpenAI default), which unwraps content_block_delta into :text_delta.
      assert Enum.to_list(stream) == [
               {:text_delta, "hel"},
               {:text_delta, "lo"},
               {:finish, "stop"}
             ]
    end
  end

  describe "error mapping" do
    test "chat/2 surfaces a non-200 as {:error, %{status: ...}}", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        respond_json(conn, 400, %{"error" => %{"type" => "invalid_request_error"}})
      end)

      assert {:error, %{status: 400, body: %{"error" => %{"type" => "invalid_request_error"}}}} =
               Anthropic.chat(%{"model" => "claude", "messages" => []},
                 base_url: base,
                 api_key: @api_key
               )
    end

    test "request/3 wraps a 429 in ProviderError with status and retry hint", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> respond_json(429, %{"error" => %{"type" => "rate_limit_error"}})
      end)

      assert {:error, %ProviderError{provider: :anthropic, status_code: 429} = err} =
               Anthropic.request(model(base), [Message.user("hi")], %{})

      assert err.retry_after_ms == 7_000
    end
  end
end
