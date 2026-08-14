defmodule Nous.Session.LogIntegrationTest do
  @moduledoc """
  The wiring between `Nous.Session.Log` and everything that used to own a flat
  message list: `Nous.Agent.Context`, the three plugins that injected messages
  behind its back, and the runner.

  `Nous.Session.LogTest` covers the log in isolation and
  `Nous.Session.D2MessageContractTest` covers the public message surface. This
  file covers the property that connects them — **model-visible implies logged**
  — and the invariant that keeps it true: `ctx.messages` is always the fold of
  `ctx.log`, plus the assembly-time system-prompt overlay, which is deliberately
  not history.
  """

  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Session.Log

  @moduletag :capture_log

  # --- doubles ---------------------------------------------------------------

  defmodule SummaryDispatcher do
    @moduledoc false
    def request(_model, _messages, _settings) do
      {:ok, Message.assistant("compacted briefing", metadata: %{})}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 1
  end

  defmodule EchoDispatcher do
    @moduledoc false
    def request(_model, _messages, _settings) do
      usage = %Nous.Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1}
      {:ok, Message.assistant("ok", metadata: %{usage: usage})}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 1
  end

  # The invariant. `system_prompt_overlay` is the one sanctioned difference
  # between the view and the fold, so every caller of this runs without one.
  defp lockstep!(%Context{} = ctx) do
    assert ctx.system_prompt_overlay == nil
    assert ctx.messages == Log.derive_messages(ctx.log)
    ctx
  end

  # --- Context ---------------------------------------------------------------

  describe "add_message/3 and add_messages/2 as appends" do
    test "seq stays contiguous through an arbitrary mix of single and bulk adds" do
      ctx =
        Context.new()
        |> Context.add_message(Message.system("sys"))
        |> Context.add_messages([Message.user("a"), Message.assistant("b")])
        |> Context.add_message(Message.user("c"))
        |> Context.add_messages([])
        |> Context.add_messages([
          Message.assistant("d", tool_calls: [%{"id" => "c1", "name" => "echo"}]),
          Message.tool("c1", "echoed", name: "echo")
        ])
        |> Context.add_message(Message.user("e"))

      assert ctx.log |> Log.events() |> Enum.map(& &1.seq) == Enum.to_list(0..6)
      assert Log.count(ctx.log) == 7
      lockstep!(ctx)
    end

    test "a message added is the message returned, byte for byte" do
      # `created_at` included: the event carries the message's own time, so the
      # fold cannot drift the transcript's timestamps forward on every append.
      messages = [
        Message.system("sys", metadata: %{tier: "gold"}),
        Message.user("hi", name: "alice"),
        Message.assistant("thinking",
          tool_calls: [%{"id" => "c1", "name" => "echo", "arguments" => %{"t" => 1}}],
          reasoning_content: "because",
          metadata: %{usage: %Nous.Usage{total_tokens: 3}}
        ),
        Message.tool("c1", "echoed", name: "echo", metadata: %{ms: 4})
      ]

      one_at_a_time = Enum.reduce(messages, Context.new(), &Context.add_message(&2, &1))
      in_bulk = Context.add_messages(Context.new(), messages)

      assert one_at_a_time.messages == messages
      assert in_bulk.messages == messages
      lockstep!(one_at_a_time)
      lockstep!(in_bulk)
    end

    test "an assistant event with neither content nor tool calls is logged AND derived" do
      # The fold reproduces it; it filters nothing. Phase A filtered it, and that
      # was observable — before the log this message sat in `ctx.messages`, so
      # `BasicAgent.extract_output/2` found it and a run whose model produced
      # empty content returned `{:ok, ""}`, where filtering turned the same run
      # into `{:error, :no_output}`. Dropping an empty assistant turn is a fact
      # about what a provider will accept, so it belongs in the request builder.
      # `Nous.Session.Log`'s `project/1` carries the full rationale.
      empty = Message.assistant("")
      ctx = Context.add_message(Context.new(), empty)

      assert Log.count(ctx.log) == 1
      assert ctx.messages == [empty]
      lockstep!(ctx)
    end

    test "update_needs_response is unchanged by the log" do
      base = Context.new()

      assert Context.add_message(base, Message.user("q")).needs_response
      refute Context.add_message(base, Message.assistant("done")).needs_response

      assert Context.add_message(
               base,
               Message.assistant("calling", tool_calls: [%{"id" => "c1"}])
             ).needs_response

      assert Context.add_message(base, Message.tool("c1", "r")).needs_response

      # A system message leaves it alone.
      refute Context.add_message(%{base | needs_response: false}, Message.system("s")).needs_response
    end

    test "a caller that writes ctx.messages directly is re-seeded, not clobbered" do
      # Plugin fixtures and user code written before the log both do this. The
      # next append must not silently resurrect the fold over it.
      ctx = %{Context.new() | messages: [Message.user("written by hand")]}

      ctx = Context.add_message(ctx, Message.assistant("answer"))

      assert Enum.map(ctx.messages, & &1.content) == ["written by hand", "answer"]
      assert Log.count(ctx.log) == 2
      lockstep!(ctx)
    end
  end

  describe "seeding" do
    test "Context.new(messages: ...) folds back to exactly those messages" do
      messages = [Message.system("sys"), Message.user("q"), Message.assistant("a")]

      ctx = Context.new(messages: messages)

      assert ctx.messages == messages

      assert Enum.map(Log.events(ctx.log), & &1.type) ==
               [:system_message, :user_message, :assistant_message]

      lockstep!(ctx)
    end

    test "Nous.run(agent, messages: [...]) seeds a log whose fold equals the input list" do
      Nous.ModelDispatcher.put_dispatcher(EchoDispatcher)

      seeded = [
        Message.system("seeded system"),
        Message.user("seeded user"),
        Message.assistant("seeded assistant"),
        Message.user("and then this")
      ]

      {:ok, result} = Nous.run(Nous.new("openai:gpt-4o", name: "seed-run"), messages: seeded)

      log = result.context.log

      assert Enum.take(Log.derive_messages(log), 4) == seeded
      assert log |> Log.events() |> Enum.map(& &1.seq) |> Enum.take(4) == [0, 1, 2, 3]
      lockstep!(result.context)
    end
  end

  # --- the migrated bypass sites --------------------------------------------

  describe "injected memory is logged" do
    test "the injection is an event marked with its source, and messages stays the fold" do
      alias Nous.Memory.{Entry, Store}

      agent = Nous.new("openai:gpt-4", plugins: [Nous.Plugins.Memory])

      ctx =
        Nous.Plugins.Memory.init(agent, Context.new(deps: %{memory_config: %{store: Store.ETS}}))

      config = ctx.deps[:memory_config]

      {:ok, store} =
        Store.ETS.store(config[:store_state], Entry.new(%{content: "prefers dark mode"}))

      ctx = %{
        ctx
        | deps: Map.put(ctx.deps, :memory_config, Map.put(config, :store_state, store))
      }

      ctx = Context.add_message(ctx, Message.user("what do you know about my setup?"))
      before = Log.count(ctx.log)

      {ctx, _tools} = Nous.Plugins.Memory.before_request(agent, ctx, [])

      injected = ctx.log |> Log.events() |> List.last()

      assert Log.count(ctx.log) == before + 1
      assert injected.type == :system_message
      assert injected.data.source == :memory
      assert injected.data.content =~ "prefers dark mode"
      lockstep!(ctx)
    end
  end

  describe "injected knowledge base entries are logged" do
    test "the injection is an event marked with its source, and messages stays the fold" do
      alias Nous.KnowledgeBase.{Entry, Store}

      {:ok, store} = Store.ETS.init([])

      {:ok, store} =
        Store.ETS.store_entry(
          store,
          Entry.new(%{title: "GenServer Guide", content: "state and callbacks", kb_id: "kb"})
        )

      ctx =
        Context.new(
          messages: [Message.user("tell me about GenServer")],
          deps: %{
            kb_config: %{
              store: Store.ETS,
              store_state: store,
              kb_id: "kb",
              auto_inject: true,
              inject_strategy: :first_only,
              inject_min_score: 0.0,
              inject_limit: 3,
              _inject_done: false
            }
          }
        )

      agent = Nous.new("openai:gpt-4", plugins: [Nous.Plugins.KnowledgeBase])

      {ctx, _tools} = Nous.Plugins.KnowledgeBase.before_request(agent, ctx, [])

      injected = ctx.log |> Log.events() |> List.last()

      assert Log.count(ctx.log) == 2
      assert injected.type == :system_message
      assert injected.data.source == :knowledge_base
      assert injected.data.content =~ "Relevant Knowledge"
      lockstep!(ctx)
    end
  end

  describe "the assembled system prompt is not an event" do
    test "the overlay reaches the model without touching the log" do
      # The decision, pinned: plugin and skill system prompts are re-derived from
      # agent config on every run, so logging each rewrite would append a copy of
      # the same text per run. The overlay is applied during materialization
      # instead, which is why `messages` and the fold still agree.
      ctx = Context.new(messages: [Message.system("base"), Message.user("q")])
      before = Log.events(ctx.log)

      ctx = Context.put_system_prompt_overlay(ctx, "PLUGIN FRAGMENT")

      assert Log.events(ctx.log) == before
      assert hd(ctx.messages).content == "base\n\nPLUGIN FRAGMENT"
      # The fold itself is untouched: the overlay is a view, not history.
      assert hd(Log.derive_messages(ctx.log)).content == "base"

      # Idempotent, where the old in-place rewrite compounded.
      ctx = Context.put_system_prompt_overlay(ctx, "PLUGIN FRAGMENT")
      assert hd(ctx.messages).content == "base\n\nPLUGIN FRAGMENT"

      # An append after the overlay neither loses it nor logs it.
      ctx = Context.add_message(ctx, Message.assistant("a"))
      assert hd(ctx.messages).content == "base\n\nPLUGIN FRAGMENT"

      assert Enum.map(Log.events(ctx.log), & &1.type) ==
               [:system_message, :user_message, :assistant_message]

      assert Context.put_system_prompt_overlay(ctx, nil).messages ==
               Log.derive_messages(ctx.log)
    end

    test "with no leading system message the overlay becomes one, still without an event" do
      ctx =
        Context.new(messages: [Message.user("q")])
        |> Context.put_system_prompt_overlay("ONLY FRAGMENT")

      assert Enum.map(ctx.messages, &{&1.role, &1.content}) ==
               [{:system, "ONLY FRAGMENT"}, {:user, "q"}]

      assert Enum.map(Log.events(ctx.log), & &1.type) == [:user_message]

      # Timestamps still never go backwards, which the D2 gate pins.
      stamps = Enum.map(ctx.messages, & &1.created_at)
      assert stamps == Enum.sort(stamps, &(DateTime.compare(&1, &2) != :gt))
    end
  end

  # --- compaction ------------------------------------------------------------

  describe "compaction replaces instead of deleting" do
    setup do
      Nous.ModelDispatcher.put_dispatcher(SummaryDispatcher)

      agent =
        Nous.new("openai:gpt-4",
          plugins: [Nous.Plugins.Summarization],
          instructions: "Be helpful"
        )

      %{agent: agent}
    end

    defp compaction_ctx(messages, opts) do
      Context.new(
        messages: messages,
        deps: %{summarization_config: Map.merge(%{max_context_tokens: 1}, Map.new(opts))},
        usage: %Nous.Usage{total_tokens: 200}
      )
    end

    test "the summary lands in the shadowed range's position and nothing is deleted",
         %{agent: agent} do
      messages = [
        Message.system("sys"),
        Message.user("Q1"),
        Message.assistant("A1"),
        Message.user("Q2"),
        Message.assistant("A2"),
        Message.user("Q3"),
        Message.assistant("A3")
      ]

      ctx = compaction_ctx(messages, keep_recent: 2)

      {ctx, _tools} = Nous.Plugins.Summarization.before_request(agent, ctx, [])

      # The compacted view: system prompt, then the summary standing exactly
      # where Q1..A2 stood, then the recent pair.
      assert Enum.map(ctx.messages, &{&1.role, &1.content}) == [
               {:system, "sys"},
               {:system, "[Conversation Summary]\ncompacted briefing"},
               {:user, "Q3"},
               {:assistant, "A3"}
             ]

      # Every original event is still there — seven seeded, plus the summary.
      events = Log.events(ctx.log)
      assert Enum.map(events, & &1.seq) == Enum.to_list(0..7)

      assert events |> Enum.take(7) |> Enum.map(& &1.data[:content]) ==
               ["sys", "Q1", "A1", "Q2", "A2", "Q3", "A3"]

      assert List.last(events).data.surface_op == {:replace, 1, 4}
      lockstep!(ctx)
    end

    test "the summary inherits the time of the range it stands in for", %{agent: agent} do
      messages = [Message.user("Q1"), Message.assistant("A1"), Message.user("Q2")]
      ctx = compaction_ctx(messages, keep_recent: 1)

      {ctx, _tools} = Nous.Plugins.Summarization.before_request(agent, ctx, [])

      stamps = Enum.map(ctx.messages, & &1.created_at)

      assert hd(stamps) == hd(messages).created_at
      assert stamps == Enum.sort(stamps, &(DateTime.compare(&1, &2) != :gt))
    end

    test "no boundary produces an orphaned tool result", %{agent: agent} do
      messages = [
        Message.system("sys"),
        Message.user("u1"),
        Message.assistant("calling", tool_calls: [%{"id" => "c1", "name" => "search"}]),
        Message.tool("c1", "found", name: "search"),
        Message.assistant("calling twice",
          tool_calls: [%{"id" => "c2", "name" => "search"}, %{"id" => "c3", "name" => "search"}]
        ),
        Message.tool("c2", "a", name: "search"),
        Message.tool("c3", "b", name: "search"),
        Message.assistant("done")
      ]

      # Every boundary, including the ones that land mid tool-run.
      for keep_recent <- 1..7 do
        ctx = compaction_ctx(messages, keep_recent: keep_recent)
        {ctx, _tools} = Nous.Plugins.Summarization.before_request(agent, ctx, [])

        folded = ctx.messages

        Enum.each(Enum.with_index(folded), fn {msg, index} ->
          if msg.role == :tool do
            previous = if index > 0, do: Enum.at(folded, index - 1)

            assert previous && previous.role in [:assistant, :tool],
                   "keep_recent: #{keep_recent} orphaned #{msg.tool_call_id} behind " <>
                     "#{inspect(previous && previous.role)}"
          end
        end)

        # The mirror of it: no surviving tool result whose call was shadowed.
        call_ids =
          folded
          |> Enum.filter(&(&1.role == :assistant))
          |> Enum.flat_map(&Enum.map(&1.tool_calls || [], fn call -> call["id"] end))
          |> MapSet.new()

        result_ids =
          folded
          |> Enum.filter(&(&1.role == :tool))
          |> Enum.map(& &1.tool_call_id)
          |> MapSet.new()

        assert MapSet.subset?(result_ids, call_ids),
               "keep_recent: #{keep_recent} left a tool result with no call"

        lockstep!(ctx)
      end
    end

    test "pruning rewrites a tool result in place and keeps the oversized original",
         %{agent: agent} do
      oversized = String.duplicate("x", 100_000)

      messages = [
        Message.user("read"),
        Message.assistant("reading", tool_calls: [%{"id" => "c1", "name" => "read"}]),
        Message.tool("c1", oversized, name: "read"),
        Message.user("thanks"),
        Message.assistant("done")
      ]

      # A budget pruning alone can clear, so this is the prune-only path: no
      # summary, and the plugin must still leave the view and the log in step.
      ctx =
        Context.new(
          messages: messages,
          deps: %{summarization_config: %{max_context_tokens: 5_000, keep_recent: 2}},
          usage: %Nous.Usage{total_tokens: 60_000}
        )

      {ctx, _tools} = Nous.Plugins.Summarization.before_request(agent, ctx, [])

      # Same count, same order, one shorter tool result.
      assert Enum.map(ctx.messages, & &1.role) == Enum.map(messages, & &1.role)
      pruned = Enum.at(ctx.messages, 2)
      assert pruned.content =~ "bytes elided by transcript pruning"
      assert pruned.tool_call_id == "c1"
      assert pruned.name == "read"

      # The prune is an in-place replace, and the oversized original is still in
      # the log where a rewind could find it.
      replace = ctx.log |> Log.events() |> List.last()
      assert replace.type == :tool_result
      assert replace.data.surface_op == {:replace, 2, 2}
      assert Enum.at(Log.events(ctx.log), 2).data.content == oversized
      lockstep!(ctx)
    end

    test "a summary swallows an in-place prune inside its range", %{agent: agent} do
      oversized = String.duplicate("x", 100_000)

      messages = [
        Message.user("read"),
        Message.assistant("reading", tool_calls: [%{"id" => "c1", "name" => "read"}]),
        Message.tool("c1", oversized, name: "read"),
        Message.user("Q2"),
        Message.assistant("A2")
      ]

      # A budget pruning cannot clear, so both halves run: pruning appends a
      # `{:replace, 2, 2}` at seq 5, and the summary then replaces positions
      # 0..2, which has to shadow that prune even though its seq is outside the
      # range. Shadowing by raw seq would leave the pruned tool result behind
      # with its assistant message gone — an orphan every provider 400s on.
      ctx = compaction_ctx(messages, keep_recent: 2)

      {ctx, _tools} = Nous.Plugins.Summarization.before_request(agent, ctx, [])

      refute Enum.any?(ctx.messages, &(&1.role == :tool))
      assert Enum.map(ctx.messages, & &1.role) == [:system, :user, :assistant]
      # Five seeded, plus the prune, plus the summary: nothing deleted.
      assert Log.count(ctx.log) == 7
      lockstep!(ctx)
    end

    test "a second compaction shadows its own range and keeps every event", %{agent: agent} do
      messages =
        Enum.flat_map(1..4, fn i -> [Message.user("Q#{i}"), Message.assistant("A#{i}")] end)

      ctx = compaction_ctx(messages, keep_recent: 4)
      {ctx, _tools} = Nous.Plugins.Summarization.before_request(agent, ctx, [])

      assert Enum.map(ctx.messages, & &1.content) == [
               "[Conversation Summary]\ncompacted briefing",
               "Q3",
               "A3",
               "Q4",
               "A4"
             ]

      ctx = %{
        ctx
        | deps:
            Map.put(ctx.deps, :summarization_config, %{
              max_context_tokens: 1,
              keep_recent: 2,
              summary_count: 1
            }),
          usage: %Nous.Usage{total_tokens: 200}
      }

      {ctx, _tools} = Nous.Plugins.Summarization.before_request(agent, ctx, [])

      # The second summary shadows exactly the range it summarized, named in
      # surface positions: Q3 and A3 sat at seqs 4 and 5.
      assert List.last(Log.events(ctx.log)).data.surface_op == {:replace, 4, 5}

      # The earlier summary survives ahead of the new one because the plugin
      # splits system messages out of the conversation and keeps them, and a
      # summary is a system message. That is pre-existing behaviour — the old
      # list rewrite did the same — not something the log changed.
      assert Enum.map(ctx.messages, & &1.content) == [
               "[Conversation Summary]\ncompacted briefing",
               "[Conversation Summary]\ncompacted briefing",
               "Q4",
               "A4"
             ]

      # Eight originals plus two summaries: still nothing deleted.
      assert Log.count(ctx.log) == 10
      lockstep!(ctx)
    end
  end
end
