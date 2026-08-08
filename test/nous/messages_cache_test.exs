defmodule Nous.MessagesCacheTest do
  use ExUnit.Case, async: true

  alias Nous.Agent
  alias Nous.AgentRunner
  alias Nous.Message
  alias Nous.Message.ContentPart
  alias Nous.Messages
  alias Nous.Messages.Cache
  alias Nous.ModelDispatcher
  alias Nous.Usage

  # Every provider `to_provider_format/2` dispatches to. The memoized payload
  # must be indistinguishable from a cold conversion for all of them.
  @providers [
    :openai,
    :openai_compatible,
    :groq,
    :lmstudio,
    :ollama,
    :openrouter,
    :together,
    :vllm,
    :sglang,
    :anthropic,
    :gemini,
    :vertex_ai,
    :mistral,
    :llamacpp,
    :custom
  ]

  # The runner and `Nous.LLM` warm the cache in the CALLING process as a side
  # effect of dispatching a request -- `Nous.Provider.request/3` converts the
  # whole history -- and `AGENTS.md` documents that process as a long-lived
  # LiveView. These dispatchers do that same conversion and report the cache
  # keys they left behind, so the lifetime tests below can prove the cache was
  # genuinely WARM when the entry point returned. Without that half, "the
  # dictionary holds no cache keys afterwards" would pass just as well against a
  # run that never warmed it.
  defmodule WarmingDispatcher do
    @moduledoc false

    def request(model, messages, _settings) do
      warm_and_report(model, messages)

      {:ok,
       Message.from_legacy(%{
         parts: [{:text, "ok"}],
         usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
         model_name: "test-model",
         timestamp: DateTime.utc_now()
       })}
    end

    def request_stream(model, messages, _settings) do
      warm_and_report(model, messages)
      {:ok, [{:text_delta, "ok"}, {:finish, "stop"}]}
    end

    def count_tokens(_messages), do: 0

    defp warm_and_report(model, messages) do
      Messages.to_provider_format(messages, model.provider)
      send(self(), {:cache_warm, Nous.MessagesCacheTest.cache_keys()})
    end
  end

  defmodule RaisingDispatcher do
    @moduledoc false

    def request(model, messages, _settings) do
      Messages.to_provider_format(messages, model.provider)
      send(self(), {:cache_warm, Nous.MessagesCacheTest.cache_keys()})
      raise "provider blew up mid-run"
    end

    def request_stream(model, messages, settings), do: request(model, messages, settings)
    def count_tokens(_messages), do: 0
  end

  defmodule WarmingToolStreamDispatcher do
    @moduledoc false
    # The tool branch of `stream_text/3` converts once per turn while the
    # CONSUMER enumerates, so its release is the `Stream.resource` after-fun
    # rather than the function's own `after`. First turn asks for a tool; once
    # the result is in the history, answer with text so the stream terminates.
    def request_stream(model, messages, _settings) do
      Messages.to_provider_format(messages, model.provider)
      send(self(), {:cache_warm, Nous.MessagesCacheTest.cache_keys()})

      if Enum.any?(messages, &match?(%Message{role: :tool}, &1)) do
        {:ok, [{:text_delta, "done"}, {:finish, "stop"}]}
      else
        {:ok,
         [
           {:tool_call_delta, %{"name" => "echo", "arguments" => %{"input" => "hi"}}},
           {:finish, "tool_calls"}
         ]}
      end
    end

    def request(model, messages, settings), do: request_stream(model, messages, settings)
    def count_tokens(_messages), do: 0
  end

  @doc false
  # Public so `&__MODULE__.echo/2` can be captured the way callers pass tools.
  def echo(_ctx, args), do: Map.get(args, "input", "")

  @doc false
  # Every process-dictionary key the cache owns. Deliberately not "the whole
  # dictionary is empty": `ModelDispatcher.put_dispatcher/1` lives there too, and
  # clear/0 has no business touching it.
  def cache_keys do
    Enum.filter(Process.get_keys(), &match?({Cache, _}, &1))
  end

  describe "Cache.map/3" do
    test "converts only the tail appended since the previous call" do
      key = make_ref()
      counter = :counters.new(1, [])
      fun = counting_fun(counter)

      history = Enum.to_list(1..50)
      assert Cache.map(key, history, fun) == Enum.map(history, &{:converted, &1})
      assert :counters.get(counter, 1) == 50

      grown = history ++ [51]
      assert Cache.map(key, grown, fun) == Enum.map(grown, &{:converted, &1})

      # O(new), not O(all): 50 + 1 conversions, not 50 + 51.
      assert :counters.get(counter, 1) == 51
    end

    test "reuses the converted payloads themselves, not just their values" do
      key = make_ref()
      fun = fn n -> %{"n" => Integer.to_string(n)} end

      warm = Cache.map(key, [1, 2, 3], fun)
      reused = Cache.map(key, [1, 2, 3, 4], fun)

      assert Enum.all?(Enum.zip(warm, reused), fn {a, b} -> :erts_debug.same(a, b) end)
    end

    test "reconverts from the first divergence onwards" do
      key = make_ref()
      counter = :counters.new(1, [])
      fun = counting_fun(counter)

      Cache.map(key, [:a, :b, :c], fun)
      assert :counters.get(counter, 1) == 3

      converted = Cache.map(key, [:a, :x, :c], fun)
      assert converted == [{:converted, :a}, {:converted, :x}, {:converted, :c}]

      # :a was reused; :x and :c were rebuilt.
      assert :counters.get(counter, 1) == 5
    end

    test "a truncated history converts correctly" do
      key = make_ref()
      fun = counting_fun(:counters.new(1, []))

      Cache.map(key, [1, 2, 3], fun)

      assert Cache.map(key, [2, 3], fun) == [{:converted, 2}, {:converted, 3}]
    end

    test "keys do not share cache entries" do
      counter = :counters.new(1, [])
      fun = counting_fun(counter)

      Cache.map(:key_a, [1, 2, 3], fun)
      Cache.map(:key_b, [1, 2, 3], fun)

      assert :counters.get(counter, 1) == 6
    end

    test "the cache is process-local" do
      key = make_ref()
      counter = :counters.new(1, [])
      fun = counting_fun(counter)

      Cache.map(key, [1, 2, 3], fun)
      Task.await(Task.async(fn -> Cache.map(key, [1, 2, 3, 4], fun) end))

      # The task started with an empty process dictionary, so it converted all 4.
      assert :counters.get(counter, 1) == 7
    end
  end

  describe "provider payload memoization" do
    setup do
      history = history()

      %{history: history, grown: history ++ [Message.user("and one more thing")]}
    end

    test "reuses the openai prefix", %{history: history, grown: grown} do
      warm = Messages.to_openai_format(history)
      reused = Messages.to_openai_format(grown)

      assert length(reused) == length(warm) + 1
      assert Enum.all?(Enum.zip(warm, reused), fn {a, b} -> :erts_debug.same(a, b) end)

      # Control: a conversion the cache cannot serve allocates fresh maps, so
      # :erts_debug.same/2 is genuinely discriminating on these payloads.
      Messages.to_openai_format([Message.user("an unrelated conversation")])
      fresh = Messages.to_openai_format(grown)

      assert fresh == reused
      refute Enum.any?(Enum.zip(reused, fresh), fn {a, b} -> :erts_debug.same(a, b) end)
    end

    test "reuses the anthropic prefix and keeps the system prompt", ctx do
      {warm_system, warm} = Messages.to_anthropic_format(ctx.history)
      {system, reused} = Messages.to_anthropic_format(ctx.grown)

      assert system == warm_system
      assert length(reused) == length(warm) + 1
      assert Enum.all?(Enum.zip(warm, reused), fn {a, b} -> :erts_debug.same(a, b) end)
    end

    test "reuses the gemini prefix and keeps the system prompt", ctx do
      {warm_system, warm} = Messages.to_gemini_format(ctx.history)
      {system, reused} = Messages.to_gemini_format(ctx.grown)

      assert system == warm_system
      assert length(reused) == length(warm) + 1
      assert Enum.all?(Enum.zip(warm, reused), fn {a, b} -> :erts_debug.same(a, b) end)
    end

    test "every provider payload matches a cold conversion", ctx do
      for provider <- @providers do
        cold = in_fresh_process(fn -> Messages.to_provider_format(ctx.grown, provider) end)

        hot =
          in_fresh_process(fn ->
            Messages.to_provider_format(ctx.history, provider)
            Messages.to_provider_format(ctx.grown, provider)
          end)

        assert hot == cold, "#{provider} payload changed under memoization"
      end
    end
  end

  describe "Cache.clear/0" do
    test "drops the module's entries and nothing else" do
      Cache.map(:key_a, [1, 2], & &1)
      Cache.map(:key_b, [1, 2], & &1)
      Process.put(:unrelated_entry, :keep_me)

      assert length(cache_keys()) == 2
      assert Cache.clear() == :ok
      assert cache_keys() == []
      assert Process.get(:unrelated_entry) == :keep_me
    end

    test "a cleared cache reconverts to the identical payload" do
      warm = Messages.to_openai_format(history())
      Cache.clear()

      assert Messages.to_openai_format(history()) == warm
    end
  end

  # Lifetime, not correctness: the cache retains the converted history for the
  # life of the process that warmed it, and the entry points that warmed it
  # without being asked to are the ones that release it.
  describe "the entry points release what they warmed" do
    test "AgentRunner.run/3" do
      ModelDispatcher.put_dispatcher(WarmingDispatcher)

      assert {:ok, _result} = AgentRunner.run(Agent.new("openai:gpt-4"), "hello")

      assert_received {:cache_warm, warmed}
      assert warmed != []
      assert cache_keys() == []
    end

    test "AgentRunner.run/3 when the provider raises" do
      ModelDispatcher.put_dispatcher(RaisingDispatcher)

      assert_raise RuntimeError, "provider blew up mid-run", fn ->
        AgentRunner.run(Agent.new("openai:gpt-4"), "hello")
      end

      assert_received {:cache_warm, warmed}
      assert warmed != []
      assert cache_keys() == []
    end

    test "AgentRunner.run_with_context/3" do
      ModelDispatcher.put_dispatcher(WarmingDispatcher)

      ctx = Nous.Agent.Context.new(messages: [Message.user("hello")])

      assert {:ok, _result} = AgentRunner.run_with_context(Agent.new("openai:gpt-4"), ctx)

      assert_received {:cache_warm, warmed}
      assert warmed != []
      assert cache_keys() == []
    end

    test "AgentRunner.run_stream/3, before the consumer even pulls" do
      ModelDispatcher.put_dispatcher(WarmingDispatcher)

      assert {:ok, stream} = AgentRunner.run_stream(Agent.new("openai:gpt-4"), "hello")

      # The whole conversion on this path is eager, so the release is complete
      # by the time the caller holds the stream.
      assert_received {:cache_warm, warmed}
      assert warmed != []
      assert cache_keys() == []

      assert Enum.any?(Enum.to_list(stream), &match?({:complete, _}, &1))
      assert cache_keys() == []
    end

    test "Nous.LLM.generate_text/3" do
      assert {:ok, "ok"} =
               Nous.LLM.generate_text("openai:gpt-4", "hello",
                 model_dispatcher: WarmingDispatcher
               )

      assert_received {:cache_warm, warmed}
      assert warmed != []
      assert cache_keys() == []
    end

    test "Nous.LLM.generate_text/3 when the provider raises" do
      assert_raise RuntimeError, "provider blew up mid-run", fn ->
        Nous.LLM.generate_text("openai:gpt-4", "hello", model_dispatcher: RaisingDispatcher)
      end

      assert_received {:cache_warm, warmed}
      assert warmed != []
      assert cache_keys() == []
    end

    test "Nous.LLM.stream_text/3 on the tool-free branch" do
      assert {:ok, stream} =
               Nous.LLM.stream_text("openai:gpt-4", "hello", model_dispatcher: WarmingDispatcher)

      assert Enum.to_list(stream) == ["ok"]
      assert_received {:cache_warm, warmed}
      assert warmed != []
      assert cache_keys() == []
    end

    test "Nous.LLM.stream_text/3 on the tool branch, once enumeration ends" do
      assert {:ok, stream} =
               Nous.LLM.stream_text("openai:gpt-4", "hello",
                 tools: [&__MODULE__.echo/2],
                 model_dispatcher: WarmingToolStreamDispatcher
               )

      # Nothing is converted until the consumer pulls, so the release cannot be
      # the function's own `after` -- it is the stream's terminal clause.
      assert cache_keys() == []
      refute_received {:cache_warm, _}

      assert "done" in Enum.to_list(stream)
      assert_received {:cache_warm, warmed}
      assert warmed != []
      assert cache_keys() == []
    end
  end

  defp counting_fun(counter) do
    fn item ->
      :counters.add(counter, 1, 1)
      {:converted, item}
    end
  end

  defp in_fresh_process(fun), do: Task.await(Task.async(fun))

  # Exercises every converter clause: system, plain user, multi-modal user,
  # assistant with reasoning, assistant with tool calls, and a tool result.
  defp history do
    [
      Message.system("Be helpful"),
      Message.user("What is in this image?"),
      Message.user([
        ContentPart.text("Describe it"),
        ContentPart.image_url("https://example.com/image.png")
      ]),
      Message.assistant("Let me look it up", reasoning_content: "the user wants a lookup"),
      Message.assistant("",
        tool_calls: [%{id: "call_1", name: "search", arguments: %{"query" => "cats"}}]
      ),
      Message.tool("call_1", %{"results" => ["a", "b"]}, name: "search"),
      Message.assistant("It is a cat.")
    ]
  end
end
