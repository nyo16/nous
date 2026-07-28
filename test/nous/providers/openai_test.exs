defmodule Nous.Providers.OpenAITest do
  # async: true — this suite never touches the process environment. OpenAI
  # resolves its base URL from opts/app-config only (there is no
  # `OPENAI_BASE_URL` lookup in `Nous.Provider.base_url/1`), and every test
  # passes `:api_key` explicitly so `OPENAI_API_KEY` is never read.
  use ExUnit.Case, async: true

  alias Nous.Errors.ProviderError
  alias Nous.Message
  alias Nous.Model
  alias Nous.Providers.OpenAI
  alias Nous.Tool

  @api_key "sk-test-key"

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}/v1"}
  end

  # Built through `Tool.to_openai_schema/1` so a regression in the conversion
  # (a bare Gemini-style declaration, a missing envelope) fails here.
  defp weather_tool_schema do
    Tool.to_openai_schema(%Tool{
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

  defp model(base, overrides) do
    struct!(
      %Model{
        provider: :openai,
        model: "gpt-4o",
        base_url: base,
        api_key: @api_key,
        # Generous: the peer is a local Bypass server, so this bound exists only
        # to stop a hung test hanging forever — it is never the thing under test.
        receive_timeout: 30_000
      },
      overrides
    )
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
      "id" => "chatcmpl-1",
      "model" => "gpt-4o",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 4, "total_tokens" => 7}
    }
  end

  describe "macro-injected metadata" do
    test "exposes provider_id, default_base_url, and default_env_key" do
      assert OpenAI.provider_id() == :openai
      assert OpenAI.default_base_url() == "https://api.openai.com/v1"
      assert OpenAI.default_env_key() == "OPENAI_API_KEY"
    end
  end

  describe "chat/2 URL and auth" do
    test "POSTs to /chat/completions with a Bearer token", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/chat/completions"

        # OpenAI uses `authorization: Bearer`, not Anthropic's `x-api-key`
        # and not Gemini's `x-goog-api-key`.
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@api_key}"]
        assert Plug.Conn.get_req_header(conn, "x-api-key") == []
        assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == []
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")

        # No org / project scoping was requested.
        assert Plug.Conn.get_req_header(conn, "openai-organization") == []
        assert Plug.Conn.get_req_header(conn, "openai-project") == []

        {body, conn} = read_json_body(conn)
        # Unlike Gemini, the model stays in the body.
        assert body["model"] == "gpt-4o"
        assert body["messages"] == [%{"role" => "user", "content" => "hi"}]

        respond_json(conn, 200, text_response("hello"))
      end)

      params = %{
        "model" => "gpt-4o",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      assert {:ok, %{"id" => "chatcmpl-1"}} =
               OpenAI.chat(params, base_url: base, api_key: @api_key)
    end

    test "sends openai-organization and openai-project when scoped", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        assert Plug.Conn.get_req_header(conn, "openai-organization") == ["org-test"]
        assert Plug.Conn.get_req_header(conn, "openai-project") == ["proj-test"]
        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, _} =
               OpenAI.chat(%{"model" => "gpt-4o", "messages" => []},
                 base_url: base,
                 api_key: @api_key,
                 organization: "org-test",
                 project: "proj-test"
               )
    end

    test "omits the authorization header when no key is configured", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        # `HTTP.bearer_auth_header/1` drops nil/""/"not-needed" so local
        # OpenAI-compatible servers are not sent a `Bearer not-needed`.
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, _} =
               OpenAI.chat(%{"model" => "gpt-4o", "messages" => []},
                 base_url: base,
                 api_key: "not-needed"
               )
    end
  end

  describe "chat/2 reasoning-model adjustments" do
    test "strips temperature, top_p and the penalties for o-series models", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        # The o-series API 400s on any of these; chat/2 must drop them
        # rather than forward what the caller passed.
        refute Map.has_key?(body, "temperature")
        refute Map.has_key?(body, "top_p")
        refute Map.has_key?(body, "presence_penalty")
        refute Map.has_key?(body, "frequency_penalty")

        # Everything else survives.
        assert body["model"] == "o3-mini"
        assert body["max_completion_tokens"] == 4096

        respond_json(conn, 200, text_response("ok"))
      end)

      params = %{
        "model" => "o3-mini",
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "temperature" => 0.7,
        "top_p" => 0.9,
        "presence_penalty" => 0.1,
        "frequency_penalty" => 0.2,
        "max_completion_tokens" => 4096
      }

      assert {:ok, _} = OpenAI.chat(params, base_url: base, api_key: @api_key)
    end

    test "keeps temperature for non-reasoning models", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)
        assert body["temperature"] == 0.7
        respond_json(conn, 200, text_response("ok"))
      end)

      params = %{"model" => "gpt-4o", "messages" => [], "temperature" => 0.7}
      assert {:ok, _} = OpenAI.chat(params, base_url: base, api_key: @api_key)
    end
  end

  describe "chat_stream/2" do
    test "forces stream: true and consumes the SSE stream", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.request_path == "/v1/chat/completions"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@api_key}"]

        {body, conn} = read_json_body(conn)
        assert body["stream"] == true

        sse = """
        data: {"choices":[{"delta":{"content":"hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"}}]}

        data: [DONE]

        """

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.resp(200, sse)
      end)

      params = %{"model" => "gpt-4o", "messages" => [%{"role" => "user", "content" => "hi"}]}

      assert {:ok, stream} = OpenAI.chat_stream(params, base_url: base, api_key: @api_key)

      assert [
               %{"choices" => [%{"delta" => %{"content" => "hel"}}]},
               %{"choices" => [%{"delta" => %{"content" => "lo"}}]},
               {:stream_done, "stop"}
             ] = Enum.to_list(stream)
    end

    test "refuses to stream a reasoning model without opening a connection" do
      # Port 9 is discard: if the guard ever regresses into an actual request
      # this returns a transport error instead of the expected tuple.
      assert {:error, %{reason: :streaming_not_supported, message: message}} =
               OpenAI.chat_stream(%{"model" => "o1-preview", "messages" => []},
                 base_url: "http://127.0.0.1:9/v1",
                 api_key: @api_key
               )

      assert message =~ "o1-preview"
    end
  end

  describe "request/3 body shape" do
    test "keeps the system prompt inside messages and wraps tools in the OpenAI envelope", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        # Unlike Anthropic (top-level "system") and Gemini
        # ("systemInstruction"), OpenAI keeps system as the first message.
        assert body["messages"] == [
                 %{"role" => "system", "content" => "You are terse."},
                 %{"role" => "user", "content" => "Weather in Athens?"}
               ]

        refute Map.has_key?(body, "system")
        refute Map.has_key?(body, "systemInstruction")

        assert body["temperature"] == 0.2
        assert body["max_tokens"] == 256

        assert [tool] = body["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "get_weather"
        assert tool["function"]["description"] == "Look up the current weather for a city"
        assert tool["function"]["parameters"]["properties"] == %{"city" => %{"type" => "string"}}

        # The declaration must stay wrapped: a bare Gemini-style declaration
        # or an Anthropic `input_schema` here is a 400 from OpenAI.
        refute Map.has_key?(tool, "name")
        refute Map.has_key?(tool, "input_schema")
        refute Map.has_key?(tool, "functionDeclarations")

        assert body["tool_choice"] == "auto"

        respond_json(conn, 200, text_response("Sunny."))
      end)

      messages = [Message.system("You are terse."), Message.user("Weather in Athens?")]

      settings = %{
        temperature: 0.2,
        max_tokens: 256,
        tools: [weather_tool_schema()],
        tool_choice: "auto"
      }

      assert {:ok, %Message{role: :assistant, content: "Sunny."}} =
               OpenAI.request(model(base, []), messages, settings)
    end

    test "forwards the model organization as a header, not a body key", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        assert Plug.Conn.get_req_header(conn, "openai-organization") == ["org-from-model"]

        {body, conn} = read_json_body(conn)
        refute Map.has_key?(body, "organization")

        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, %Message{}} =
               OpenAI.request(
                 model(base, organization: "org-from-model"),
                 [Message.user("hi")],
                 %{}
               )
    end

    test "passes response_format through for structured outputs", %{bypass: bypass, base: base} do
      schema = %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "answer",
          "schema" => %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}
        }
      }

      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)
        assert body["response_format"] == schema
        respond_json(conn, 200, text_response("{}"))
      end)

      assert {:ok, %Message{}} =
               OpenAI.request(model(base, []), [Message.user("hi")], %{response_format: schema})
    end
  end

  describe "error mapping" do
    test "chat/2 surfaces a non-200 as {:error, %{status: ...}}", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        respond_json(conn, 401, %{"error" => %{"message" => "Incorrect API key"}})
      end)

      assert {:error, %{status: 401, body: %{"error" => %{"message" => "Incorrect API key"}}}} =
               OpenAI.chat(%{"model" => "gpt-4o", "messages" => []},
                 base_url: base,
                 api_key: "sk-wrong"
               )
    end

    test "request/3 wraps a 500 in ProviderError with the status code", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        respond_json(conn, 500, %{"error" => %{"message" => "server error"}})
      end)

      assert {:error, %ProviderError{provider: :openai, status_code: 500}} =
               OpenAI.request(model(base, []), [Message.user("hi")], %{})
    end
  end
end
