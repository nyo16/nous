defmodule Nous.Providers.GeminiTest do
  # async: true — unlike the other provider Bypass suites this one never
  # touches the process environment: Gemini resolves its base URL from
  # opts/app-config only (`Nous.Provider.base_url/1`), and every test passes
  # `:api_key` explicitly so `GOOGLE_AI_API_KEY` is never read.
  use ExUnit.Case, async: true

  alias Nous.Errors.ProviderError
  alias Nous.Message
  alias Nous.Model
  alias Nous.Providers.Gemini
  alias Nous.Tool
  alias Nous.Tool.Wire

  @api_key "test-gemini-key"

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}/v1beta"}
  end

  # A Gemini-shaped `functionDeclarations` entry, produced the same way the
  # runner produces it. Building it through `Wire.to_gemini/1` rather
  # than hand-writing the map is deliberate: if the conversion ever regresses
  # back to the OpenAI `%{"type" => "function", "function" => ...}` envelope,
  # the refutations below fail instead of passing against a hard-coded fixture.
  defp weather_declaration do
    Wire.to_gemini(%Tool{
      name: "get_weather",
      description: "Look up the current weather for a city",
      parameters: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"],
        "additionalProperties" => false
      },
      function: fn _args -> {:ok, "sunny"} end
    })
  end

  defp model(base) do
    %Model{
      provider: :gemini,
      model: "gemini-2.0-flash",
      base_url: base,
      api_key: @api_key,
      # Generous: the peer is a local Bypass server, so this bound exists only
      # to stop a hung test hanging forever — it is never the thing under test.
      # At 5s it flaked on a loaded runner, timing out a round trip that would
      # have succeeded.
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
      "candidates" => [
        %{"content" => %{"role" => "model", "parts" => [%{"text" => text}]}}
      ]
    }
  end

  describe "macro-injected metadata" do
    test "exposes provider_id, default_base_url, and default_env_key" do
      assert Gemini.provider_id() == :gemini

      assert Gemini.default_base_url() ==
               "https://generativelanguage.googleapis.com/v1beta"

      assert Gemini.default_env_key() == "GOOGLE_AI_API_KEY"
    end
  end

  describe "chat/2 URL and auth" do
    test "POSTs to /models/<model>:generateContent with the key in the header, not the query",
         %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1beta/models/gemini-2.0-flash:generateContent"

        # The key must ride in `x-goog-api-key`. A `?key=` query string leaks
        # the secret into proxy/LB access logs — see the comment on
        # `Gemini.build_url/3`.
        assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == [@api_key]
        assert conn.query_string == ""
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")

        {body, conn} = read_json_body(conn)

        # The model lives in the path; Gemini rejects it in the body.
        refute Map.has_key?(body, "model")
        assert body["contents"] == [%{"role" => "user", "parts" => [%{"text" => "hi"}]}]

        respond_json(conn, 200, text_response("hello"))
      end)

      params = %{
        "model" => "gemini-2.0-flash",
        "contents" => [%{"role" => "user", "parts" => [%{"text" => "hi"}]}]
      }

      assert {:ok, %{"candidates" => [_]}} =
               Gemini.chat(params, base_url: base, api_key: @api_key)
    end

    test "falls back to gemini-2.0-flash-exp when no model is given", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.request_path == "/v1beta/models/gemini-2.0-flash-exp:generateContent"
        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, _} = Gemini.chat(%{"contents" => []}, base_url: base, api_key: @api_key)
    end

    test "accepts an atom :model key and strips it from the body", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.request_path == "/v1beta/models/gemini-1.5-pro:generateContent"
        {body, conn} = read_json_body(conn)
        refute Map.has_key?(body, "model")
        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, _} =
               Gemini.chat(%{"contents" => [], model: "gemini-1.5-pro"},
                 base_url: base,
                 api_key: @api_key
               )
    end
  end

  describe "chat_stream/2" do
    test "POSTs to :streamGenerateContent and decodes the JSON-array stream", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1beta/models/gemini-2.0-flash:streamGenerateContent"
        assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == [@api_key]

        body =
          ~s([{"candidates":[{"content":{"parts":[{"text":"hel"}]}}]},) <>
            ~s({"candidates":[{"content":{"parts":[{"text":"lo"}]}}]}])

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, body)
      end)

      params = %{
        "model" => "gemini-2.0-flash",
        "contents" => [%{"role" => "user", "parts" => [%{"text" => "hi"}]}]
      }

      assert {:ok, stream} = Gemini.chat_stream(params, base_url: base, api_key: @api_key)

      assert [
               %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hel"}]}}]},
               %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "lo"}]}}]}
             ] = Enum.to_list(stream)
    end
  end

  describe "request/3 body shape" do
    test "hoists the system prompt into systemInstruction and maps settings to generationConfig",
         %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        # System is hoisted out of `contents` into a top-level
        # `systemInstruction`; Gemini has no "system" role in `contents`
        # and no top-level "system" string (that is Anthropic's dialect).
        assert body["systemInstruction"] == %{"parts" => [%{"text" => "You are terse."}]}
        refute Map.has_key?(body, "system")
        refute Enum.any?(body["contents"], &(&1["role"] == "system"))

        assert body["contents"] == [
                 %{"role" => "user", "parts" => [%{"text" => "Weather in Athens?"}]}
               ]

        # Generic settings are renamed into Gemini's generationConfig; they
        # must NOT appear as top-level OpenAI-style keys.
        assert body["generationConfig"]["temperature"] == 0.2
        assert body["generationConfig"]["maxOutputTokens"] == 256
        refute Map.has_key?(body, "temperature")
        refute Map.has_key?(body, "max_tokens")

        respond_json(conn, 200, text_response("Sunny."))
      end)

      messages = [Message.system("You are terse."), Message.user("Weather in Athens?")]
      settings = %{temperature: 0.2, max_tokens: 256}

      assert {:ok, %Message{role: :assistant, content: "Sunny."}} =
               Gemini.request(model(base), messages, settings)
    end

    test "wraps tools as functionDeclarations without the OpenAI envelope", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        assert [%{"functionDeclarations" => [declaration]}] = body["tools"]

        assert declaration["name"] == "get_weather"
        assert declaration["description"] == "Look up the current weather for a city"
        assert declaration["parameters"]["type"] == "object"
        assert declaration["parameters"]["properties"] == %{"city" => %{"type" => "string"}}
        assert declaration["parameters"]["required"] == ["city"]

        # THE regression this file exists for: an OpenAI tool envelope
        # (`%{"type" => "function", "function" => %{...}}`) was once nested
        # inside functionDeclarations and shipped to Gemini/Vertex. Gemini
        # rejects it, and nothing asserted on the outgoing body.
        refute Map.has_key?(declaration, "type")
        refute Map.has_key?(declaration, "function")
        refute Map.has_key?(declaration, "input_schema")

        # Vertex's schema validator rejects these JSON Schema keys outright.
        refute Map.has_key?(declaration["parameters"], "additionalProperties")
        refute Map.has_key?(declaration["parameters"], "$schema")

        # And the tools array itself is the Gemini wrapper list, never the
        # bare OpenAI list of function objects.
        refute Enum.any?(body["tools"], &Map.has_key?(&1, "function"))

        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, %Message{}} =
               Gemini.request(
                 model(base),
                 [Message.user("Weather in Athens?")],
                 %{tools: [weather_declaration()]}
               )
    end

    test "renders tool_choice as toolConfig", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "ANY"}}
        refute Map.has_key?(body, "tool_choice")

        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, %Message{}} =
               Gemini.request(
                 model(base),
                 [Message.user("hi")],
                 %{tools: [weather_declaration()], tool_choice: :required}
               )
    end

    @tag :capture_log
    test "merges :extra_body but drops keys that would rewrite the request", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        {body, conn} = read_json_body(conn)

        # Additive vendor keys land at the top level of the Gemini body.
        assert body["labels"] == %{"team" => "search"}

        # `tools` is on the macro's blocked list: :extra_body is additive-only
        # and must not become a back-door for rewriting the tool list.
        assert [%{"functionDeclarations" => [%{"name" => "get_weather"} | _]}] = body["tools"]

        respond_json(conn, 200, text_response("ok"))
      end)

      assert {:ok, %Message{}} =
               Gemini.request(
                 model(base),
                 [Message.user("hi")],
                 %{
                   tools: [weather_declaration()],
                   extra_body: %{"labels" => %{"team" => "search"}, "tools" => "hijacked"}
                 }
               )
    end
  end

  describe "request_stream/3" do
    test "hits :streamGenerateContent and normalizes through the Gemini normalizer", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        assert conn.request_path == "/v1beta/models/gemini-2.0-flash:streamGenerateContent"

        {body, conn} = read_json_body(conn)
        assert body["contents"] == [%{"role" => "user", "parts" => [%{"text" => "hi"}]}]

        chunks =
          ~s([{"candidates":[{"content":{"parts":[{"text":"hel"}]}}]},) <>
            ~s({"candidates":[{"content":{"parts":[{"text":"lo"}]},"finishReason":"STOP"}]}])

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, chunks)
      end)

      assert {:ok, stream} = Gemini.request_stream(model(base), [Message.user("hi")], %{})

      # request_stream/3 must pick Nous.StreamNormalizer.Gemini (not the
      # OpenAI default), which turns candidate parts into :text_delta and
      # finishReason into :finish.
      events = Enum.to_list(stream)

      assert Enum.filter(events, &match?({:text_delta, _}, &1)) ==
               [{:text_delta, "hel"}, {:text_delta, "lo"}]

      # Gemini's "STOP" is mapped to the normalized "stop".
      assert {:finish, "stop"} in events
    end
  end

  describe "error mapping" do
    test "chat/2 surfaces a non-200 as {:error, %{status: ...}}", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, fn conn ->
        respond_json(conn, 429, %{"error" => %{"message" => "quota"}})
      end)

      assert {:error, %{status: 429, body: %{"error" => %{"message" => "quota"}}}} =
               Gemini.chat(%{"model" => "gemini-2.0-flash", "contents" => []},
                 base_url: base,
                 api_key: @api_key
               )
    end

    test "request/3 wraps a non-200 in ProviderError with the status code", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, fn conn ->
        respond_json(conn, 503, %{"error" => %{"message" => "overloaded"}})
      end)

      assert {:error, %ProviderError{provider: :gemini, status_code: 503}} =
               Gemini.request(model(base), [Message.user("hi")], %{})
    end
  end
end
