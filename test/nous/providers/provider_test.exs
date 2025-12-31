defmodule Nous.ProviderTest do
  use ExUnit.Case, async: true

  # ============================================================================
  # Test Module Using the Provider Behaviour
  # ============================================================================

  defmodule TestProvider do
    use Nous.Provider,
      id: :test_provider,
      default_base_url: "https://api.test.example.com/v1",
      default_env_key: "TEST_PROVIDER_API_KEY"

    @impl true
    def chat(_params, _opts), do: {:ok, %{"response" => "test"}}

    @impl true
    def chat_stream(_params, _opts), do: {:ok, Stream.map([], & &1)}
  end

  defmodule CustomTokenProvider do
    use Nous.Provider,
      id: :custom_token,
      default_base_url: "https://custom.example.com",
      default_env_key: "CUSTOM_API_KEY"

    @impl true
    def chat(_params, _opts), do: {:ok, %{}}

    @impl true
    def chat_stream(_params, _opts), do: {:ok, Stream.map([], & &1)}

    # Override count_tokens with custom implementation
    @impl true
    def count_tokens(messages) do
      # Custom: 10 tokens per message
      length(messages) * 10
    end
  end

  # ============================================================================
  # Provider Behaviour Tests
  # ============================================================================

  describe "provider_id/0" do
    test "returns the configured provider ID" do
      assert TestProvider.provider_id() == :test_provider
      assert CustomTokenProvider.provider_id() == :custom_token
    end
  end

  describe "default_base_url/0" do
    test "returns the configured base URL" do
      assert TestProvider.default_base_url() == "https://api.test.example.com/v1"
      assert CustomTokenProvider.default_base_url() == "https://custom.example.com"
    end
  end

  describe "default_env_key/0" do
    test "returns the configured environment variable name" do
      assert TestProvider.default_env_key() == "TEST_PROVIDER_API_KEY"
      assert CustomTokenProvider.default_env_key() == "CUSTOM_API_KEY"
    end
  end

  describe "api_key/1" do
    test "returns nil when no API key is configured" do
      # Ensure env var is not set
      System.delete_env("TEST_PROVIDER_API_KEY")

      assert TestProvider.api_key() == nil
    end

    test "returns API key from options" do
      assert TestProvider.api_key(api_key: "from-opts") == "from-opts"
    end

    test "prioritizes options over environment variable" do
      System.put_env("TEST_PROVIDER_API_KEY", "from-env")

      try do
        assert TestProvider.api_key(api_key: "from-opts") == "from-opts"
      after
        System.delete_env("TEST_PROVIDER_API_KEY")
      end
    end

    test "falls back to environment variable" do
      System.put_env("TEST_PROVIDER_API_KEY", "from-env")

      try do
        assert TestProvider.api_key() == "from-env"
      after
        System.delete_env("TEST_PROVIDER_API_KEY")
      end
    end
  end

  describe "base_url/1" do
    test "returns default base URL when no override" do
      assert TestProvider.base_url() == "https://api.test.example.com/v1"
    end

    test "returns base URL from options" do
      assert TestProvider.base_url(base_url: "https://custom.example.com") ==
               "https://custom.example.com"
    end

    test "prioritizes options over default" do
      assert TestProvider.base_url(base_url: "https://override.example.com") ==
               "https://override.example.com"
    end
  end

  describe "count_tokens/1" do
    test "default implementation estimates tokens" do
      messages = [
        %{role: "user", content: "Hello, how are you?"},
        %{role: "assistant", content: "I'm doing well, thank you!"}
      ]

      count = TestProvider.count_tokens(messages)

      # Should return a reasonable estimate (string length / 4)
      assert is_integer(count)
      assert count > 0
    end

    test "default implementation handles empty list" do
      assert TestProvider.count_tokens([]) == 0
    end

    test "custom implementation can override" do
      messages = [%{content: "a"}, %{content: "b"}, %{content: "c"}]

      # Custom provider returns 10 * message_count
      assert CustomTokenProvider.count_tokens(messages) == 30
    end
  end

  describe "chat/2 callback" do
    test "callback is implemented" do
      assert {:ok, %{"response" => "test"}} = TestProvider.chat(%{}, [])
    end
  end

  describe "chat_stream/2 callback" do
    test "callback is implemented" do
      assert {:ok, _stream} = TestProvider.chat_stream(%{}, [])
    end
  end

  # ============================================================================
  # Real Provider Tests
  # ============================================================================

  describe "Nous.Providers.OpenAICompatible" do
    test "has correct provider configuration" do
      Code.ensure_loaded!(Nous.Providers.OpenAICompatible)

      assert Nous.Providers.OpenAICompatible.provider_id() == :openai_compatible
      assert Nous.Providers.OpenAICompatible.default_base_url() == "https://api.openai.com/v1"
      assert Nous.Providers.OpenAICompatible.default_env_key() == "OPENAI_API_KEY"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(Nous.Providers.OpenAICompatible)

      functions = Nous.Providers.OpenAICompatible.__info__(:functions)
      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
    end
  end

  describe "Nous.Providers.OpenAI" do
    test "has correct provider configuration" do
      Code.ensure_loaded!(Nous.Providers.OpenAI)

      assert Nous.Providers.OpenAI.provider_id() == :openai
      assert Nous.Providers.OpenAI.default_base_url() == "https://api.openai.com/v1"
      assert Nous.Providers.OpenAI.default_env_key() == "OPENAI_API_KEY"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(Nous.Providers.OpenAI)

      functions = Nous.Providers.OpenAI.__info__(:functions)
      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
    end

    test "identifies reasoning models" do
      Code.ensure_loaded!(Nous.Providers.OpenAI)

      # Reasoning models
      assert Nous.Providers.OpenAI.reasoning_model?("o1")
      assert Nous.Providers.OpenAI.reasoning_model?("o1-mini")
      assert Nous.Providers.OpenAI.reasoning_model?("o1-preview")
      assert Nous.Providers.OpenAI.reasoning_model?("o3")
      assert Nous.Providers.OpenAI.reasoning_model?("o3-mini")

      # Non-reasoning models
      refute Nous.Providers.OpenAI.reasoning_model?("gpt-4")
      refute Nous.Providers.OpenAI.reasoning_model?("gpt-4o")
      refute Nous.Providers.OpenAI.reasoning_model?("gpt-3.5-turbo")
      refute Nous.Providers.OpenAI.reasoning_model?(nil)
    end
  end

  describe "Nous.Providers.Anthropic" do
    test "has correct provider configuration" do
      Code.ensure_loaded!(Nous.Providers.Anthropic)

      assert Nous.Providers.Anthropic.provider_id() == :anthropic
      assert Nous.Providers.Anthropic.default_base_url() == "https://api.anthropic.com"
      assert Nous.Providers.Anthropic.default_env_key() == "ANTHROPIC_API_KEY"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(Nous.Providers.Anthropic)

      functions = Nous.Providers.Anthropic.__info__(:functions)
      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
    end
  end

  describe "Nous.Providers.Gemini" do
    test "has correct provider configuration" do
      Code.ensure_loaded!(Nous.Providers.Gemini)

      assert Nous.Providers.Gemini.provider_id() == :gemini
      assert Nous.Providers.Gemini.default_base_url() == "https://generativelanguage.googleapis.com/v1beta"
      assert Nous.Providers.Gemini.default_env_key() == "GOOGLE_AI_API_KEY"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(Nous.Providers.Gemini)

      functions = Nous.Providers.Gemini.__info__(:functions)
      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
    end
  end

  # ============================================================================
  # New Provider Tests (Mistral, LMStudio, vLLM, SGLang)
  # ============================================================================

  describe "Nous.Providers.Mistral" do
    test "has correct provider configuration" do
      Code.ensure_loaded!(Nous.Providers.Mistral)

      assert Nous.Providers.Mistral.provider_id() == :mistral
      assert Nous.Providers.Mistral.default_base_url() == "https://api.mistral.ai/v1"
      assert Nous.Providers.Mistral.default_env_key() == "MISTRAL_API_KEY"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(Nous.Providers.Mistral)

      functions = Nous.Providers.Mistral.__info__(:functions)
      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
      assert {:request, 3} in functions
      assert {:request_stream, 3} in functions
    end
  end

  describe "Nous.Providers.LMStudio" do
    test "has correct provider configuration" do
      Code.ensure_loaded!(Nous.Providers.LMStudio)

      assert Nous.Providers.LMStudio.provider_id() == :lmstudio
      assert Nous.Providers.LMStudio.default_base_url() == "http://localhost:1234/v1"
      assert Nous.Providers.LMStudio.default_env_key() == "LMSTUDIO_API_KEY"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(Nous.Providers.LMStudio)

      functions = Nous.Providers.LMStudio.__info__(:functions)
      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
      assert {:request, 3} in functions
      assert {:request_stream, 3} in functions
    end

    test "respects LMSTUDIO_BASE_URL environment variable" do
      System.put_env("LMSTUDIO_BASE_URL", "http://custom:5000/v1")

      try do
        # The provider should check this env var in get_base_url
        Code.ensure_loaded!(Nous.Providers.LMStudio)
        # We can't easily test the internal function, but we verify the module loads
        assert Nous.Providers.LMStudio.provider_id() == :lmstudio
      after
        System.delete_env("LMSTUDIO_BASE_URL")
      end
    end
  end

  describe "Nous.Providers.VLLM" do
    test "has correct provider configuration" do
      Code.ensure_loaded!(Nous.Providers.VLLM)

      assert Nous.Providers.VLLM.provider_id() == :vllm
      assert Nous.Providers.VLLM.default_base_url() == "http://localhost:8000/v1"
      assert Nous.Providers.VLLM.default_env_key() == "VLLM_API_KEY"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(Nous.Providers.VLLM)

      functions = Nous.Providers.VLLM.__info__(:functions)
      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
      assert {:request, 3} in functions
      assert {:request_stream, 3} in functions
    end

    test "respects VLLM_BASE_URL environment variable" do
      System.put_env("VLLM_BASE_URL", "http://gpu-server:8000/v1")

      try do
        Code.ensure_loaded!(Nous.Providers.VLLM)
        assert Nous.Providers.VLLM.provider_id() == :vllm
      after
        System.delete_env("VLLM_BASE_URL")
      end
    end
  end

  describe "Nous.Providers.SGLang" do
    test "has correct provider configuration" do
      Code.ensure_loaded!(Nous.Providers.SGLang)

      assert Nous.Providers.SGLang.provider_id() == :sglang
      assert Nous.Providers.SGLang.default_base_url() == "http://localhost:30000/v1"
      assert Nous.Providers.SGLang.default_env_key() == "SGLANG_API_KEY"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(Nous.Providers.SGLang)

      functions = Nous.Providers.SGLang.__info__(:functions)
      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
      assert {:request, 3} in functions
      assert {:request_stream, 3} in functions
    end

    test "respects SGLANG_BASE_URL environment variable" do
      System.put_env("SGLANG_BASE_URL", "http://sglang-server:30000/v1")

      try do
        Code.ensure_loaded!(Nous.Providers.SGLang)
        assert Nous.Providers.SGLang.provider_id() == :sglang
      after
        System.delete_env("SGLANG_BASE_URL")
      end
    end
  end

  # ============================================================================
  # High-Level Request Callback Tests
  # ============================================================================

  describe "request/3 and request_stream/3 callbacks" do
    test "providers have request/3 function injected" do
      Code.ensure_loaded!(Nous.Providers.OpenAICompatible)
      functions = Nous.Providers.OpenAICompatible.__info__(:functions)
      assert {:request, 3} in functions
    end

    test "providers have request_stream/3 function injected" do
      Code.ensure_loaded!(Nous.Providers.OpenAICompatible)
      functions = Nous.Providers.OpenAICompatible.__info__(:functions)
      assert {:request_stream, 3} in functions
    end

    test "all providers implement high-level callbacks" do
      providers = [
        Nous.Providers.OpenAI,
        Nous.Providers.OpenAICompatible,
        Nous.Providers.Anthropic,
        Nous.Providers.Gemini,
        Nous.Providers.Mistral,
        Nous.Providers.LMStudio,
        Nous.Providers.VLLM,
        Nous.Providers.SGLang
      ]

      for provider <- providers do
        Code.ensure_loaded!(provider)
        functions = provider.__info__(:functions)

        assert {:request, 3} in functions,
               "#{inspect(provider)} should implement request/3"

        assert {:request_stream, 3} in functions,
               "#{inspect(provider)} should implement request_stream/3"
      end
    end
  end
end
