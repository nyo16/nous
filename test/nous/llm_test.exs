defmodule Nous.LLMTest do
  use ExUnit.Case, async: true

  alias Nous.{Model, Message, Usage}

  # Mock dispatcher that captures the model struct passed to it
  defmodule CapturingDispatcher do
    @moduledoc false

    # Process-dictionary state, not a BEAM-global `:named_table`. A table name
    # is a node-wide namespace, `:ets.delete/1` from a non-owner raises, and
    # teardown on owner death is not instantaneous — so the old
    # delete-then-recreate dance had a narrow window against a just-exited test
    # process, in a module that runs async. Nothing here needs to cross a
    # process boundary: Nous.LLM calls the dispatcher inline in the caller, a
    # fact the sibling SettingsCapturingDispatcher below already leans on with
    # `send(self(), _)` + `assert_received`.
    @key {__MODULE__, :models}

    def configure do
      Process.put(@key, [])
      :ok
    end

    def get_models, do: @key |> Process.get([]) |> Enum.reverse()

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

    defp record(model), do: Process.put(@key, [model | Process.get(@key, [])])
  end

  defmodule FailingStreamDispatcher do
    @moduledoc false

    def request(_model, _messages, _settings),
      do: {:error, %Nous.Errors.ModelError{message: "boom", provider: :test}}

    def request_stream(_model, _messages, _settings),
      do: {:error, %Nous.Errors.ModelError{message: "boom", provider: :test}}
  end

  # Captures the settings map handed to the dispatcher, so tests can assert the
  # exact tool-schema wire format Nous.LLM builds per provider.
  defmodule SettingsCapturingDispatcher do
    @moduledoc false

    def request(_model, _messages, settings) do
      send(self(), {:captured_settings, settings})

      {:ok,
       %Message{
         role: :assistant,
         content: "ok",
         metadata: %{usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
       }}
    end

    def request_stream(_model, _messages, settings) do
      send(self(), {:captured_settings, settings})
      {:ok, [{:text_delta, "ok"}, {:finish, "stop"}]}
    end
  end

  setup do
    CapturingDispatcher.configure()
    # Both the dispatcher override and the capture buffer are process-scoped:
    # no global env to restore and no node-wide ETS name to contend for.
    Nous.ModelDispatcher.put_dispatcher(CapturingDispatcher)
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

  describe "stream_text/3 with tools surfaces dispatcher errors" do
    test "emits an {:error, _} event instead of silently halting" do
      # Before fix: stream_text_with_tools silently :halt'd on Fallback error,
      # so the consumer saw a clean empty stream with no signal that the LLM
      # call had failed. Now an {:error, _} event is emitted before halt.
      Nous.ModelDispatcher.put_dispatcher(FailingStreamDispatcher)

      tool = %Nous.Tool{
        name: "noop",
        description: "no-op for test",
        parameters: %{type: "object", properties: %{}},
        function: fn _, _ -> {:ok, "x"} end,
        takes_ctx: false
      }

      {:ok, stream} = Nous.LLM.stream_text("openai:gpt-4", "hi", tools: [tool])
      events = Enum.to_list(stream)

      assert Enum.any?(events, fn
               {:error, _} -> true
               _ -> false
             end),
             "stream should emit an {:error, _} event when the dispatcher fails, got: #{inspect(events)}"
    end
  end

  describe "generate_text/3 tool-schema wire format" do
    setup do
      Nous.ModelDispatcher.put_dispatcher(SettingsCapturingDispatcher)
      :ok
    end

    test "gemini gets bare function declarations, not the OpenAI envelope" do
      tool = sample_tool()

      assert {:ok, "ok"} = Nous.LLM.generate_text("gemini:gemini-2.0-flash", "hi", tools: [tool])

      assert_received {:captured_settings, settings}
      assert settings.tools == [Nous.Tool.Wire.to_gemini(tool)]
    end

    test "vertex_ai gets the same bare function declarations" do
      tool = sample_tool()

      assert {:ok, "ok"} =
               Nous.LLM.generate_text("vertex_ai:gemini-2.0-flash", "hi", tools: [tool])

      assert_received {:captured_settings, settings}
      assert settings.tools == [Nous.Tool.Wire.to_gemini(tool)]
    end

    test "openai gets the OpenAI function envelope" do
      tool = sample_tool()

      assert {:ok, "ok"} = Nous.LLM.generate_text("openai:gpt-4", "hi", tools: [tool])

      assert_received {:captured_settings, settings}
      assert settings.tools == [Nous.Tool.to_openai_schema(tool)]
    end

    test "anthropic gets the atom-keyed input_schema form" do
      tool = sample_tool()

      assert {:ok, "ok"} =
               Nous.LLM.generate_text("anthropic:claude-haiku-4-5", "hi", tools: [tool])

      assert_received {:captured_settings, settings}
      assert settings.tools == [Nous.Tool.Wire.to_anthropic(tool)]
    end
  end

  defp sample_tool do
    %Nous.Tool{
      name: "lookup",
      description: "Look something up",
      parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}},
      function: fn _, _ -> {:ok, "x"} end,
      takes_ctx: false
    }
  end
end
