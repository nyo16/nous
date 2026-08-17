defmodule Nous.Plugins.SummarizationTest do
  use ExUnit.Case, async: true

  alias Nous.Agent
  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Plugins.Summarization

  defmodule FailingDispatcher do
    def request(_model, _messages, _settings), do: {:error, :summarizer_llm_down}
    def request_stream(_model, _messages, _settings), do: {:error, :summarizer_llm_down}
    def count_tokens(_messages), do: 0
  end

  defmodule RaisingDispatcher do
    def request(_model, _messages, _settings), do: raise("summarizer exploded")
    def request_stream(_model, _messages, _settings), do: raise("summarizer exploded")
    def count_tokens(_messages), do: 0
  end

  # Records the request in the calling process's mailbox and replays whatever
  # response the test parked in the process dictionary. The plugin dispatches
  # synchronously from `before_request/3`, so both run in the test process.
  defmodule RecordingDispatcher do
    def request(model, messages, settings) do
      send(self(), {:summary_request, model, messages, settings})
      Process.get(:summary_response, {:ok, Nous.Message.assistant("a summary")})
    end

    def request_stream(_model, _messages, _settings), do: {:error, :not_supported}
    def count_tokens(_messages), do: 0
  end

  defp search_tool do
    %Nous.Tool{
      name: "search",
      description: "Search the web",
      parameters: %{
        "type" => "object",
        "properties" => %{"q" => %{"type" => "string"}}
      },
      function: fn _args, _ctx -> {:ok, "results"} end
    }
  end

  setup do
    # The failure-path tests previously relied on "no API key" to make the
    # summary LLM call fail — which fired a REAL request at api.openai.com
    # (and would make a real paid call, then fail, with OPENAI_API_KEY set).
    # A failing mock dispatcher exercises the same fail-open branch offline.
    # Process-scoped, so this module no longer serialises with the rest of the
    # suite to hold a stub in the application environment.
    Nous.ModelDispatcher.put_dispatcher(FailingDispatcher)

    agent =
      Agent.new("openai:gpt-4",
        plugins: [Summarization],
        instructions: "Be helpful"
      )

    %{agent: agent}
  end

  # Collects [:nous, :compaction, *] events in order for the calling process.
  defp attach_compaction_telemetry(name) do
    test_pid = self()

    :telemetry.attach_many(
      name,
      [
        [:nous, :compaction, :start],
        [:nous, :compaction, :stop],
        [:nous, :compaction, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  describe "init/2" do
    test "initializes with default config", %{agent: agent} do
      ctx = Context.new(deps: %{})
      ctx = Summarization.init(agent, ctx)

      config = ctx.deps[:summarization_config]
      assert config[:max_context_tokens] == 100_000
      assert config[:keep_recent] == 10
      assert config[:max_result_chars] == 8192
      assert config[:summary_count] == 0
      assert config[:summary_model] == nil
      assert config[:compaction_in_progress] == false
    end

    test "respects custom config", %{agent: agent} do
      ctx =
        Context.new(
          deps: %{
            summarization_config: %{
              max_context_tokens: 50_000,
              keep_recent: 5,
              max_result_chars: 512,
              summary_model: "openai:gpt-4o-mini"
            }
          }
        )

      ctx = Summarization.init(agent, ctx)
      config = ctx.deps[:summarization_config]

      assert config[:max_context_tokens] == 50_000
      assert config[:keep_recent] == 5
      assert config[:max_result_chars] == 512
      assert config[:summary_model] == "openai:gpt-4o-mini"
    end
  end

  describe "before_request/3 — threshold" do
    test "does not trigger when under token threshold", %{agent: agent} do
      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 100_000}},
          usage: %Nous.Usage{total_tokens: 50_000}
        )

      ctx = Summarization.init(agent, ctx)

      # Add a few messages
      ctx = Context.add_message(ctx, Message.user("Hello"))
      ctx = Context.add_message(ctx, Message.assistant("Hi!"))

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # Messages should be unchanged
      assert length(result_ctx.messages) == length(ctx.messages)
    end

    test "triggers on the size of the transcript, not on cumulative usage", %{agent: agent} do
      # The bug this pins: the trigger used to read `ctx.usage.total_tokens`, the
      # cumulative bill for the run. A context far past its limit was therefore
      # ignored whenever little had been billed yet — measured at ~300,000
      # estimated tokens against `max_context_tokens: 5_000`, left untouched.
      #
      # `usage` is deliberately ZERO here. Every other test in this file supplies a
      # large fake `total_tokens`, which is why they all passed while the plugin was
      # bounding nothing.
      big = String.duplicate("x", 40_000)

      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 5_000, keep_recent: 2}},
          usage: %Nous.Usage{total_tokens: 0}
        )

      ctx = Summarization.init(agent, ctx)

      ctx =
        Enum.reduce(1..6, Context.add_message(ctx, Message.user("start")), fn i, acc ->
          acc
          |> Context.add_message(
            Message.assistant("",
              tool_calls: [%{"id" => "c#{i}", "name" => "grep", "arguments" => %{}}]
            )
          )
          |> Context.add_message(Message.tool("c#{i}", big, name: "grep"))
        end)

      before_tokens = Nous.Transcript.estimate_messages_tokens(ctx.messages)
      assert before_tokens > 5_000, "the fixture must actually exceed the limit"

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])
      after_tokens = Nous.Transcript.estimate_messages_tokens(result_ctx.messages)

      # Measured: 60,000 estimated tokens against a 5,000 limit comes down to
      # ~7,800 on the free prune alone — 12x over budget reduced to under 2x.
      # Closing the last of that gap is the LLM summarization step's job, and no
      # summary model is configured here, so this asserts what the prune owns.
      #
      # Both bounds matter: a prune that trimmed one byte satisfies `<` on its own,
      # and on the old usage-based trigger nothing was pruned at all, so
      # `after_tokens` equalled `before_tokens` and both of these fail.
      assert after_tokens < div(before_tokens, 5)
      assert after_tokens < 5_000 * 2
    end

    test "does not crash when over threshold but too few messages to summarize", %{agent: agent} do
      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 100, keep_recent: 10}},
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)

      # Add fewer messages than keep_recent
      ctx = Context.add_message(ctx, Message.user("Hello"))
      ctx = Context.add_message(ctx, Message.assistant("Hi!"))

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # Should pass through unchanged (not enough to summarize)
      assert length(result_ctx.messages) == 2
    end
  end

  describe "prune-first" do
    test "pruning that clears the pressure makes ZERO model calls" do
      # The whole point of Phase B: an oversized tool result is truncated for
      # free, the transcript is re-measured, and no summarization request is
      # made. The endpoint below is wired to FAIL this test if it is hit.
      bypass = Bypass.open()
      test_pid = self()

      Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
        send(test_pid, :llm_called)
        Plug.Conn.resp(conn, 200, "{}")
      end)

      # Real dispatcher: the only thing standing between this test and a
      # network call is the plugin deciding not to make one.
      Nous.ModelDispatcher.put_dispatcher(nil)

      # `lmstudio` is a `:local`-strategy provider: its SSRF guard allows
      # loopback, so a request the plugin should not make would genuinely
      # reach Bypass. (`custom:` would be refused before the socket opens,
      # which would make this assertion vacuous.)
      agent =
        Agent.new("lmstudio:fake-model",
          plugins: [Summarization],
          base_url: "http://localhost:#{bypass.port}/v1",
          api_key: "not-needed"
        )

      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 5_000, keep_recent: 2}},
          usage: %Nous.Usage{total_tokens: 60_000}
        )

      ctx = Summarization.init(agent, ctx)

      messages = [
        Message.system("You are helpful"),
        Message.user("read the file"),
        Message.assistant("reading", tool_calls: [%{id: "c1", name: "read"}]),
        Message.tool("c1", String.duplicate("x", 100_000)),
        Message.user("thanks"),
        Message.assistant("done")
      ]

      ctx = %{ctx | messages: messages}

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      refute_receive :llm_called, 200

      # Pruning happened and nothing was summarized away.
      assert length(result_ctx.messages) == length(messages)
      assert Enum.map(result_ctx.messages, & &1.role) == Enum.map(messages, & &1.role)

      tool_msg = Enum.find(result_ctx.messages, &(&1.role == :tool))
      assert tool_msg.content =~ "bytes elided by transcript pruning"
      assert byte_size(tool_msg.content) < 10_000

      refute Enum.any?(result_ctx.messages, &(&1.content =~ "[Conversation Summary]"))
    end

    test "still summarizes when pruning is not enough", %{agent: agent} do
      Nous.ModelDispatcher.put_dispatcher(RecordingDispatcher)

      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 1, keep_recent: 2}},
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)

      ctx = %{
        ctx
        | messages: [
            Message.system("sys"),
            Message.user("Q1"),
            Message.assistant("A1"),
            Message.user("Q2"),
            Message.assistant("A2")
          ]
      }

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      assert_received {:summary_request, _model, _messages, _settings}
      assert Enum.any?(result_ctx.messages, &(&1.content =~ "[Conversation Summary]"))
    end

    test "keeps the pruned messages even when the summarizer fails", %{agent: agent} do
      # FailingDispatcher from setup. Pruning is free and already paid for;
      # a failed summary must not roll it back.
      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 1, keep_recent: 2}},
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)

      messages = [
        Message.user("read"),
        Message.assistant("reading", tool_calls: [%{id: "c1", name: "read"}]),
        Message.tool("c1", String.duplicate("x", 100_000)),
        Message.user("thanks"),
        Message.assistant("done")
      ]

      ctx = %{ctx | messages: messages}

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      assert length(result_ctx.messages) == length(messages)
      tool_msg = Enum.find(result_ctx.messages, &(&1.role == :tool))
      assert tool_msg.content =~ "bytes elided by transcript pruning"
    end
  end

  describe "tool_call/tool_result safety at the compaction boundary" do
    test "never splits a tool_call from its tool_result", %{agent: agent} do
      # Build a conversation where a naive split would land inside a tool sequence
      messages = [
        Message.user("Search for dogs"),
        Message.assistant("Let me search",
          tool_calls: [%{id: "call_1", name: "search", arguments: %{}}]
        ),
        Message.tool("call_1", "Found dogs"),
        Message.user("Now search for cats"),
        Message.assistant("Searching cats",
          tool_calls: [%{id: "call_2", name: "search", arguments: %{}}]
        ),
        Message.tool("call_2", "Found cats"),
        Message.user("Thanks"),
        Message.assistant("You're welcome!")
      ]

      # Create context with high token count to trigger summarization
      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 1, keep_recent: 3}},
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)
      ctx = %{ctx | messages: messages}

      # The summarization will try to run but fail (FailingDispatcher),
      # so the fallback should keep all messages
      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # Check that no tool result is separated from its tool call
      result_msgs = result_ctx.messages

      Enum.with_index(result_msgs)
      |> Enum.each(fn {msg, i} ->
        if msg.role == :tool and i > 0 do
          prev = Enum.at(result_msgs, i - 1)

          # The message before a tool result should either be another tool result
          # (from the same multi-call) or the assistant message with tool_calls
          assert prev.role in [:assistant, :tool],
                 "Tool result at index #{i} is preceded by #{prev.role}"
        end
      end)
    end

    test "a boundary landing between an assistant tool_call and its result summarizes both",
         %{agent: agent} do
      Nous.ModelDispatcher.put_dispatcher(RecordingDispatcher)

      # keep_recent: 2 puts the naive boundary immediately after the assistant
      # tool_call, orphaning the tool result at the head of `recent`.
      messages = [
        Message.user("u1"),
        Message.assistant("calling", tool_calls: [%{id: "c1", name: "search"}]),
        Message.tool("c1", "found"),
        Message.assistant("done")
      ]

      ctx = compaction_ctx(agent, messages, keep_recent: 2)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # Both halves of the pair went into the summary; neither survives.
      refute Enum.any?(result_ctx.messages, &(&1.role == :tool))
      refute Enum.any?(result_ctx.messages, &Nous.Message.has_tool_calls?/1)

      assert_received {:summary_request, _model, request_messages, _settings}
      summarized = Enum.filter(request_messages, &(&1.role in [:tool, :assistant]))
      assert Enum.any?(summarized, &(&1.role == :tool))
    end

    test "a boundary landing mid-run of parallel tool results keeps the run together",
         %{agent: agent} do
      Nous.ModelDispatcher.put_dispatcher(RecordingDispatcher)

      messages = [
        Message.user("u1"),
        Message.assistant("calling",
          tool_calls: [%{id: "c1", name: "search"}, %{id: "c2", name: "search"}]
        ),
        Message.tool("c1", "a"),
        Message.tool("c2", "b"),
        Message.assistant("done")
      ]

      # keep_recent: 2 splits the pair of tool results down the middle.
      ctx = compaction_ctx(agent, messages, keep_recent: 2)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      refute Enum.any?(result_ctx.messages, &(&1.role == :tool))
    end
  end

  describe "prefix-cache-friendly summarization request" do
    setup %{agent: _agent} do
      Nous.ModelDispatcher.put_dispatcher(RecordingDispatcher)

      agent =
        Agent.new("openai:gpt-4",
          plugins: [Summarization],
          instructions: "Be helpful",
          tools: [search_tool()],
          model_settings: %{top_p: 0.9}
        )

      %{agent: agent}
    end

    test "replays the conversation's own system prompt and tools verbatim", %{agent: agent} do
      system = Message.system("You are a very specific assistant")

      messages = [
        system,
        Message.user("Q1"),
        Message.assistant("A1"),
        Message.user("Q2"),
        Message.assistant("A2")
      ]

      ctx = compaction_ctx(agent, messages, keep_recent: 2)

      {_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      assert_received {:summary_request, model, request_messages, settings}

      # Same model as the conversation — a different one cannot hit the cache.
      assert model == agent.model

      # The system prompt leads the request, byte-for-byte.
      assert hd(request_messages) == system

      # The conversation's tool schemas ride along.
      assert [%{"function" => %{"name" => "search"}}] = settings[:tools]

      # Base model settings are preserved.
      assert settings[:top_p] == 0.9

      # The instruction is appended as the final turn, after the replayed
      # history, so the whole prefix stays cacheable.
      last = List.last(request_messages)
      assert last.role == :user
      assert last.content =~ "Summarize the conversation above"
    end

    test "discards tool calls and reasoning from the summary response", %{agent: agent} do
      Process.put(
        :summary_response,
        {:ok,
         %Message{
           role: :assistant,
           content: "the actual summary",
           reasoning_content: "secret chain of thought",
           tool_calls: [%{"id" => "c9", "function" => %{"name" => "search"}}],
           metadata: %{}
         }}
      )

      messages = [
        Message.system("sys"),
        Message.user("Q1"),
        Message.assistant("A1"),
        Message.user("Q2"),
        Message.assistant("A2")
      ]

      ctx = compaction_ctx(agent, messages, keep_recent: 2)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      summary = Enum.find(result_ctx.messages, &(&1.content =~ "[Conversation Summary]"))

      assert summary
      assert summary.content =~ "the actual summary"
      # An orphaned tool_call in a durable system message would 400 the very
      # next request.
      assert summary.tool_calls == []
      refute summary.content =~ "secret chain of thought"
      refute summary.reasoning_content
    end

    test "a tool-call-only response is a failed summary, not an empty one", %{agent: agent} do
      Process.put(
        :summary_response,
        {:ok,
         %Message{
           role: :assistant,
           content: nil,
           tool_calls: [%{"id" => "c9", "function" => %{"name" => "search"}}],
           metadata: %{}
         }}
      )

      messages = [
        Message.system("sys"),
        Message.user("Q1"),
        Message.assistant("A1"),
        Message.user("Q2"),
        Message.assistant("A2")
      ]

      ctx = compaction_ctx(agent, messages, keep_recent: 2)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # History is intact rather than replaced by an empty summary.
      assert length(result_ctx.messages) == length(messages)
      refute Enum.any?(result_ctx.messages, &(&1.content =~ "[Conversation Summary]"))
    end
  end

  describe "telemetry" do
    test "emits start then stop with the documented metadata", %{agent: agent} do
      attach_compaction_telemetry("compaction-stop-test")
      Nous.ModelDispatcher.put_dispatcher(RecordingDispatcher)

      messages = [
        Message.system("sys"),
        Message.user("Q1"),
        Message.assistant("A1"),
        Message.user("Q2"),
        Message.assistant("A2")
      ]

      ctx = compaction_ctx(agent, messages, keep_recent: 2)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      assert_received {:telemetry, [:nous, :compaction, :start], start_measurements,
                       start_metadata}

      assert is_integer(start_measurements.system_time)
      assert is_integer(start_measurements.monotonic_time)
      assert start_metadata.agent_name == agent.name
      assert start_metadata.messages_before == 5

      assert_received {:telemetry, [:nous, :compaction, :stop], stop_measurements, stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.bytes_before > 0
      assert stop_metadata.messages_before == 5
      assert stop_metadata.messages_after == length(result_ctx.messages)
      assert stop_metadata.llm_called
      assert stop_metadata.summarized
      assert stop_metadata.provider == :openai
      assert stop_metadata.model == "gpt-4"

      refute_received {:telemetry, [:nous, :compaction, :exception], _, _}
    end

    test "reports llm_called: false when pruning alone cleared the pressure", %{agent: agent} do
      attach_compaction_telemetry("compaction-prune-only-test")

      messages = [
        Message.user("read"),
        Message.assistant("reading", tool_calls: [%{id: "c1", name: "read"}]),
        Message.tool("c1", String.duplicate("x", 100_000)),
        Message.assistant("done")
      ]

      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 5_000, keep_recent: 2}},
          usage: %Nous.Usage{total_tokens: 60_000}
        )

      ctx = Summarization.init(agent, ctx)
      ctx = %{ctx | messages: messages}

      {_result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      assert_received {:telemetry, [:nous, :compaction, :start], _, _}
      assert_received {:telemetry, [:nous, :compaction, :stop], measurements, metadata}

      refute metadata.llm_called
      refute metadata.summarized
      assert metadata.provider == nil
      assert metadata.usage == nil
      # The saving pruning bought is visible in the measurements.
      assert measurements.bytes_after < measurements.bytes_before / 10
    end

    test "an exception mid-compaction emits :exception and leaves the marker set",
         %{agent: agent} do
      attach_compaction_telemetry("compaction-exception-test")
      Nous.ModelDispatcher.put_dispatcher(RaisingDispatcher)

      messages = [
        Message.system("sys"),
        Message.user("Q1"),
        Message.assistant("A1"),
        Message.user("Q2"),
        Message.assistant("A2")
      ]

      ctx = compaction_ctx(agent, messages, keep_recent: 2)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      assert_received {:telemetry, [:nous, :compaction, :start], _, _}

      assert_received {:telemetry, [:nous, :compaction, :exception], measurements, metadata}

      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "summarizer exploded"} = metadata.reason
      assert metadata.llm_called
      assert is_list(metadata.stacktrace)

      # No :stop: an orphaned :start is exactly the signal we want.
      refute_received {:telemetry, [:nous, :compaction, :stop], _, _}

      # And the in-progress marker is still up, so the next turn can see that
      # the previous compaction never finished.
      assert result_ctx.deps[:summarization_config][:compaction_in_progress]

      # The run survives with its messages intact.
      assert length(result_ctx.messages) == length(messages)
    end

    test "the in-progress marker is cleared only on the success path", %{agent: agent} do
      Nous.ModelDispatcher.put_dispatcher(RecordingDispatcher)

      messages = [
        Message.system("sys"),
        Message.user("Q1"),
        Message.assistant("A1"),
        Message.user("Q2"),
        Message.assistant("A2")
      ]

      ctx = compaction_ctx(agent, messages, keep_recent: 2)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      refute result_ctx.deps[:summarization_config][:compaction_in_progress]
      assert result_ctx.deps[:summarization_config][:summary_count] == 1
    end
  end

  describe "system message preservation" do
    test "system messages are preserved separately from conversation", %{agent: agent} do
      # Create a context with system and conversation messages
      ctx =
        Context.new(
          system_prompt: "You are helpful",
          deps: %{summarization_config: %{max_context_tokens: 1, keep_recent: 2}},
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)

      # Add system + conversation messages
      ctx = Context.add_message(ctx, Message.system("System instruction"))
      ctx = Context.add_message(ctx, Message.user("First question"))
      ctx = Context.add_message(ctx, Message.assistant("First answer"))
      ctx = Context.add_message(ctx, Message.user("Second question"))
      ctx = Context.add_message(ctx, Message.assistant("Second answer"))
      ctx = Context.add_message(ctx, Message.user("Third question"))
      ctx = Context.add_message(ctx, Message.assistant("Third answer"))

      # Summarization will try but fail (FailingDispatcher), so messages are preserved
      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # System messages should still be present
      system_msgs = Enum.filter(result_ctx.messages, &(&1.role == :system))
      assert length(system_msgs) >= 1
    end
  end

  describe "fallback on summarization failure" do
    test "keeps all messages when LLM call fails", %{agent: agent} do
      ctx =
        Context.new(
          deps: %{
            summarization_config: %{
              max_context_tokens: 1,
              keep_recent: 2,
              summary_model: "openai:gpt-4o-mini"
            }
          },
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)

      # Add enough messages to trigger summarization
      ctx = Context.add_message(ctx, Message.user("Q1"))
      ctx = Context.add_message(ctx, Message.assistant("A1"))
      ctx = Context.add_message(ctx, Message.user("Q2"))
      ctx = Context.add_message(ctx, Message.assistant("A2"))
      ctx = Context.add_message(ctx, Message.user("Q3"))
      ctx = Context.add_message(ctx, Message.assistant("A3"))

      original_count = length(ctx.messages)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # On failure, all messages should be preserved
      assert length(result_ctx.messages) == original_count
    end
  end

  defp compaction_ctx(agent, messages, opts) do
    config =
      %{max_context_tokens: 1}
      |> Map.merge(Map.new(opts))

    ctx =
      Context.new(
        deps: %{summarization_config: config},
        usage: %Nous.Usage{total_tokens: 200}
      )

    ctx = Summarization.init(agent, ctx)
    %{ctx | messages: messages}
  end
end
