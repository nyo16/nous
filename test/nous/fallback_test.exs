defmodule Nous.FallbackTest do
  use ExUnit.Case, async: true

  alias Nous.{Fallback, Model, Errors}

  describe "fallback_eligible?/1" do
    test "returns true for ProviderError" do
      error = Errors.ProviderError.exception(message: "rate limited", provider: :openai)
      assert Fallback.fallback_eligible?(error)
    end

    test "returns true for ModelError" do
      error = Errors.ModelError.exception(message: "model not found", provider: :openai)
      assert Fallback.fallback_eligible?(error)
    end

    test "returns false for ValidationError" do
      error = Errors.ValidationError.exception(message: "invalid output")
      refute Fallback.fallback_eligible?(error)
    end

    test "returns false for MaxIterationsExceeded" do
      error = Errors.MaxIterationsExceeded.exception(max_iterations: 10)
      refute Fallback.fallback_eligible?(error)
    end

    test "returns false for ExecutionCancelled" do
      error = Errors.ExecutionCancelled.exception(reason: "user cancelled")
      refute Fallback.fallback_eligible?(error)
    end

    test "returns false for ToolError" do
      error = Errors.ToolError.exception(tool_name: "search")
      refute Fallback.fallback_eligible?(error)
    end

    test "returns false for ToolTimeout" do
      error = Errors.ToolTimeout.exception(tool_name: "search", timeout: 5000)
      refute Fallback.fallback_eligible?(error)
    end

    test "returns false for UsageLimitExceeded" do
      error = Errors.UsageLimitExceeded.exception(limit_type: :tokens)
      refute Fallback.fallback_eligible?(error)
    end

    test "returns false for ConfigurationError" do
      error = Errors.ConfigurationError.exception(message: "missing key")
      refute Fallback.fallback_eligible?(error)
    end

    test "returns false for plain strings" do
      refute Fallback.fallback_eligible?("some error")
    end

    test "returns false for atoms" do
      refute Fallback.fallback_eligible?(:timeout)
    end

    test "returns false for RuntimeError" do
      refute Fallback.fallback_eligible?(%RuntimeError{message: "oops"})
    end
  end

  describe "with_fallback/3" do
    test "returns success from first model when it succeeds" do
      models = [
        Model.new(:openai, "gpt-4"),
        Model.new(:anthropic, "claude-sonnet-4-20250514")
      ]

      result =
        Fallback.with_fallback(models, fn model ->
          {:ok, "response from #{model.provider}:#{model.model}"}
        end)

      assert {:ok, "response from openai:gpt-4"} = result
    end

    test "falls back to second model on ProviderError" do
      models = [
        Model.new(:openai, "gpt-4"),
        Model.new(:anthropic, "claude-sonnet-4-20250514")
      ]

      calls = :counters.new(1, [:atomics])

      result =
        Fallback.with_fallback(models, fn model ->
          count = :counters.get(calls, 1)
          :counters.add(calls, 1, 1)

          if count == 0 do
            {:error, Errors.ProviderError.exception(message: "rate limited")}
          else
            {:ok, "response from #{model.provider}:#{model.model}"}
          end
        end)

      assert {:ok, "response from anthropic:claude-sonnet-4-20250514"} = result
      assert :counters.get(calls, 1) == 2
    end

    test "falls back to second model on ModelError" do
      models = [
        Model.new(:openai, "nonexistent-model"),
        Model.new(:openai, "gpt-4")
      ]

      calls = :counters.new(1, [:atomics])

      result =
        Fallback.with_fallback(models, fn model ->
          count = :counters.get(calls, 1)
          :counters.add(calls, 1, 1)

          if count == 0 do
            {:error, Errors.ModelError.exception(message: "model not found")}
          else
            {:ok, "response from #{model.model}"}
          end
        end)

      assert {:ok, "response from gpt-4"} = result
    end

    test "tries all models in chain until one succeeds" do
      models = [
        Model.new(:openai, "model-a"),
        Model.new(:openai, "model-b"),
        Model.new(:openai, "model-c")
      ]

      calls = :counters.new(1, [:atomics])

      result =
        Fallback.with_fallback(models, fn model ->
          count = :counters.get(calls, 1)
          :counters.add(calls, 1, 1)

          if count < 2 do
            {:error, Errors.ProviderError.exception(message: "fail #{count}")}
          else
            {:ok, "response from #{model.model}"}
          end
        end)

      assert {:ok, "response from model-c"} = result
      assert :counters.get(calls, 1) == 3
    end

    test "returns last error when all models fail with eligible errors" do
      models = [
        Model.new(:openai, "model-a"),
        Model.new(:openai, "model-b")
      ]

      result =
        Fallback.with_fallback(models, fn model ->
          {:error, Errors.ProviderError.exception(message: "fail for #{model.model}")}
        end)

      assert {:error, %Errors.ProviderError{message: "fail for model-b"}} = result
    end

    test "does not fallback on non-eligible errors" do
      models = [
        Model.new(:openai, "gpt-4"),
        Model.new(:anthropic, "claude-sonnet-4-20250514")
      ]

      calls = :counters.new(1, [:atomics])

      result =
        Fallback.with_fallback(models, fn _model ->
          :counters.add(calls, 1, 1)
          {:error, Errors.ValidationError.exception(message: "invalid")}
        end)

      assert {:error, %Errors.ValidationError{}} = result
      # Should only have tried the first model
      assert :counters.get(calls, 1) == 1
    end

    test "does not fallback on MaxIterationsExceeded" do
      models = [
        Model.new(:openai, "gpt-4"),
        Model.new(:anthropic, "claude-sonnet-4-20250514")
      ]

      calls = :counters.new(1, [:atomics])

      result =
        Fallback.with_fallback(models, fn _model ->
          :counters.add(calls, 1, 1)
          {:error, Errors.MaxIterationsExceeded.exception(max_iterations: 10)}
        end)

      assert {:error, %Errors.MaxIterationsExceeded{}} = result
      assert :counters.get(calls, 1) == 1
    end

    test "does not fallback on ExecutionCancelled" do
      models = [
        Model.new(:openai, "gpt-4"),
        Model.new(:anthropic, "claude-sonnet-4-20250514")
      ]

      calls = :counters.new(1, [:atomics])

      result =
        Fallback.with_fallback(models, fn _model ->
          :counters.add(calls, 1, 1)
          {:error, Errors.ExecutionCancelled.exception(reason: "cancelled")}
        end)

      assert {:error, %Errors.ExecutionCancelled{}} = result
      assert :counters.get(calls, 1) == 1
    end

    test "works with single model (no fallback)" do
      models = [Model.new(:openai, "gpt-4")]

      result =
        Fallback.with_fallback(models, fn _model ->
          {:ok, "response"}
        end)

      assert {:ok, "response"} = result
    end

    test "single model returns error directly" do
      models = [Model.new(:openai, "gpt-4")]

      result =
        Fallback.with_fallback(models, fn _model ->
          {:error, Errors.ProviderError.exception(message: "fail")}
        end)

      assert {:error, %Errors.ProviderError{}} = result
    end

    test "returns ConfigurationError for empty model list" do
      result = Fallback.with_fallback([], fn _model -> {:ok, "never called"} end)

      assert {:error, %Errors.ConfigurationError{}} = result
    end

    test "emits telemetry on fallback activation" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:nous, :fallback, :activated]])

      models = [
        Model.new(:openai, "gpt-4"),
        Model.new(:anthropic, "claude-sonnet-4-20250514")
      ]

      calls = :counters.new(1, [:atomics])

      Fallback.with_fallback(models, fn model ->
        count = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)

        if count == 0 do
          {:error, Errors.ProviderError.exception(message: "rate limited")}
        else
          {:ok, "response from #{model.model}"}
        end
      end)

      assert_received {[:nous, :fallback, :activated], ^ref, %{system_time: _},
                       %{
                         failed_provider: :openai,
                         failed_model: "gpt-4",
                         next_provider: :anthropic,
                         next_model: "claude-sonnet-4-20250514",
                         reason: %Errors.ProviderError{}
                       }}
    end

    test "emits multiple telemetry events when falling through chain" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:nous, :fallback, :activated]])

      models = [
        Model.new(:openai, "model-a"),
        Model.new(:anthropic, "model-b"),
        Model.new(:groq, "model-c")
      ]

      calls = :counters.new(1, [:atomics])

      Fallback.with_fallback(models, fn model ->
        count = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)

        if count < 2 do
          {:error, Errors.ProviderError.exception(message: "fail")}
        else
          {:ok, "response from #{model.model}"}
        end
      end)

      # First fallback: model-a -> model-b
      assert_received {[:nous, :fallback, :activated], ^ref, _,
                       %{failed_provider: :openai, next_provider: :anthropic}}

      # Second fallback: model-b -> model-c
      assert_received {[:nous, :fallback, :activated], ^ref, _,
                       %{failed_provider: :anthropic, next_provider: :groq}}
    end
  end

  describe "parse_fallback_models/2" do
    test "parses model strings into Model structs" do
      models =
        Fallback.parse_fallback_models(["openai:gpt-4", "anthropic:claude-sonnet-4-20250514"])

      assert [%Model{provider: :openai, model: "gpt-4"}, %Model{provider: :anthropic}] = models
    end

    test "passes through existing Model structs" do
      existing = Model.new(:openai, "gpt-4")
      models = Fallback.parse_fallback_models([existing, "anthropic:claude-sonnet-4-20250514"])

      assert [^existing, %Model{provider: :anthropic}] = models
    end

    test "handles mixed strings and structs" do
      existing = Model.new(:groq, "llama-3.1-70b-versatile")

      models =
        Fallback.parse_fallback_models([
          "openai:gpt-4",
          existing,
          "anthropic:claude-sonnet-4-20250514"
        ])

      assert [%Model{provider: :openai}, ^existing, %Model{provider: :anthropic}] = models
    end

    test "returns empty list for empty input" do
      assert [] = Fallback.parse_fallback_models([])
    end
  end

  describe "build_model_chain/2" do
    test "prepends primary to fallbacks" do
      primary = Model.new(:openai, "gpt-4")

      fallbacks = [
        Model.new(:anthropic, "claude-sonnet-4-20250514"),
        Model.new(:groq, "llama-3.1-70b")
      ]

      chain = Fallback.build_model_chain(primary, fallbacks)

      assert [^primary | ^fallbacks] = chain
      assert length(chain) == 3
    end

    test "returns single-element list when no fallbacks" do
      primary = Model.new(:openai, "gpt-4")

      chain = Fallback.build_model_chain(primary, [])

      assert [^primary] = chain
    end
  end
end
