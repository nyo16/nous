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

      gemini = Model.new(:gemini, "gemini-2.0-flash")
      assert gemini.base_url == "https://generativelanguage.googleapis.com/v1beta"
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

    test "sets default receive_timeout based on provider" do
      # Cloud providers get 3 minutes (reasoning models can take a while)
      openai = Model.new(:openai, "gpt-4")
      assert openai.receive_timeout == 180_000

      # LM Studio gets 5 minutes: it JIT-loads a model on the first request that
      # names it, so a cold 27B spends tens of seconds before its first token,
      # and a long tool loop on a large local model outran the previous 2 minutes
      # in practice.
      lmstudio = Model.new(:lmstudio, "qwen3")
      assert lmstudio.receive_timeout == 300_000

      # Other local OpenAI-compatible servers still get 2 minutes.
      ollama = Model.new(:ollama, "llama2")
      assert ollama.receive_timeout == 120_000

      # A local host is never given less headroom than a cloud one.
      assert lmstudio.receive_timeout >= openai.receive_timeout
    end

    test "allows overriding receive_timeout" do
      model = Model.new(:openai, "gpt-4", receive_timeout: 180_000)
      assert model.receive_timeout == 180_000
    end
  end

  describe "new/3 :headers" do
    test "accepts a map or a tuple list and keeps it out of inspect output" do
      from_map = Model.new(:openai, "gpt-4", headers: %{"cf-aig-gateway-id" => "gw"})
      assert from_map.headers == [{"cf-aig-gateway-id", "gw"}]

      model = Model.new(:openai, "gpt-4", headers: [{"cf-aig-authorization", "Bearer secret"}])
      assert model.headers == [{"cf-aig-authorization", "Bearer secret"}]
      refute inspect(model) =~ "secret"
    end

    test "defaults to no extra headers" do
      assert Model.new(:openai, "gpt-4").headers == []
      assert Model.new(:openai, "gpt-4", headers: nil).headers == []
    end

    test "rejects a value that would split the request, without echoing it" do
      error =
        assert_raise ArgumentError, fn ->
          Model.new(:openai, "gpt-4", headers: [{"x-token", "secret\r\nx-evil: 1"}])
        end

      assert error.message =~ "x-token"
      refute error.message =~ "secret"
    end

    test "rejects names that are not HTTP tokens and entries that are not string pairs" do
      assert_raise ArgumentError, ~r/invalid HTTP header name/, fn ->
        Model.new(:openai, "gpt-4", headers: [{"bad name", "v"}])
      end

      assert_raise ArgumentError, ~r/string tuples/, fn ->
        Model.new(:openai, "gpt-4", headers: [{:"x-atom", "v"}])
      end

      assert_raise ArgumentError, ~r/list of \{name, value\} tuples or a map/, fn ->
        Model.new(:openai, "gpt-4", headers: "x-a: b")
      end
    end

    test "parse/2 forwards :headers" do
      model = Model.parse("custom:m", base_url: "https://gw.example/v1", headers: [{"x-a", "1"}])
      assert model.headers == [{"x-a", "1"}]
    end
  end
end
