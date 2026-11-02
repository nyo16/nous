defmodule Nous.Providers.SeedForwardingTest do
  # R4: `model_settings: %{seed: n}` reached the wire only for Gemini/Vertex;
  # the default request builder dropped it silently everywhere else. Asserted
  # on the request body each provider sends.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner}

  import ExUnit.CaptureLog

  @moduletag :capture_log

  setup do
    Nous.ModelDispatcher.put_dispatcher(nil)
    previous = Application.get_env(:nous, :custom)
    Application.put_env(:nous, :custom, allow_private_hosts: true)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nous, :custom, previous),
        else: Application.delete_env(:nous, :custom)
    end)

    :ok
  end

  # Sends one seeded run to `model` against a Bypass endpoint that answers 500,
  # and returns the first request body it received.
  defp request_body(model, base_url_fun) do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, JSON.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(500, ~s({"error":{"message":"stop"}}))
    end)

    agent =
      Agent.new(model,
        base_url: base_url_fun.(bypass.port),
        api_key: "k",
        model_settings: %{seed: 42, temperature: 0.0}
      )

    AgentRunner.run(agent, "hi")
    assert_receive {:body, body}, 2_000
    body
  end

  for model <- ["openai:gpt-4o-mini", "custom:test-model", "vllm:test-model"] do
    test "#{model} sends seed" do
      body = request_body(unquote(model), &"http://localhost:#{&1}/v1")
      assert body["seed"] == 42
    end
  end

  test "mistral sends the seed as random_seed" do
    body = request_body("mistral:mistral-small", &"http://localhost:#{&1}/v1")

    assert body["random_seed"] == 42
    refute Map.has_key?(body, "seed")
  end

  test "gemini keeps the seed in generationConfig" do
    body = request_body("gemini:gemini-2.0-flash", &"http://localhost:#{&1}")
    assert body["generationConfig"]["seed"] == 42
  end

  test "anthropic drops the seed and warns once" do
    :persistent_term.erase({Nous.Provider, :seed_dropped, :anthropic})

    log =
      capture_log(fn ->
        body = request_body("anthropic:claude-sonnet-4-5", &"http://localhost:#{&1}")
        refute Map.has_key?(body, "seed")
        assert body["temperature"] == 0.0

        request_body("anthropic:claude-sonnet-4-5", &"http://localhost:#{&1}")
      end)

    assert length(String.split(log, "anthropic has no seed parameter")) == 2
  end
end
