defmodule Nous.AgentRunner.StickyFallbackTest do
  # Regression test for cross-provider sticky fallback (research:
  # .claude/plans/decision-models/research/sticky-fallback.md).
  #
  # The primary (Anthropic) always 500s, so iteration 1 falls back to an
  # OpenAI-compatible model. Every assertion is on what the fallback provider
  # actually receives over HTTP, or on what the caller observes.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, Tool}

  import ExUnit.CaptureLog

  def weather(_args), do: {:ok, "sunny"}

  defp weather_tool do
    %Tool{
      name: "get_weather",
      description: "Look up the current weather for a city",
      parameters: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      },
      function: &__MODULE__.weather/1,
      takes_ctx: false
    }
  end

  setup do
    # Real HTTP dispatcher (other suites override it per process).
    Nous.ModelDispatcher.put_dispatcher(nil)
    anth = Bypass.open()
    oai = Bypass.open()
    test_pid = self()

    # Primary: Anthropic always 500s (ProviderError -> fallback-eligible).
    Bypass.stub(anth, "POST", "/v1/messages", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:anthropic_hit, JSON.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(500, ~s({"type":"error","error":{"type":"api_error","message":"boom"}}))
    end)

    %{anth: anth, oai: oai, test_pid: test_pid}
  end

  # The fallback endpoint. `responder.(n)` returns `{status, :tool_call | {:text, t} | body}`;
  # 200 replies are served as SSE when the request asked to stream.
  defp openai_compat(oai, test_pid, responder) do
    counter = :counters.new(1, [])

    Bypass.stub(oai, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      body = JSON.decode!(raw)
      send(test_pid, {:oai_hit, n, body})

      case responder.(n) do
        {200, reply} ->
          if body["stream"] do
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
            |> Plug.Conn.resp(200, sse_body(reply))
          else
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, JSON.encode!(json_body(reply)))
          end

        {status, error_body} ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(status, JSON.encode!(error_body))
      end
    end)
  end

  defp json_body(:tool_call) do
    %{
      "id" => "chatcmpl-1",
      "object" => "chat.completion",
      "model" => "fake-model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10}
    }
  end

  defp json_body({:text, text}) do
    %{
      "id" => "chatcmpl-2",
      "object" => "chat.completion",
      "model" => "fake-model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10}
    }
  end

  defp sse_body(:tool_call) do
    sse([
      %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}
                }
              ]
            }
          }
        ]
      },
      %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]}
    ])
  end

  defp sse_body({:text, text}) do
    sse([
      %{"choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => text}}]},
      %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}
    ])
  end

  defp sse(chunks) do
    Enum.map_join(chunks, "", &"data: #{JSON.encode!(&1)}\n\n") <> "data: [DONE]\n\n"
  end

  defp agent(anth, oai, opts \\ []) do
    Agent.new(
      "anthropic:claude-sonnet-4-20250514",
      [
        base_url: "http://localhost:#{anth.port}",
        api_key: "sk-ant-test",
        tools: [weather_tool()],
        fallback: [
          Nous.Model.parse("lmstudio:fake-model",
            base_url: "http://localhost:#{oai.port}/v1",
            api_key: "not-needed"
          )
        ]
      ] ++ opts
    )
  end

  defp drain(tag) do
    receive do
      {^tag, body} -> [body | drain(tag)]
      {^tag, n, body} -> [{n, body} | drain(tag)]
    after
      0 -> []
    end
  end

  defp drain_telemetry(ref) do
    receive do
      {event, ^ref, _measurements, meta} -> [{event, meta} | drain_telemetry(ref)]
    after
      0 -> []
    end
  end

  defp run_quietly(agent, prompt, opts) do
    {result, _log} = with_log(fn -> AgentRunner.run(agent, prompt, opts) end)
    result
  end

  defp assert_openai_tools(body, names) do
    tools = body["tools"]
    assert is_list(tools), "expected OpenAI-shaped tools, got: #{inspect(tools)}"

    for tool <- tools do
      assert %{"type" => "function", "function" => %{"name" => _, "parameters" => _}} = tool
      refute Map.has_key?(tool, "input_schema")
    end

    assert Enum.map(tools, & &1["function"]["name"]) == names
  end

  for stream? <- [false, true] do
    describe "stream: #{stream?}" do
      @describetag stream: stream?

      test "the fallback provider receives its own tool format on every iteration", %{
        anth: anth,
        oai: oai,
        test_pid: pid
      } do
        openai_compat(oai, pid, fn
          1 -> {200, :tool_call}
          _ -> {200, {:text, "done"}}
        end)

        ref =
          :telemetry_test.attach_event_handlers(self(), [
            [:nous, :agent, :fallback, :used],
            [:nous, :agent, :run, :stop]
          ])

        assert {:ok, result} =
                 run_quietly(agent(anth, oai), "weather?", stream: unquote(stream?))

        assert result.output == "done"
        assert [_] = drain(:anthropic_hit)
        assert [{1, first}, {2, second}] = drain(:oai_hit)
        assert_openai_tools(first, ["get_weather"])
        assert_openai_tools(second, ["get_weather"])

        events = drain_telemetry(ref)
        used = for {[:nous, :agent, :fallback, :used], meta} <- events, do: meta
        assert [%{original_provider: :anthropic, active_provider: :lmstudio}] = used

        assert [%{fallback_used: true, active_model_provider: :lmstudio}] =
                 for({[:nous, :agent, :run, :stop], meta} <- events, do: meta)

        refute Map.has_key?(result.deps, :active_model)
        refute Map.has_key?(result.context.deps, :active_model)
      end

      test "structured output keeps the fallback provider's response_format on iteration 2", %{
        anth: anth,
        oai: oai,
        test_pid: pid
      } do
        openai_compat(oai, pid, fn
          1 -> {200, :tool_call}
          _ -> {200, {:text, ~s({"answer":"sunny"})}}
        end)

        schema = %{
          "type" => "object",
          "properties" => %{"answer" => %{"type" => "string"}},
          "required" => ["answer"]
        }

        assert {:ok, _result} =
                 run_quietly(agent(anth, oai, output_type: schema), "weather?",
                   stream: unquote(stream?)
                 )

        assert [{1, first}, {2, second}] = drain(:oai_hit)

        for body <- [first, second] do
          assert %{"type" => "json_schema"} = body["response_format"]
          assert_openai_tools(body, ["get_weather"])
        end
      end

      test "a failing sticky fallback is tried once, not twice", %{
        anth: anth,
        oai: oai,
        test_pid: pid
      } do
        openai_compat(oai, pid, fn
          1 -> {200, :tool_call}
          _ -> {500, %{"error" => %{"message" => "down"}}}
        end)

        assert {:error, _} = run_quietly(agent(anth, oai), "weather?", stream: unquote(stream?))

        assert [_] = drain(:anthropic_hit)
        # Iteration 1 answered by the fallback; iteration 2 tries the sticky
        # fallback exactly once (the chain holds no duplicate of it).
        assert [{1, _}, {2, _}] = drain(:oai_hit)
      end

      test "a continued run starts at the primary again", %{
        anth: anth,
        oai: oai,
        test_pid: pid
      } do
        openai_compat(oai, pid, fn
          1 -> {200, :tool_call}
          _ -> {200, {:text, "done"}}
        end)

        a = agent(anth, oai)
        assert {:ok, r1} = run_quietly(a, "weather?", stream: unquote(stream?))
        refute Map.has_key?(r1.deps, :active_model)
        _ = drain(:anthropic_hit)
        _ = drain(:oai_hit)

        assert {:ok, _r2} =
                 run_quietly(a, "again?", context: r1.context, stream: unquote(stream?))

        # The primary is retried first, and the fallback it lands on gets its
        # own tool format from the very first request of the new run.
        assert [_] = drain(:anthropic_hit)
        assert [{3, body}] = drain(:oai_hit)
        assert_openai_tools(body, ["get_weather"])
      end
    end
  end

  test "a hand-built context carrying :active_model does not skip the primary", %{
    anth: anth,
    oai: oai,
    test_pid: pid
  } do
    openai_compat(oai, pid, fn _ -> {200, {:text, "done"}} end)
    a = agent(anth, oai)
    [fallback] = a.fallback

    ctx = Nous.Agent.Context.new(deps: %{active_model: fallback})

    capture_log(fn ->
      assert {:ok, _} = AgentRunner.run(a, "hi", context: ctx)
    end)

    assert [_] = drain(:anthropic_hit)
  end
end
