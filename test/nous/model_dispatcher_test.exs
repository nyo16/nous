defmodule Nous.ModelDispatcherTest do
  # async: false — the precedence ladder below has to prove that the
  # `:nous, :model_dispatcher` application environment is a real (if lower
  # priority) layer, and that means writing it. Every *other* dispatcher-bound
  # suite now uses the process-scoped override and runs async instead.
  use ExUnit.Case, async: false

  alias Nous.ModelDispatcher
  alias Nous.Providers

  defmodule AppEnvDispatcher do
    @moduledoc false
    def request(_model, _messages, _settings), do: {:ok, :app_env}
    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0
  end

  defmodule ProcessDispatcher do
    @moduledoc false
    def request(_model, _messages, _settings), do: {:ok, :process}
    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0
  end

  defmodule ExplicitDispatcher do
    @moduledoc false

    def request(_model, _messages, _settings) do
      {:ok, Nous.Message.assistant("explicit")}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 0
  end

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

  describe "resolve/1 precedence" do
    setup do
      previous = Application.fetch_env(:nous, :model_dispatcher)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:nous, :model_dispatcher, value)
          :error -> Application.delete_env(:nous, :model_dispatcher)
        end
      end)

      :ok
    end

    # One test, walked as a ladder: every rung is a strictly higher-priority
    # layer than the one below it. A refactor that inverts two layers — the
    # classic way this kind of resolver rots — fails here rather than silently
    # sending a test's traffic to a real provider.
    test "explicit option beats process override beats app env beats the default" do
      Application.delete_env(:nous, :model_dispatcher)
      assert ModelDispatcher.resolve() == ModelDispatcher

      Application.put_env(:nous, :model_dispatcher, AppEnvDispatcher)
      assert ModelDispatcher.resolve() == AppEnvDispatcher

      ModelDispatcher.put_dispatcher(ProcessDispatcher)
      assert ModelDispatcher.resolve() == ProcessDispatcher

      assert ModelDispatcher.resolve(ExplicitDispatcher) == ExplicitDispatcher
    end

    test "put_dispatcher(nil) drops back to the app env" do
      Application.put_env(:nous, :model_dispatcher, AppEnvDispatcher)
      ModelDispatcher.put_dispatcher(ProcessDispatcher)
      assert ModelDispatcher.resolve() == ProcessDispatcher

      ModelDispatcher.put_dispatcher(nil)
      assert ModelDispatcher.resolve() == AppEnvDispatcher
    end
  end

  describe "put_dispatcher/1 scope" do
    test "is visible to tasks spawned by the owner, directly and nested" do
      ModelDispatcher.put_dispatcher(ProcessDispatcher)

      assert Task.async(fn -> ModelDispatcher.resolve() end) |> Task.await() ==
               ProcessDispatcher

      nested =
        Task.async(fn ->
          Task.async(fn -> ModelDispatcher.resolve() end) |> Task.await()
        end)

      assert Task.await(nested) == ProcessDispatcher

      assert [ok: ProcessDispatcher] =
               Nous.TaskSupervisor
               |> Task.Supervisor.async_stream_nolink([1], fn _ ->
                 ModelDispatcher.resolve()
               end)
               |> Enum.to_list()
    end

    # The whole point of the seam: an unrelated concurrent process must not be
    # able to observe it. If this ever fails, `async: true` on the dispatcher
    # suites is unsound.
    test "is invisible to a process that is not in the caller chain" do
      ModelDispatcher.put_dispatcher(ProcessDispatcher)

      owner = self()
      spawn(fn -> send(owner, {:resolved, ModelDispatcher.resolve()}) end)

      assert_receive {:resolved, resolved}, 1_000
      refute resolved == ProcessDispatcher
    end

    test "concurrent owners each see their own override" do
      # No sleeps: put_dispatcher/1 writes the caller's own process
      # dictionary, so the assertion holds under full serialisation and the
      # sleeps bought an interleaving nothing here verifies. The real
      # isolation proof is the test above.
      [a, b] =
        Task.await_many([
          Task.async(fn ->
            ModelDispatcher.put_dispatcher(AppEnvDispatcher)
            ModelDispatcher.resolve()
          end),
          Task.async(fn ->
            ModelDispatcher.put_dispatcher(ProcessDispatcher)
            ModelDispatcher.resolve()
          end)
        ])

      assert {a, b} == {AppEnvDispatcher, ProcessDispatcher}
    end
  end

  describe "Nous.LLM :model_dispatcher option" do
    test "the explicit option reaches the request, outranking a process override" do
      ModelDispatcher.put_dispatcher(ProcessDispatcher)

      assert {:ok, "explicit"} =
               Nous.LLM.generate_text("openai:gpt-4", "hi", model_dispatcher: ExplicitDispatcher)
    end
  end
end
