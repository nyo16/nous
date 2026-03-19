defmodule Nous.AgentFallbackTest do
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, Message, Model, Usage}
  alias Nous.Errors

  import ExUnit.CaptureLog

  # Mock dispatcher that tracks which models are called and can fail specific ones
  defmodule FallbackMockDispatcher do
    @moduledoc false

    # Uses the process dictionary to track calls and configure failures.
    # Each test sets up failures via `configure/1` before running.

    def configure(opts) do
      # Store config in a named ETS table for cross-process access
      if :ets.whereis(:fallback_mock_config) != :undefined do
        :ets.delete(:fallback_mock_config)
      end

      :ets.new(:fallback_mock_config, [:named_table, :public, :set])

      :ets.insert(
        :fallback_mock_config,
        {:fail_providers, Keyword.get(opts, :fail_providers, [])}
      )

      :ets.insert(:fallback_mock_config, {:fail_models, Keyword.get(opts, :fail_models, [])})
      :ets.insert(:fallback_mock_config, {:calls, []})
    end

    def get_calls do
      [{:calls, calls}] = :ets.lookup(:fallback_mock_config, :calls)
      Enum.reverse(calls)
    end

    def request(model, _messages, _settings) do
      record_call(model)

      fail_providers = get_config(:fail_providers)
      fail_models = get_config(:fail_models)

      cond do
        model.provider in fail_providers ->
          {:error,
           Errors.ProviderError.exception(
             message: "Provider #{model.provider} unavailable",
             provider: model.provider,
             status_code: 503
           )}

        model.model in fail_models ->
          {:error,
           Errors.ModelError.exception(
             message: "Model #{model.model} not found",
             provider: model.provider,
             status_code: 404
           )}

        true ->
          response = build_success_response(model)
          {:ok, response}
      end
    end

    def request_stream(model, _messages, _settings) do
      record_call(model)

      fail_providers = get_config(:fail_providers)
      fail_models = get_config(:fail_models)

      cond do
        model.provider in fail_providers ->
          {:error,
           Errors.ProviderError.exception(
             message: "Provider #{model.provider} unavailable",
             provider: model.provider
           )}

        model.model in fail_models ->
          {:error,
           Errors.ModelError.exception(
             message: "Model #{model.model} not found",
             provider: model.provider
           )}

        true ->
          stream = [
            {:text_delta, "Hello from #{model.provider}:#{model.model}"},
            {:finish, "stop"}
          ]

          {:ok, stream}
      end
    end

    def count_tokens(_messages), do: 50

    defp record_call(model) do
      [{:calls, calls}] = :ets.lookup(:fallback_mock_config, :calls)
      :ets.insert(:fallback_mock_config, {:calls, [{model.provider, model.model} | calls]})
    end

    defp get_config(key) do
      case :ets.lookup(:fallback_mock_config, key) do
        [{^key, value}] -> value
        [] -> []
      end
    end

    defp build_success_response(model) do
      legacy_response = %{
        parts: [{:text, "Response from #{model.provider}:#{model.model}"}],
        usage: %Usage{
          input_tokens: 10,
          output_tokens: 5,
          total_tokens: 15,
          tool_calls: 0,
          requests: 1
        },
        model_name: model.model,
        timestamp: DateTime.utc_now()
      }

      Message.from_legacy(legacy_response)
    end
  end

  setup do
    Application.put_env(:nous, :model_dispatcher, FallbackMockDispatcher)

    on_exit(fn ->
      Application.delete_env(:nous, :model_dispatcher)

      if :ets.whereis(:fallback_mock_config) != :undefined do
        :ets.delete(:fallback_mock_config)
      end
    end)

    :ok
  end

  describe "Agent.new/2 with fallback" do
    test "parses fallback model strings" do
      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514", "groq:llama-3.1-70b"]
        )

      assert length(agent.fallback) == 2
      assert [%Model{provider: :anthropic}, %Model{provider: :groq}] = agent.fallback
    end

    test "accepts Model structs in fallback list" do
      backup = Model.new(:anthropic, "claude-sonnet-4-20250514")
      agent = Agent.new("openai:gpt-4", fallback: [backup])

      assert [^backup] = agent.fallback
    end

    test "handles mixed strings and structs" do
      backup = Model.new(:groq, "llama-3.1-70b")

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514", backup]
        )

      assert [%Model{provider: :anthropic}, ^backup] = agent.fallback
    end

    test "defaults to empty fallback list" do
      agent = Agent.new("openai:gpt-4")
      assert agent.fallback == []
    end
  end

  describe "AgentRunner.run/3 with fallback" do
    test "uses primary model when it succeeds" do
      FallbackMockDispatcher.configure(fail_providers: [])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514"]
        )

      capture_log(fn ->
        {:ok, result} = AgentRunner.run(agent, "Hello")
        assert result.output =~ "openai:gpt-4"
      end)

      calls = FallbackMockDispatcher.get_calls()
      assert [{:openai, "gpt-4"}] = calls
    end

    test "falls back when primary provider fails" do
      FallbackMockDispatcher.configure(fail_providers: [:openai])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514"]
        )

      capture_log(fn ->
        {:ok, result} = AgentRunner.run(agent, "Hello")
        assert result.output =~ "anthropic:claude-sonnet-4-20250514"
      end)

      calls = FallbackMockDispatcher.get_calls()
      assert [{:openai, "gpt-4"}, {:anthropic, "claude-sonnet-4-20250514"}] = calls
    end

    test "falls back when primary model fails" do
      FallbackMockDispatcher.configure(fail_models: ["nonexistent-model"])

      agent =
        Agent.new("openai:nonexistent-model",
          fallback: ["openai:gpt-4"]
        )

      capture_log(fn ->
        {:ok, result} = AgentRunner.run(agent, "Hello")
        assert result.output =~ "openai:gpt-4"
      end)

      calls = FallbackMockDispatcher.get_calls()
      assert [{:openai, "nonexistent-model"}, {:openai, "gpt-4"}] = calls
    end

    test "tries all fallbacks in order" do
      FallbackMockDispatcher.configure(fail_providers: [:openai, :anthropic])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514", "groq:llama-3.1-70b"]
        )

      capture_log(fn ->
        {:ok, result} = AgentRunner.run(agent, "Hello")
        assert result.output =~ "groq:llama-3.1-70b"
      end)

      calls = FallbackMockDispatcher.get_calls()

      assert [
               {:openai, "gpt-4"},
               {:anthropic, "claude-sonnet-4-20250514"},
               {:groq, "llama-3.1-70b"}
             ] = calls
    end

    test "returns error when all models fail" do
      FallbackMockDispatcher.configure(fail_providers: [:openai, :anthropic])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514"]
        )

      capture_log(fn ->
        assert {:error, %Errors.ProviderError{}} = AgentRunner.run(agent, "Hello")
      end)

      calls = FallbackMockDispatcher.get_calls()
      assert length(calls) == 2
    end

    test "works without fallback configured (backward compatible)" do
      FallbackMockDispatcher.configure(fail_providers: [])

      agent = Agent.new("openai:gpt-4")

      capture_log(fn ->
        {:ok, result} = AgentRunner.run(agent, "Hello")
        assert result.output =~ "openai:gpt-4"
      end)

      calls = FallbackMockDispatcher.get_calls()
      assert [{:openai, "gpt-4"}] = calls
    end

    test "error without fallback still returns error (backward compatible)" do
      FallbackMockDispatcher.configure(fail_providers: [:openai])

      agent = Agent.new("openai:gpt-4")

      capture_log(fn ->
        assert {:error, _} = AgentRunner.run(agent, "Hello")
      end)
    end
  end

  describe "AgentRunner.run_stream/3 with fallback" do
    test "uses primary model when it succeeds" do
      FallbackMockDispatcher.configure(fail_providers: [])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514"]
        )

      capture_log(fn ->
        {:ok, stream} = AgentRunner.run_stream(agent, "Hello")
        events = Enum.to_list(stream)
        assert {:text_delta, text} = hd(events)
        assert text =~ "openai:gpt-4"
      end)
    end

    test "falls back when primary provider fails on stream init" do
      FallbackMockDispatcher.configure(fail_providers: [:openai])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514"]
        )

      capture_log(fn ->
        {:ok, stream} = AgentRunner.run_stream(agent, "Hello")
        events = Enum.to_list(stream)
        assert {:text_delta, text} = hd(events)
        assert text =~ "anthropic:claude-sonnet-4-20250514"
      end)
    end

    test "returns error when all models fail on stream init" do
      FallbackMockDispatcher.configure(fail_providers: [:openai, :anthropic])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514"]
        )

      capture_log(fn ->
        assert {:error, %Errors.ProviderError{}} = AgentRunner.run_stream(agent, "Hello")
      end)
    end
  end

  describe "Nous.generate_text/3 with fallback" do
    test "falls back on provider error" do
      FallbackMockDispatcher.configure(fail_providers: [:openai])

      capture_log(fn ->
        {:ok, text} =
          Nous.generate_text("openai:gpt-4", "Hello",
            fallback: ["anthropic:claude-sonnet-4-20250514"]
          )

        assert text =~ "anthropic:claude-sonnet-4-20250514"
      end)

      calls = FallbackMockDispatcher.get_calls()
      assert [{:openai, "gpt-4"}, {:anthropic, "claude-sonnet-4-20250514"}] = calls
    end

    test "uses primary when it succeeds" do
      FallbackMockDispatcher.configure(fail_providers: [])

      capture_log(fn ->
        {:ok, text} =
          Nous.generate_text("openai:gpt-4", "Hello",
            fallback: ["anthropic:claude-sonnet-4-20250514"]
          )

        assert text =~ "openai:gpt-4"
      end)

      calls = FallbackMockDispatcher.get_calls()
      assert [{:openai, "gpt-4"}] = calls
    end

    test "works without fallback option (backward compatible)" do
      FallbackMockDispatcher.configure(fail_providers: [])

      capture_log(fn ->
        {:ok, text} = Nous.generate_text("openai:gpt-4", "Hello")
        assert text =~ "openai:gpt-4"
      end)
    end
  end

  describe "Nous.stream_text/3 with fallback" do
    test "falls back on provider error" do
      FallbackMockDispatcher.configure(fail_providers: [:openai])

      capture_log(fn ->
        {:ok, stream} =
          Nous.stream_text("openai:gpt-4", "Hello",
            fallback: ["anthropic:claude-sonnet-4-20250514"]
          )

        text = Enum.join(stream)
        assert text =~ "anthropic:claude-sonnet-4-20250514"
      end)
    end

    test "uses primary when it succeeds" do
      FallbackMockDispatcher.configure(fail_providers: [])

      capture_log(fn ->
        {:ok, stream} =
          Nous.stream_text("openai:gpt-4", "Hello",
            fallback: ["anthropic:claude-sonnet-4-20250514"]
          )

        text = Enum.join(stream)
        assert text =~ "openai:gpt-4"
      end)
    end
  end

  describe "telemetry integration" do
    test "emits fallback:activated when falling back in agent run" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:nous, :fallback, :activated]])
      FallbackMockDispatcher.configure(fail_providers: [:openai])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514"]
        )

      capture_log(fn ->
        {:ok, _result} = AgentRunner.run(agent, "Hello")
      end)

      assert_received {[:nous, :fallback, :activated], ^ref, %{system_time: _},
                       %{
                         failed_provider: :openai,
                         failed_model: "gpt-4",
                         next_provider: :anthropic,
                         next_model: "claude-sonnet-4-20250514"
                       }}
    end

    test "does not emit fallback telemetry when primary succeeds" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:nous, :fallback, :activated]])
      FallbackMockDispatcher.configure(fail_providers: [])

      agent =
        Agent.new("openai:gpt-4",
          fallback: ["anthropic:claude-sonnet-4-20250514"]
        )

      capture_log(fn ->
        {:ok, _result} = AgentRunner.run(agent, "Hello")
      end)

      refute_received {[:nous, :fallback, :activated], ^ref, _, _}
    end
  end
end
