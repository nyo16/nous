defmodule Nous.MessagesCacheTest do
  use ExUnit.Case, async: true

  alias Nous.Message
  alias Nous.Message.ContentPart
  alias Nous.Messages
  alias Nous.Messages.Cache

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
