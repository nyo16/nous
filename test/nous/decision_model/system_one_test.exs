defmodule Nous.DecisionModel.Backend.SystemOneTest do
  # async: false — the Workers AI cases set CLOUDFLARE_* env vars.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Nous.DecisionModel
  alias Nous.DecisionModel.{Answer, Result}
  alias Nous.DecisionModel.Backend.SystemOne
  alias Nous.Errors.DecisionModelError

  @fixture Path.expand(
             "../../support/fixtures/decision_model/workers_ai_clef_flash.json",
             __DIR__
           )

  # Declared in an order a map would re-sort (a map gives prompt_injection,
  # severity, verdict) and with options out of alphabetical order.
  @questions [
    prompt_injection: [
      type: :noul,
      instructions: "Injection?",
      criteria: [{"true", "yes"}, {"false", "no"}]
    ],
    verdict: [
      type: :choice,
      instructions: "Handle how?",
      criteria: [safe: "benign", suspicious: nil, blocked: "attack"]
    ],
    severity: [type: :score, instructions: "How bad?", criteria: ["none", "minor", "major"]]
  ]

  @state %{"surface" => "user_input", "untrusted_content" => "hello"}

  @expected_body ~s({"model":"clef-flash",) <>
                   ~s("state":{"surface":"user_input","untrusted_content":"hello"},) <>
                   ~s("questions":{) <>
                   ~s("prompt_injection":{"type":"noul","instructions":"Injection?","criteria":{"true":"yes","false":"no"}},) <>
                   ~s("verdict":{"type":"choice","instructions":"Handle how?","criteria":{"safe":"benign","suspicious":null,"blocked":"attack"}},) <>
                   ~s("severity":{"type":"score","instructions":"How bad?","criteria":["none","minor","major"]}}})

  setup do
    bypass = Bypass.open()
    envelope = File.read!(@fixture)
    plain = envelope |> JSON.decode!() |> Map.fetch!("result") |> JSON.encode!()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}", envelope: envelope, plain: plain}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(status, body)
  end

  defp systemone(base, opts \\ []) do
    DecisionModel.parse("systemone:clef-flash", [base_url: base] ++ opts)
  end

  for http_backend <- [Nous.HTTP.Backend.Req, Nous.HTTP.Backend.Hackney] do
    @http_backend http_backend

    test "POSTs {base_url}/v1/systemone with questions and options in declared order " <>
           "(#{inspect(http_backend)})",
         %{bypass: bypass, base: base, plain: plain} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, body})
        json(conn, 200, plain)
      end)

      dm = systemone(base, http_backend: @http_backend)
      assert {:ok, %Result{}} = DecisionModel.decide(dm, @state, @questions)

      assert_receive {:body, body}
      # Exact bytes: key order of questions and options, no top-level
      # "instructions", "model" first.
      assert body == @expected_body
    end
  end

  test "maps answers back to the declared ids and option keys, in question order",
       %{bypass: bypass, base: base, plain: plain} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", &json(&1, 200, plain))

    assert {:ok, result} = DecisionModel.decide(systemone(base), @state, @questions)

    assert Enum.map(result.answers, &elem(&1, 0)) == [:prompt_injection, :verdict, :severity]
    assert result.usage == %{input_tokens: 187, output_tokens: 0}
    assert result.backend == SystemOne
    assert result.model == "clef-flash"

    assert {:ok,
            %Answer{type: :noul, noul: 0.031, probabilities: [{"true", 0.031}, {"false", f}]}} =
             Result.fetch(result, :prompt_injection)

    assert_in_delta f, 0.969, 1.0e-9

    assert {:ok,
            %Answer{
              type: :choice,
              choice: :safe,
              probabilities: [safe: 0.91, suspicious: 0.06, blocked: 0.03],
              confidence: 0.82
            }} = Result.fetch(result, :verdict)

    assert {:ok,
            %Answer{
              type: :score,
              score: 0.4,
              probabilities: [{0, 0.7}, {1, 0.2}, {2, 0.1}],
              confidence: 0.41
            }} = Result.fetch(result, :severity)
  end

  test "sends a bearer token when :api_key is given", %{bypass: bypass, base: base, plain: plain} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer s3cret"]
      json(conn, 200, plain)
    end)

    assert {:ok, _} = DecisionModel.decide(systemone(base, api_key: "s3cret"), @state, @questions)
  end

  test "a base_url ending in /v1 is not doubled", %{bypass: bypass, base: base, plain: plain} do
    Bypass.expect_once(bypass, "POST", "/v1/systemone", &json(&1, 200, plain))
    assert {:ok, _} = DecisionModel.decide(systemone(base <> "/v1/"), @state, @questions)
  end

  describe "Workers AI preset" do
    setup do
      saved = for k <- ~w(CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN), do: {k, System.get_env(k)}

      on_exit(fn ->
        Enum.each(saved, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)
    end

    test "uses CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN and unwraps the result envelope",
         %{bypass: bypass, base: base, envelope: envelope} do
      System.put_env("CLOUDFLARE_ACCOUNT_ID", "acc0123")
      System.put_env("CLOUDFLARE_API_TOKEN", "cf-token")
      test_pid = self()

      Bypass.expect_once(
        bypass,
        "POST",
        "/client/v4/accounts/acc0123/ai/run/@cf/cloudflare/clef-flash",
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:request, Plug.Conn.get_req_header(conn, "authorization"), body})
          json(conn, 200, envelope)
        end
      )

      dm = DecisionModel.parse("workers_ai:clef-flash", base_url: base <> "/client/v4")
      assert {:ok, result} = DecisionModel.decide(dm, @state, @questions)

      assert_receive {:request, ["Bearer cf-token"], body}
      assert body == @expected_body
      assert {:ok, %Answer{choice: :safe}} = Result.fetch(result, :verdict)
      assert result.usage.input_tokens == 187
    end

    test "without credentials it fails closed and sends nothing", %{base: base} do
      System.delete_env("CLOUDFLARE_ACCOUNT_ID")
      System.delete_env("CLOUDFLARE_API_TOKEN")

      dm = DecisionModel.parse("workers_ai:clef-flash", base_url: base <> "/client/v4")

      assert {:error, %DecisionModelError{reason: :unavailable, backend: SystemOne}} =
               DecisionModel.decide(dm, @state, @questions)
    end

    test "max_state_tokens is the 65,536-token Workers AI window" do
      assert DecisionModel.max_state_tokens(DecisionModel.parse("workers_ai:clef")) == 65_536
      assert DecisionModel.max_state_tokens(systemone("http://localhost:1")) == 16_384
    end
  end

  describe "error mapping" do
    test "429 is retryable and carries Retry-After", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> json(429, ~s({"error":"rate limited"}))
      end)

      assert {:error,
              %DecisionModelError{
                reason: :http,
                status: 429,
                retryable?: true,
                retry_after_ms: 2_000
              }} = DecisionModel.decide(systemone(base), @state, @questions)
    end

    test "400 saying the request is too long is :oversize", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
        json(
          conn,
          400,
          ~s({"error":{"message":"The schema is too long for max_model_len 16384"}})
        )
      end)

      assert {:error, %DecisionModelError{reason: :oversize, status: 400, retryable?: false}} =
               DecisionModel.decide(systemone(base), @state, @questions)
    end

    test "other 4xx is a non-retryable :http error", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
        json(conn, 400, ~s({"error":"unknown field instructions"}))
      end)

      assert {:error, %DecisionModelError{reason: :http, status: 400, retryable?: false}} =
               DecisionModel.decide(systemone(base), @state, @questions)
    end

    test "5xx is a retryable :http error", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/v1/systemone", &json(&1, 503, ~s({"error":"busy"})))

      assert {:error, %DecisionModelError{reason: :http, status: 503, retryable?: true}} =
               DecisionModel.decide(systemone(base), @state, @questions)
    end

    test "a server that does not answer in time is :timeout",
         %{bypass: bypass, base: base, plain: plain} do
      test_pid = self()

      # The handler holds the response until the test has seen the timeout,
      # then answers, so Bypass is not torn down mid-request.
      Bypass.expect_once(bypass, "POST", "/v1/systemone", fn conn ->
        send(test_pid, {:handler, self()})

        receive do
          :release -> :ok
        after
          2_000 -> :ok
        end

        json(conn, 200, plain)
      end)

      assert {:error, %DecisionModelError{reason: :timeout, retryable?: true}} =
               DecisionModel.decide(systemone(base), @state, @questions, timeout: 50)

      assert_receive {:handler, handler}
      send(handler, :release)
    end

    test "a refused connection is :unavailable", %{bypass: bypass, base: base} do
      Bypass.down(bypass)

      assert {:error, %DecisionModelError{reason: :unavailable}} =
               DecisionModel.decide(systemone(base), @state, @questions)
    end

    test "a choice label that was not declared is :unknown_label", %{bypass: bypass, base: base} do
      response =
        ~s({"answers":{"verdict":{"type":"choice","choice":"evil","probabilities":{"safe":0.1,"evil":0.9},"confidence":0.8}},"usage":{"input_tokens":3,"output_tokens":0}})

      Bypass.expect_once(bypass, "POST", "/v1/systemone", &json(&1, 200, response))

      assert {:error, %DecisionModelError{reason: :unknown_label}} =
               DecisionModel.decide(systemone(base), @state, Keyword.take(@questions, [:verdict]))
    end

    test "an answer for an undeclared question id is :unknown_label", %{
      bypass: bypass,
      base: base
    } do
      response =
        ~s({"answers":{"prompt_injection":{"type":"noul","noul":0.1},"extra":{"type":"noul","noul":0.9}},"usage":{"input_tokens":3,"output_tokens":0}})

      Bypass.expect_once(bypass, "POST", "/v1/systemone", &json(&1, 200, response))

      questions = Keyword.take(@questions, [:prompt_injection])

      assert {:error, %DecisionModelError{reason: :unknown_label}} =
               DecisionModel.decide(systemone(base), @state, questions)
    end

    test "a score level outside the declared levels is :unknown_label", %{
      bypass: bypass,
      base: base
    } do
      response =
        ~s({"answers":{"severity":{"type":"score","score":1.0,"probabilities":{"0":0.5,"1":0.3,"2":0.1,"3":0.1},"confidence":0.2}},"usage":{"input_tokens":3,"output_tokens":0}})

      Bypass.expect_once(bypass, "POST", "/v1/systemone", &json(&1, 200, response))

      assert {:error, %DecisionModelError{reason: :unknown_label}} =
               DecisionModel.decide(
                 systemone(base),
                 @state,
                 Keyword.take(@questions, [:severity])
               )
    end

    test "a missing answer is :invalid_response, never a default", %{bypass: bypass, base: base} do
      response = ~s({"answers":{},"usage":{"input_tokens":3,"output_tokens":0}})
      Bypass.expect_once(bypass, "POST", "/v1/systemone", &json(&1, 200, response))

      assert {:error, %DecisionModelError{reason: :invalid_response}} =
               DecisionModel.decide(systemone(base), @state, @questions)
    end
  end

  describe "UrlGuard" do
    # 0.0.0.0 ("this network") is on UrlGuard's blocklist and is not one of the
    # explicit loopback names, yet a connection to it reaches the loopback
    # Bypass listener. So the same server is refused without the opt-in and
    # answered with it.
    test "a private-network base_url is refused before any request is sent",
         %{bypass: bypass} do
      dm = systemone("http://0.0.0.0:#{bypass.port}")

      assert {:error, %DecisionModelError{reason: :unavailable, message: message}} =
               DecisionModel.decide(dm, @state, @questions)

      assert message =~ "SSRF"
    end

    test "allow_private_hosts: true lets that same base_url through",
         %{bypass: bypass, plain: plain} do
      Bypass.expect_once(bypass, "POST", "/v1/systemone", &json(&1, 200, plain))

      dm = systemone("http://0.0.0.0:#{bypass.port}", allow_private_hosts: true)
      assert {:ok, %Result{}} = DecisionModel.decide(dm, @state, @questions)
    end

    test "non-http schemes are refused" do
      dm = systemone("file:///etc/passwd")

      assert {:error, %DecisionModelError{reason: :unavailable}} =
               DecisionModel.decide(dm, @state, @questions)
    end
  end
end
