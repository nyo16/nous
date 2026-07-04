defmodule Nous.ErrorsTest do
  use ExUnit.Case, async: true

  alias Nous.Errors

  # Characterization tests for exception construction: every exception must
  # accept a keyword list (fields + optional :message override) and a bare
  # binary message. Default messages are part of the public error surface.

  describe "ConfigurationError" do
    test "keyword construction with default message" do
      e = Errors.ConfigurationError.exception(details: :missing_dep)
      assert e.message == "Configuration error"
      assert e.details == :missing_dep
    end

    test "binary construction" do
      assert Errors.ConfigurationError.exception("nope").message == "nope"
    end
  end

  describe "ModelError" do
    test "default message includes provider and status" do
      e = Errors.ModelError.exception(provider: :openai, status_code: 500, details: %{})
      assert e.message == "Model request failed (openai) [500]"
      assert e.provider == :openai
      assert e.status_code == 500
    end

    test "explicit message wins" do
      assert Errors.ModelError.exception(message: "custom", provider: :x).message == "custom"
    end

    test "binary construction" do
      assert Errors.ModelError.exception("boom").message == "boom"
    end
  end

  describe "ProviderError" do
    test "default message and fields" do
      e =
        Errors.ProviderError.exception(
          provider: :vertex_ai,
          status_code: 429,
          retry_after_ms: 1000,
          details: %{"error" => "quota"}
        )

      assert e.message == "Provider request failed (vertex_ai) [429]"
      assert e.retry_after_ms == 1000
      assert e.details == %{"error" => "quota"}
    end

    test "binary construction" do
      assert Errors.ProviderError.exception("down").message == "down"
    end
  end

  describe "ToolError" do
    test "default message includes tool name and attempts" do
      e = Errors.ToolError.exception(tool_name: "search", attempt: 3, original_error: :oops)
      assert e.message == "Tool execution failed (search) after 3 attempt(s)"
      assert e.original_error == :oops
    end

    test "binary construction" do
      assert Errors.ToolError.exception("bad tool").message == "bad tool"
    end
  end

  describe "ToolTimeout" do
    test "default message includes tool name and timeout" do
      e = Errors.ToolTimeout.exception(tool_name: "slow", timeout: 5000)
      assert e.message == "Tool 'slow' timed out after 5000ms"
    end

    test "default message tolerates missing fields" do
      assert Errors.ToolTimeout.exception([]).message == "Tool 'unknown' timed out after 0ms"
    end

    test "binary construction" do
      assert Errors.ToolTimeout.exception("timeout").message == "timeout"
    end
  end

  describe "ValidationError" do
    test "default message includes output type" do
      e = Errors.ValidationError.exception(output_type: MySchema, errors: [name: "required"])
      assert e.message == "Output validation failed for MySchema"
      assert e.errors == [name: "required"]
    end

    test "binary construction" do
      assert Errors.ValidationError.exception("invalid").message == "invalid"
    end
  end

  describe "UsageLimitExceeded" do
    test "default message includes limit comparison" do
      e =
        Errors.UsageLimitExceeded.exception(
          limit_type: :tokens,
          limit_value: 100,
          actual_value: 150
        )

      assert e.message == "Usage limit exceeded (tokens): 150 > 100"
    end

    test "binary construction" do
      assert Errors.UsageLimitExceeded.exception("over").message == "over"
    end
  end

  describe "MaxIterationsExceeded" do
    test "default message includes the limit" do
      e = Errors.MaxIterationsExceeded.exception(max_iterations: 5)
      assert e.message == "Maximum iterations exceeded (5)"
      assert e.max_iterations == 5
    end

    test "binary construction" do
      assert Errors.MaxIterationsExceeded.exception("looped").message == "looped"
    end
  end

  describe "ExecutionCancelled" do
    test "default message includes reason" do
      e = Errors.ExecutionCancelled.exception(reason: "user abort")
      assert e.message == "Execution cancelled: user abort"
    end

    test "binary construction" do
      assert Errors.ExecutionCancelled.exception("stop").message == "stop"
    end
  end

  describe "raise compatibility" do
    test "exceptions raise with keyword opts" do
      assert_raise Errors.ProviderError, "Provider request failed (openai) [500]", fn ->
        raise Errors.ProviderError, provider: :openai, status_code: 500
      end
    end

    test "exceptions raise with a bare message" do
      assert_raise Errors.ToolError, "kaput", fn ->
        raise Errors.ToolError, "kaput"
      end
    end
  end
end
