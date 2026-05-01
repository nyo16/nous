defmodule Nous.LLMTest do
  use ExUnit.Case, async: false

  alias Nous.{Model, Message, Usage}

  # Mock dispatcher that captures the model struct passed to it
  defmodule CapturingDispatcher do
    @moduledoc false

    def configure do
      if :ets.whereis(:llm_test_captures) != :undefined do
        :ets.delete(:llm_test_captures)
      end

      :ets.new(:llm_test_captures, [:named_table, :public, :set])
      :ets.insert(:llm_test_captures, {:models, []})
    end

    def get_models do
      [{:models, models}] = :ets.lookup(:llm_test_captures, :models)
      Enum.reverse(models)
    end

    def request(model, _messages, _settings) do
      record(model)

      {:ok,
       %Message{
         role: :assistant,
         content: "ok",
         metadata: %{usage: %Usage{input_tokens: 5, output_tokens: 2, total_tokens: 7}}
       }}
    end

    def request_stream(model, _messages, _settings) do
      record(model)
      {:ok, [{:text_delta, "ok"}, {:finish, "stop"}]}
    end

    defp record(model) do
      [{:models, models}] = :ets.lookup(:llm_test_captures, :models)
      :ets.insert(:llm_test_captures, {:models, [model | models]})
    end
  end

  setup do
    CapturingDispatcher.configure()
    prev = Application.get_env(:nous, :model_dispatcher)
    Application.put_env(:nous, :model_dispatcher, CapturingDispatcher)
    on_exit(fn -> Application.put_env(:nous, :model_dispatcher, prev) end)
    :ok
  end

  describe "generate_text/3 passes receive_timeout to model" do
    test "with string model and receive_timeout option" do
      {:ok, _text} =
        Nous.LLM.generate_text("openai:gpt-4", "hi", receive_timeout: 300_000)

      [model] = CapturingDispatcher.get_models()
      assert model.receive_timeout == 300_000
    end

    test "with string model uses provider default when receive_timeout not given" do
      {:ok, _text} = Nous.LLM.generate_text("openai:gpt-4", "hi")

      [model] = CapturingDispatcher.get_models()
      # OpenAI default is 180_000 (3 minutes, bumped in 0.15.5)
      assert model.receive_timeout == 180_000
    end

    test "with string model for local provider uses its default" do
      {:ok, _text} = Nous.LLM.generate_text("lmstudio:qwen3", "hi")

      [model] = CapturingDispatcher.get_models()
      # LMStudio default is 120_000
      assert model.receive_timeout == 120_000
    end

    test "with %Model{} struct preserves receive_timeout" do
      model = Model.new(:openai, "gpt-4", receive_timeout: 600_000)
      {:ok, _text} = Nous.LLM.generate_text(model, "hi")

      [captured] = CapturingDispatcher.get_models()
      assert captured.receive_timeout == 600_000
    end
  end

  describe "stream_text/3 passes receive_timeout to model" do
    test "with string model and receive_timeout option" do
      {:ok, stream} =
        Nous.LLM.stream_text("openai:gpt-4", "hi", receive_timeout: 300_000)

      # Consume the stream so the request is made
      _chunks = Enum.to_list(stream)

      [model] = CapturingDispatcher.get_models()
      assert model.receive_timeout == 300_000
    end

    test "with string model uses provider default when receive_timeout not given" do
      {:ok, stream} = Nous.LLM.stream_text("openai:gpt-4", "hi")
      _chunks = Enum.to_list(stream)

      [model] = CapturingDispatcher.get_models()
      # OpenAI default is 180_000 (3 minutes, bumped in 0.15.5)
      assert model.receive_timeout == 180_000
    end

    test "with %Model{} struct preserves receive_timeout" do
      model = Model.new(:openai, "gpt-4", receive_timeout: 600_000)
      {:ok, stream} = Nous.LLM.stream_text(model, "hi")
      _chunks = Enum.to_list(stream)

      [captured] = CapturingDispatcher.get_models()
      assert captured.receive_timeout == 600_000
    end
  end
end
