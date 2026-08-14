defmodule Nous.Session.InvariantTest do
  @moduledoc """
  Phase C: every model-visible request is reconstructable from the session log.

  Two halves. The pure half pins the comparison rule — including what the
  system-prompt overlay is and is not allowed to excuse, because an exemption
  that is merely permissive would make the whole check decorative. The wired
  half drives real agent runs through `Nous.ModelDispatcher.put_dispatcher/1`
  and asserts the checker stays silent, which is the plan's verification item
  and the only thing that proves the migrated bypass sites actually hold.
  """

  # async: false — the mode tests write `config :nous, :session_invariant`, which
  # is global. ExUnit runs sync modules after every async one, so nothing else is
  # in flight; each test restores the previous value in `on_exit`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nous.Agent.Context
  alias Nous.AgentRunner.RequestDispatch
  alias Nous.Session.Invariant
  alias Nous.{Message, Tool, Usage}

  @moduletag :capture_log

  doctest Nous.Session.Invariant

  # Two-step run: the first response calls a tool, the second concludes — the
  # shape that puts every surface role into one request. Stateless, so the
  # dispatcher override is all the isolation this needs.
  defmodule ToolThenTextDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      response =
        cond do
          summary_request?(messages) ->
            Message.assistant("the older conversation, in brief")

          Enum.count(messages, &(&1.role == :assistant)) == 0 ->
            Message.assistant("",
              tool_calls: [
                %{"id" => "call_fixed_1", "name" => "echo", "arguments" => %{"text" => "hello"}}
              ]
            )

          true ->
            Message.assistant("done: hello")
        end

      usage = %Usage{input_tokens: 11, output_tokens: 7, total_tokens: 18, requests: 1}
      {:ok, %{response | metadata: %{usage: usage}}}
    end

    # Nous.Plugins.Summarization appends its instruction as the final user turn.
    # Answering that with the tool call this stub otherwise returns would make
    # every summarization fail as :empty_summary, and the compaction test would
    # assert on a compaction that never happened.
    defp summary_request?(messages) do
      case List.last(messages) do
        %Message{role: :user, content: content} when is_binary(content) ->
          String.starts_with?(content, "Summarize the conversation above")

        _other ->
          false
      end
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 42
  end

  # A rogue request builder: the assembled list carries a message the transcript
  # never had. This is the canary — it fails if the check is not actually wired
  # in where requests are assembled.
  #
  # It has to diverge at *assembly* time. A plugin that writes
  # `%{ctx | messages: ...}` directly cannot be used here: `Context.sync/1`
  # reseeds the log from whatever the caller assembled on the next append, and
  # the loop appends a `:step_start` before every request, so by dispatch the
  # fold already agrees with the request.
  defmodule GhostRequestBehaviour do
    @moduledoc false
    @behaviour Nous.Agent.Behaviour

    alias Nous.Agents.BasicAgent

    @impl true
    def build_messages(agent, ctx) do
      BasicAgent.build_messages(agent, ctx) ++ [Message.user("ghost, never logged")]
    end

    @impl true
    def get_tools(agent), do: BasicAgent.get_tools(agent)

    @impl true
    def process_response(agent, response, ctx),
      do: BasicAgent.process_response(agent, response, ctx)

    @impl true
    def extract_output(agent, ctx), do: BasicAgent.extract_output(agent, ctx)
  end

  defp echo_tool do
    %Tool{
      name: "echo",
      description: "Echo the text back",
      parameters: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      function: fn _ctx, %{"text" => text} -> "echoed:#{text}" end
    }
  end

  defp agent(opts \\ []) do
    Nous.new(
      "openai:gpt-4o",
      Keyword.merge(
        [name: "invariant", system_prompt: "You are terse.", tools: [echo_tool()]],
        opts
      )
    )
  end

  defp ctx_with(messages) do
    Enum.reduce(messages, Context.new(), fn message, ctx ->
      Context.add_message(ctx, message)
    end)
  end

  # A complete tool-calling transcript: the fold and the request agree, and the
  # tool result is properly paired.
  defp full_transcript do
    ctx_with([
      Message.system("You are terse."),
      Message.user("say hello"),
      Message.assistant("", tool_calls: [%{"id" => "call_1", "name" => "echo"}]),
      Message.tool("call_1", "echoed:hello"),
      Message.assistant("done: hello")
    ])
  end

  defp put_mode(mode) do
    previous = Application.fetch_env(:nous, :session_invariant)
    Application.put_env(:nous, :session_invariant, mode)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:nous, :session_invariant, value)
        :error -> Application.delete_env(:nous, :session_invariant)
      end
    end)
  end

  defp attach_violations do
    handler_id = {__MODULE__, :violations, System.unique_integer()}
    test = self()

    :telemetry.attach(
      handler_id,
      Invariant.violation_event(),
      fn _event, measurements, metadata, _config ->
        send(test, {:violation, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "check/2 accepts a request that is the fold" do
    test "a complete tool-calling transcript" do
      ctx = full_transcript()

      assert Invariant.check(ctx, ctx.messages) == :ok
    end

    test "an empty transcript" do
      assert Invariant.check(Context.new(), []) == :ok
    end

    test "with the overlay concatenated onto the leading system message" do
      ctx = Context.put_system_prompt_overlay(full_transcript(), "## Plugin fragment")

      # The overlay really is applied — otherwise this proves nothing.
      assert hd(ctx.messages).content == "You are terse.\n\n## Plugin fragment"
      assert length(ctx.messages) == length(Nous.Session.Log.derive_messages(ctx.log))

      assert Invariant.check(ctx, ctx.messages) == :ok
    end

    test "with the overlay prepended as a system message no event produced" do
      ctx =
        [Message.user("say hello"), Message.assistant("hi")]
        |> ctx_with()
        |> Context.put_system_prompt_overlay("## Plugin fragment")

      # One message longer than the fold, and that extra head is the overlay.
      assert length(ctx.messages) == length(Nous.Session.Log.derive_messages(ctx.log)) + 1
      assert hd(ctx.messages).role == :system
      assert hd(ctx.messages).content == "## Plugin fragment"

      assert Invariant.check(ctx, ctx.messages) == :ok
    end

    test "with a behaviour's own assembled system prompt substituted wholesale" do
      # What ReactAgent and KnowledgeBaseAgent do: reject the transcript's system
      # messages, prepend a freshly built one. Same shape, different text.
      ctx = full_transcript()
      [_original | rest] = ctx.messages
      request = [Message.system("Answer as a ReAct loop. Thought/Action/Observation.") | rest]

      assert Invariant.check(ctx, request) == :ok
    end
  end

  describe "check/2 detects each violation class" do
    test "a message in the request that no event produced" do
      ctx = full_transcript()
      request = ctx.messages ++ [Message.user("ghost")]

      assert {:violation, details} = Invariant.check(ctx, request)
      assert details.kind == :extra_message
      assert details.index == 5
      assert details.request_length == 6
      assert details.log_length == 5
      assert [%{role: :user, preview: "ghost"}] = details.extra
      assert details.missing == []
    end

    test "an event-derived message missing from the request" do
      ctx = full_transcript()
      request = List.delete_at(ctx.messages, 1)

      assert {:violation, details} = Invariant.check(ctx, request)
      assert details.kind == :missing_message
      assert details.index == 1
      assert [%{role: :user, preview: "say hello"}] = details.missing
    end

    test "the two lists in a different order" do
      ctx = ctx_with([Message.user("first"), Message.assistant("second")])

      assert {:violation, details} = Invariant.check(ctx, Enum.reverse(ctx.messages))
      assert details.kind == :order
      assert details.index == 0
      assert details.extra == []
      assert details.missing == []
      assert details.request_length == details.log_length
    end

    test "an orphaned tool result — no preceding assistant asked for it" do
      ctx = ctx_with([Message.user("hi"), Message.tool("call_missing", "result")])

      assert Invariant.check(ctx, ctx.messages) ==
               {:violation, %{kind: :orphaned_tool_result, tool_call_id: "call_missing"}}
    end

    test "a tool result paired with a LATER tool call is still orphaned" do
      ctx =
        ctx_with([
          Message.assistant("thinking"),
          Message.tool("call_1", "result"),
          Message.assistant("", tool_calls: [%{"id" => "call_1", "name" => "echo"}])
        ])

      assert {:violation, %{kind: :orphaned_tool_result, tool_call_id: "call_1"}} =
               Invariant.check(ctx, ctx.messages)
    end

    test "a request that diverges from the fold is reported before pairing" do
      # Both wrong at once: the diagnosis names the reconstruction failure,
      # because the pairing verdict is about a list already known to be wrong.
      ctx = full_transcript()
      request = ctx.messages ++ [Message.tool("call_nope", "result")]

      assert {:violation, %{kind: :extra_message}} = Invariant.check(ctx, request)
    end
  end

  describe "the overlay exemption is bounded, not permissive" do
    test "a second system message the fold does not have is still a violation" do
      ctx = Context.put_system_prompt_overlay(full_transcript(), "## Plugin fragment")
      request = [Message.system("smuggled") | ctx.messages]

      assert {:violation, %{kind: :extra_message, extra: [%{role: :system}]}} =
               Invariant.check(ctx, request)
    end

    test "the overlay does not excuse a dropped user message" do
      ctx =
        [Message.user("say hello")]
        |> ctx_with()
        |> Context.put_system_prompt_overlay("## Plugin fragment")

      assert {:violation, %{kind: :missing_message}} =
               Invariant.check(ctx, [hd(ctx.messages)])
    end

    test "rewritten user content is a violation even under an overlay" do
      ctx = Context.put_system_prompt_overlay(full_transcript(), "## Plugin fragment")

      request =
        List.update_at(ctx.messages, 1, fn user -> %{user | content: "say goodbye"} end)

      assert {:violation, details} = Invariant.check(ctx, request)
      assert details.kind == :missing_message
      assert details.index == 1
      assert [%{preview: "say goodbye"}] = details.extra
      assert [%{preview: "say hello"}] = details.missing
    end

    test "a mid-transcript system message the request dropped is a violation" do
      # A Summarization summary is a system message standing in for everything it
      # shadowed. Dropping it from the request loses that history silently.
      ctx =
        ctx_with([
          Message.system("You are terse."),
          Message.user("say hello"),
          Message.system("[Conversation Summary] ..."),
          Message.assistant("done")
        ])

      assert {:violation, %{kind: :missing_message}} =
               Invariant.check(ctx, List.delete_at(ctx.messages, 2))
    end
  end

  describe "verify/2 modes" do
    test ":warn emits telemetry and logs, and never raises" do
      put_mode(:warn)
      attach_violations()
      ctx = full_transcript()

      log =
        capture_log(fn ->
          assert Invariant.verify(ctx, ctx.messages ++ [Message.user("ghost")]) == :ok
        end)

      assert log =~ "not reconstructable"
      assert_received {:violation, %{count: 1}, metadata}
      assert metadata.kind == :extra_message
      assert metadata.mode == :warn
      assert metadata.agent_name == ctx.agent_name
    end

    test ":warn is the default with nothing configured" do
      previous = Application.fetch_env(:nous, :session_invariant)
      Application.delete_env(:nous, :session_invariant)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:nous, :session_invariant, value)
          :error -> Application.delete_env(:nous, :session_invariant)
        end
      end)

      assert Invariant.mode() == :warn
    end

    test ":strict raises, after emitting telemetry" do
      put_mode(:strict)
      attach_violations()
      ctx = full_transcript()

      assert_raise Invariant.Violation, fn -> Invariant.verify(ctx, []) end

      assert_received {:violation, %{count: 1}, metadata}
      assert metadata.mode == :strict
      assert metadata.kind == :missing_message
    end

    test ":strict stays quiet when the request is the fold" do
      put_mode(:strict)
      ctx = full_transcript()

      assert Invariant.verify(ctx, ctx.messages) == :ok
    end

    test ":off does no work at all" do
      attach_violations()
      # A log the fold cannot possibly read: touching it raises. That is the
      # instrument — `:off` must short-circuit before the fold, not after.
      broken = %Context{log: :not_a_log}
      request = [Message.user("hi")]

      put_mode(:warn)
      assert_raise FunctionClauseError, fn -> Invariant.verify(broken, request) end

      put_mode(:off)
      assert Invariant.verify(broken, request) == :ok
      refute_received {:violation, _, _}
    end

    test "a mode from a string config is coerced, never String.to_atom/1'd" do
      put_mode("strict")
      assert Invariant.mode() == :strict
    end

    test "an invalid mode falls back to :warn instead of taking down the run" do
      put_mode(:definitely_not_a_mode)
      assert Invariant.mode() == :warn

      ctx = full_transcript()
      assert Invariant.verify(ctx, ctx.messages) == :ok
    end

    test "no context in scope is a no-op" do
      put_mode(:strict)
      assert Invariant.verify(nil, [Message.user("hi")]) == :ok
    end
  end

  describe "the dispatch site" do
    setup do
      Nous.ModelDispatcher.put_dispatcher(ToolThenTextDispatcher)
      attach_violations()
      put_mode(:warn)
      :ok
    end

    test "request_with_fallback/5 checks the list it is about to send" do
      ctx = full_transcript()
      request = ctx.messages ++ [Message.user("ghost")]

      log =
        capture_log(fn ->
          assert {:ok, %Message{}, _model} =
                   RequestDispatch.request_with_fallback(agent(), request, %{}, [], ctx)
        end)

      assert log =~ "not reconstructable"
      assert_received {:violation, _measurements, %{kind: :extra_message}}
    end

    test "stream_request_with_fallback/5 checks before it opens the stream" do
      ctx = full_transcript()
      request = ctx.messages ++ [Message.user("ghost")]

      capture_log(fn ->
        RequestDispatch.stream_request_with_fallback(agent(), request, %{}, [], ctx)
      end)

      assert_received {:violation, _measurements, %{kind: :extra_message}}
    end

    test "no check without a context, so run_stream/3's path cannot crash on one" do
      ctx = full_transcript()
      request = ctx.messages ++ [Message.user("ghost")]
      put_mode(:strict)

      assert {:ok, %Message{}, _model} =
               RequestDispatch.request_with_fallback(agent(), request, %{}, [])

      refute_received {:violation, _, _}
    end
  end

  describe "a full agent run" do
    setup do
      Nous.ModelDispatcher.put_dispatcher(ToolThenTextDispatcher)
      attach_violations()
      :ok
    end

    test "a two-step tool-calling run raises no violation, even in :strict" do
      put_mode(:strict)

      assert {:ok, result} = Nous.run(agent(), "say hello")

      # The run really did every step: system, user, tool-calling assistant,
      # tool result, final assistant.
      assert Enum.map(result.all_messages, & &1.role) ==
               [:system, :user, :assistant, :tool, :assistant]

      refute_received {:violation, _, _}
    end

    test "a run whose assembled request diverges from the log IS caught" do
      # The canary for the wiring: if the check is not called where requests are
      # assembled, this run looks clean and every other test here proves nothing.
      put_mode(:warn)

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   Nous.run(agent(behaviour_module: GhostRequestBehaviour), "say hello")
        end)

      assert log =~ "not reconstructable"
      assert_received {:violation, _measurements, metadata}
      assert metadata.kind == :extra_message
      assert [%{role: :user, preview: "ghost, never logged"}] = metadata.extra
    end

    test "a run that compacts mid-flight raises no violation" do
      put_mode(:strict)

      assert {:ok, result} =
               Nous.run(agent(plugins: [Nous.Plugins.Summarization]), "say hello",
                 deps: %{
                   summarization_config: %{max_context_tokens: 1, keep_recent: 2}
                 }
               )

      # Compaction really happened: a summary stands where the user turn was,
      # and the log still holds every original event.
      assert Enum.any?(result.all_messages, fn message ->
               message.role == :system and message.content =~ "[Conversation Summary]"
             end)

      refute Enum.any?(result.all_messages, &(&1.content == "say hello"))
      assert Nous.Session.Log.count(result.context.log) > length(result.all_messages)

      refute_received {:violation, _, _}
    end
  end
end
