defmodule Nous.DecisionModel.Backend.OpenAIDecisionsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Nous.DecisionModel
  alias Nous.DecisionModel.{Answer, Result}
  alias Nous.DecisionModel.Backend.OpenAIDecisions
  alias Nous.Errors.DecisionModelError

  @questions [
    damaged: [type: :noul, instructions: "Does the customer report a damaged item?"],
    department: [
      type: :choice,
      instructions: "Which department should handle this complaint?",
      criteria: [{"returns", "Refunds and exchanges."}, {"billing", nil}]
    ],
    severity: [
      type: :score,
      instructions: "How severe is the damage?",
      criteria: ["cosmetic", "broken"]
    ]
  ]

  # vLLM's /v1/decisions answers (vLLM docs, "OpenAI Decisions API"): an
  # array that echoes each question's `name`, probabilities as arrays.
  @response ~s({"id":"dec-1","object":"decision","model":"Qwen/Qwen3-0.6B","answers":[) <>
              ~s({"type":"predicate","name":"damaged","probability":0.92},) <>
              ~s({"type":"choice","name":"department","choice":"returns","probabilities":[{"value":"returns","probability":0.95},{"value":"billing","probability":0.05}],"confidence":0.93},) <>
              ~s({"type":"score","name":"severity","score":0.8,"probabilities":[{"value":0,"label":"cosmetic","probability":0.2},{"value":1,"label":"broken","probability":0.8}],"confidence":0.55}) <>
              ~s(],"usage":{"input_tokens":142,"output_tokens":3}})

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(status, body)
  end

  defp dm(base, opts \\ []) do
    DecisionModel.parse("openai_decisions:Qwen/Qwen3-0.6B", [base_url: base] ++ opts)
  end

  test "POSTs {base_url}/v1/decisions with questions as an ordered array keyed by name",
       %{bypass: bypass, base: base} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/v1/decisions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, body})
      json(conn, 200, @response)
    end)

    assert {:ok, _} =
             DecisionModel.decide(
               dm(base),
               "The package arrived with a broken screen.",
               @questions
             )

    assert_receive {:body, body}

    assert body ==
             ~s({"model":"Qwen/Qwen3-0.6B","input":"The package arrived with a broken screen.","questions":[) <>
               ~s({"type":"predicate","name":"damaged","instructions":"Does the customer report a damaged item?"},) <>
               ~s({"type":"choice","name":"department","instructions":"Which department should handle this complaint?",) <>
               ~s("choices":[{"value":"returns","description":"Refunds and exchanges."},{"value":"billing"}]},) <>
               ~s({"type":"score","name":"severity","instructions":"How severe is the damage?",) <>
               ~s("levels":[{"label":"cosmetic"},{"label":"broken"}]}]})
  end

  test "maps answers back by name to declared ids, in declared order",
       %{bypass: bypass, base: base} do
    # The server lists answers in a different order than the questions.
    shuffled =
      @response
      |> JSON.decode!()
      |> Map.update!("answers", &Enum.reverse/1)
      |> JSON.encode!()

    Bypass.expect_once(bypass, "POST", "/v1/decisions", &json(&1, 200, shuffled))

    assert {:ok, result} = DecisionModel.decide(dm(base), "text", @questions)

    assert Enum.map(result.answers, &elem(&1, 0)) == [:damaged, :department, :severity]
    assert result.usage == %{input_tokens: 142, output_tokens: 3}
    assert result.backend == OpenAIDecisions

    assert {:ok, %Answer{type: :noul, noul: 0.92}} = Result.fetch(result, :damaged)

    assert {:ok,
            %Answer{
              type: :choice,
              choice: "returns",
              probabilities: [{"returns", 0.95}, {"billing", 0.05}],
              confidence: 0.93
            }} = Result.fetch(result, :department)

    assert {:ok, %Answer{type: :score, score: 0.8, probabilities: [{0, 0.2}, {1, 0.8}]}} =
             Result.fetch(result, :severity)
  end

  test "noul criteria are folded into the predicate's instructions; a map state is sent as JSON text",
       %{bypass: bypass, base: base} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/v1/decisions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, JSON.decode!(body)})

      json(
        conn,
        200,
        ~s({"answers":[{"type":"predicate","name":"risky","probability":0.1}],"usage":{"input_tokens":9,"output_tokens":1}})
      )
    end)

    questions = [
      risky: [
        type: :noul,
        instructions: "Risky?",
        criteria: [{"true", "it deletes"}, {"false", "read-only"}]
      ]
    ]

    assert {:ok, _} = DecisionModel.decide(dm(base), %{"tool" => "rm"}, questions)

    assert_receive {:body, %{"input" => input, "questions" => [question]}}
    assert input == ~s({"tool":"rm"})
    assert question["instructions"] == "Risky?\nTrue if: it deletes\nFalse if: read-only"
    refute Map.has_key?(question, "criteria")
  end

  test "an undeclared choice value is :unknown_label", %{bypass: bypass, base: base} do
    response =
      ~s({"answers":[{"type":"choice","name":"department","choice":"legal","probabilities":[{"value":"legal","probability":1.0}],"confidence":1.0}]})

    Bypass.expect_once(bypass, "POST", "/v1/decisions", &json(&1, 200, response))

    assert {:error, %DecisionModelError{reason: :unknown_label, backend: OpenAIDecisions}} =
             DecisionModel.decide(dm(base), "x", Keyword.take(@questions, [:department]))
  end

  test "an answer for an undeclared name is :unknown_label", %{bypass: bypass, base: base} do
    response = ~s({"answers":[{"type":"predicate","name":"other","probability":0.5}]})
    Bypass.expect_once(bypass, "POST", "/v1/decisions", &json(&1, 200, response))

    assert {:error, %DecisionModelError{reason: :unknown_label}} =
             DecisionModel.decide(dm(base), "x", Keyword.take(@questions, [:damaged]))
  end

  test "a refusal is an error, never an answer", %{bypass: bypass, base: base} do
    response = ~s({"answers":[{"type":"refusal","name":"damaged"}]})
    Bypass.expect_once(bypass, "POST", "/v1/decisions", &json(&1, 200, response))

    assert {:error, %DecisionModelError{reason: :invalid_response}} =
             DecisionModel.decide(dm(base), "x", Keyword.take(@questions, [:damaged]))
  end

  test "sends OPENAI-style bearer auth from :api_key", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "POST", "/v1/decisions", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test"]
      json(conn, 200, ~s({"answers":[{"type":"predicate","name":"damaged","probability":0.5}]}))
    end)

    assert {:ok, _} =
             DecisionModel.decide(
               dm(base, api_key: "sk-test"),
               "x",
               Keyword.take(@questions, [:damaged])
             )
  end

  test "429 maps to a retryable :http error", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "POST", "/v1/decisions", &json(&1, 429, ~s({"error":"slow down"})))

    assert {:error, %DecisionModelError{reason: :http, status: 429, retryable?: true}} =
             DecisionModel.decide(dm(base), "x", Keyword.take(@questions, [:damaged]))
  end
end
