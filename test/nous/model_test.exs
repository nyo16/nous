defmodule Nous.ModelTest do
  use ExUnit.Case, async: true

  alias Nous.Model

  doctest Model

  describe "new/3" do
    test "creates model with required fields" do
      model = Model.new(:openai, "gpt-4")

      assert model.provider == :openai
      assert model.model == "gpt-4"
    end

    test "uses default base_url for known providers" do
      openai = Model.new(:openai, "gpt-4")
      assert openai.base_url == "https://api.openai.com/v1"

      groq = Model.new(:groq, "llama-3.1-70b-versatile")
      assert groq.base_url == "https://api.groq.com/openai/v1"

      mistral = Model.new(:mistral, "mistral-large-latest")
      assert mistral.base_url == "https://api.mistral.ai/v1"

      ollama = Model.new(:ollama, "llama2")
      assert ollama.base_url == "http://localhost:11434/v1"

      lmstudio = Model.new(:lmstudio, "qwen3")
      assert lmstudio.base_url == "http://localhost:1234/v1"
    end

    test "uses default api_key from config for known providers" do
      # Note: In tests, these will be nil unless set in config
      openai = Model.new(:openai, "gpt-4")
      assert is_binary(openai.api_key) || is_nil(openai.api_key)

      # Local providers have placeholder keys
      ollama = Model.new(:ollama, "llama2")
      assert ollama.api_key == "ollama"

      lmstudio = Model.new(:lmstudio, "qwen3")
      assert lmstudio.api_key == "not-needed"
    end

    test "allows overriding base_url" do
      model = Model.new(:openai, "gpt-4", base_url: "https://custom.com/v1")

      assert model.base_url == "https://custom.com/v1"
    end

    test "allows overriding api_key" do
      model = Model.new(:openai, "gpt-4", api_key: "sk-custom")

      assert model.api_key == "sk-custom"
    end

    test "accepts organization option" do
      model = Model.new(:openai, "gpt-4", organization: "org-123")

      assert model.organization == "org-123"
    end

    test "accepts default_settings" do
      settings = %{temperature: 0.7, max_tokens: 1000}
      model = Model.new(:openai, "gpt-4", default_settings: settings)

      assert model.default_settings == settings
    end

    test "accepts all options together" do
      model =
        Model.new(:openai, "gpt-4",
          base_url: "https://custom.com/v1",
          api_key: "sk-custom",
          organization: "org-123",
          default_settings: %{temperature: 0.5}
        )

      assert model.provider == :openai
      assert model.model == "gpt-4"
      assert model.base_url == "https://custom.com/v1"
      assert model.api_key == "sk-custom"
      assert model.organization == "org-123"
      assert model.default_settings == %{temperature: 0.5}
    end
  end

  describe "to_client/1" do
    test "creates OpenaiEx client with model config" do
      model = Model.new(:openai, "gpt-4", api_key: "sk-test")

      client = Model.to_client(model)

      assert %OpenaiEx{} = client
      assert client.token == "sk-test"
      assert client.base_url == "https://api.openai.com/v1"
    end

    test "includes organization when set" do
      model = Model.new(:openai, "gpt-4", api_key: "sk-test", organization: "org-123")

      client = Model.to_client(model)

      assert client.organization == "org-123"
    end

    test "configures http options from application config" do
      model = Model.new(:groq, "llama-3.1-70b-versatile", api_key: "gsk-test")

      client = Model.to_client(model)

      assert client.finch_name == Nous.Finch
      assert is_integer(client.receive_timeout)
    end
  end
end
