defmodule Nous.ModelDispatcherTest do
  use ExUnit.Case, async: true

  alias Nous.ModelDispatcher
  alias Nous.Providers

  describe "provider_module/1" do
    test "routes each known provider to its module" do
      assert ModelDispatcher.provider_module(:anthropic) == Providers.Anthropic
      assert ModelDispatcher.provider_module(:gemini) == Providers.Gemini
      assert ModelDispatcher.provider_module(:vertex_ai) == Providers.VertexAI
      assert ModelDispatcher.provider_module(:mistral) == Providers.Mistral
      assert ModelDispatcher.provider_module(:lmstudio) == Providers.LMStudio
      assert ModelDispatcher.provider_module(:llamacpp) == Providers.LlamaCpp
      assert ModelDispatcher.provider_module(:vllm) == Providers.VLLM
      assert ModelDispatcher.provider_module(:sglang) == Providers.SGLang
      assert ModelDispatcher.provider_module(:openai) == Providers.OpenAI
      assert ModelDispatcher.provider_module(:custom) == Providers.Custom
    end

    test "unknown providers fall back to OpenAICompatible" do
      assert ModelDispatcher.provider_module(:groq) == Providers.OpenAICompatible
      assert ModelDispatcher.provider_module(:something_new) == Providers.OpenAICompatible
    end

    test "every routed module exports the dispatched functions" do
      for provider <- [
            :anthropic,
            :gemini,
            :vertex_ai,
            :mistral,
            :lmstudio,
            :llamacpp,
            :vllm,
            :sglang,
            :openai,
            :custom,
            :unknown_fallback
          ] do
        module = ModelDispatcher.provider_module(provider)
        Code.ensure_loaded!(module)

        assert function_exported?(module, :request, 3),
               "#{inspect(module)} should export request/3"

        assert function_exported?(module, :request_stream, 3),
               "#{inspect(module)} should export request_stream/3"

        assert function_exported?(module, :count_tokens, 1),
               "#{inspect(module)} should export count_tokens/1"
      end
    end
  end
end
