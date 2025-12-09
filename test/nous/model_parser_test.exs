defmodule Nous.ModelParserTest do
  use ExUnit.Case, async: true

  alias Nous.{Model, ModelParser}

  doctest ModelParser

  describe "parse/2" do
    test "parses openai format" do
      model = ModelParser.parse("openai:gpt-4")

      assert model.provider == :openai
      assert model.model == "gpt-4"
      assert model.base_url == "https://api.openai.com/v1"
    end

    test "parses groq format" do
      model = ModelParser.parse("groq:llama-3.1-70b-versatile")

      assert model.provider == :groq
      assert model.model == "llama-3.1-70b-versatile"
      assert model.base_url == "https://api.groq.com/openai/v1"
    end

    test "parses ollama format" do
      model = ModelParser.parse("ollama:llama2")

      assert model.provider == :ollama
      assert model.model == "llama2"
      assert model.base_url == "http://localhost:11434/v1"
      assert model.api_key == "ollama"
    end

    test "parses lmstudio format" do
      model = ModelParser.parse("lmstudio:qwen/qwen3-30b-a3b-2507")

      assert model.provider == :lmstudio
      assert model.model == "qwen/qwen3-30b-a3b-2507"
      assert model.base_url == "http://localhost:1234/v1"
      assert model.api_key == "not-needed"
    end

    test "parses openrouter format" do
      model = ModelParser.parse("openrouter:anthropic/claude-3.5-sonnet")

      assert model.provider == :openrouter
      assert model.model == "anthropic/claude-3.5-sonnet"
      assert model.base_url == "https://openrouter.ai/api/v1"
    end

    test "parses together format" do
      model = ModelParser.parse("together:meta-llama/Llama-3-70b-chat-hf")

      assert model.provider == :together
      assert model.model == "meta-llama/Llama-3-70b-chat-hf"
      assert model.base_url == "https://api.together.xyz/v1"
    end

    test "parses mistral format" do
      model = ModelParser.parse("mistral:mistral-large-latest")

      assert model.provider == :mistral
      assert model.model == "mistral-large-latest"
      assert model.base_url == "https://api.mistral.ai/v1"
      assert model.api_key == nil  # Will be loaded from config
    end

    test "parses custom format with base_url" do
      model =
        ModelParser.parse("custom:my-model",
          base_url: "https://my-server.com/v1",
          api_key: "my-key"
        )

      assert model.provider == :custom
      assert model.model == "my-model"
      assert model.base_url == "https://my-server.com/v1"
      assert model.api_key == "my-key"
    end

    test "raises on custom format without base_url" do
      assert_raise ArgumentError, ~r/custom provider requires :base_url/, fn ->
        ModelParser.parse("custom:my-model")
      end
    end

    test "raises on invalid format" do
      assert_raise ArgumentError, ~r/Invalid model string format/, fn ->
        ModelParser.parse("invalid-format")
      end
    end

    test "raises on unsupported provider" do
      assert_raise ArgumentError, ~r/Invalid model string format/, fn ->
        ModelParser.parse("unsupported:model")
      end
    end

    test "handles model names with special characters" do
      model = ModelParser.parse("openai:gpt-4-0125-preview")
      assert model.model == "gpt-4-0125-preview"

      model = ModelParser.parse("ollama:llama2:13b")
      assert model.model == "llama2:13b"

      model = ModelParser.parse("lmstudio:qwen/qwen3-30b-a3b-2507")
      assert model.model == "qwen/qwen3-30b-a3b-2507"
    end

    test "accepts override options" do
      model =
        ModelParser.parse("openai:gpt-4",
          base_url: "https://custom.com/v1",
          api_key: "sk-custom",
          default_settings: %{temperature: 0.9}
        )

      assert model.base_url == "https://custom.com/v1"
      assert model.api_key == "sk-custom"
      assert model.default_settings == %{temperature: 0.9}
    end
  end
end
