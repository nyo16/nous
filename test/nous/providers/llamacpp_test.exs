if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.Providers.LlamaCppTest do
    # The provider's option checks run before any llama.cpp call, so they need
    # no model on disk: each case below would otherwise reach LlamaCppEx, which
    # raises ArgumentError (crashing the run) on these inputs. The real model
    # round trips live in llamacpp_smoke_test.exs (`--only llama`).
    use ExUnit.Case, async: true

    alias Nous.Errors.ConfigurationError
    alias Nous.Providers.LlamaCpp

    @tool %{
      "type" => "function",
      "function" => %{
        "name" => "get_weather",
        "description" => "Get the weather",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    }

    # Never handed to llama.cpp: every case errors before the NIF is called.
    @model Nous.Model.parse("llamacpp:local", llamacpp_model: :not_a_loaded_model)
    @messages [Nous.Message.user("hi")]

    defp both_paths(settings) do
      [
        LlamaCpp.request(@model, @messages, settings),
        LlamaCpp.request_stream(@model, @messages, settings)
      ]
    end

    test "a JSON schema together with tools is a ConfigurationError" do
      settings = %{tools: [@tool], json_schema: %{"type" => "object"}}

      for result <- both_paths(settings) do
        assert {:error, %ConfigurationError{message: message}} = result
        assert message =~ "while tools are offered"
      end
    end

    test "tool_choice \"none\" lets a JSON schema through with tools" do
      # llama.cpp leaves the tools out of the prompt then, so no tool-call
      # grammar competes with the schema's. The option checks pass and the
      # call goes on to dispatch, where the fake model reference (read as a
      # server name) fails as a ProviderError, not a ConfigurationError.
      settings = %{tools: [@tool], tool_choice: "none", json_schema: %{"type" => "object"}}

      assert {:error, %Nous.Errors.ProviderError{provider: :llamacpp}} =
               LlamaCpp.request(@model, @messages, settings)
    end

    test "an invalid tool_choice is a ConfigurationError" do
      for result <- both_paths(%{tools: [@tool], tool_choice: "sometimes"}) do
        assert {:error, %ConfigurationError{message: message}} = result
        assert message =~ "invalid :tool_choice"
      end
    end

    test "tools that are not a list of tool maps are a ConfigurationError" do
      for tools <- ["get_weather", [@tool, "get_weather"], [%Nous.Usage{}]],
          result <- both_paths(%{tools: tools}) do
        assert {:error, %ConfigurationError{message: message}} = result
        assert message =~ "must be a list of OpenAI-shaped tool maps"
      end
    end
  end
end
