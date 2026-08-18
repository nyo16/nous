defmodule Nous.Plugins.LoopGuardTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Plugins.LoopGuard

  defp agent do
    %Nous.Agent{
      model: %Nous.Model{provider: :openai, model: "gpt-4"},
      tools: [],
      plugins: []
    }
  end

  defp start(deps \\ %{}) do
    %Context{messages: [Message.user("go")], deps: deps}
  end

  defp assistant_call(name, args) do
    Message.assistant("", tool_calls: [%{id: "call_1", name: name, arguments: args}])
  end

  # One model turn: the request, then what came back. `drive/2` appends these.
  defp turn(name, args, result \\ "ok") do
    [assistant_call(name, args), Message.tool("call_1", result, name: name)]
  end

  defp request(ctx) do
    {ctx, _tools} = LoopGuard.before_request(agent(), ctx, [])
    ctx
  end

  # The runner calls `before_request/3` once per iteration, each time on the
  # context the previous iteration produced. Feeding a pre-built transcript in one
  # shot would never exercise the advisory's effect on the *next* scan, which is
  # where the reset trap lives. N turns means N + 1 requests: the last one sees
  # the full chain.
  defp drive(turns, deps \\ %{}) do
    turns
    |> Enum.reduce(start(deps), fn turn, ctx -> Context.add_messages(request(ctx), turn) end)
    |> request()
  end

  defp advisories(%Context{messages: messages}) do
    Enum.filter(messages, &Message.get_metadata(&1, :loop_guard))
  end

  defp tool_contents(%Context{messages: messages}) do
    messages |> Enum.filter(&(&1.role == :tool)) |> Enum.map(& &1.content)
  end

  describe "thresholds" do
    test "three identical calls produce exactly one advisory" do
      ctx = drive(List.duplicate(turn("bash", %{"cmd" => "ls"}), 3))

      assert [advisory] = advisories(ctx)
      assert advisory.role == :user
      assert advisory.content =~ "3 times in a row"
      assert advisory.content =~ "`bash`"
    end

    test "a fourth identical call adds no second advisory" do
      ctx = drive(List.duplicate(turn("bash", %{"cmd" => "ls"}), 4))

      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "3 times in a row"
    end

    test "the injected advisory does not reset the chain it reports on" do
      ctx = drive(List.duplicate(turn("bash", %{"cmd" => "ls"}), 8))

      # Escalation reaches 5 and 8 only if the injected user-role advisory was
      # skipped by the next scan. Were it counted as a new instruction, the chain
      # would restart after each advisory and every one would read "3 times".
      assert [three, five, eight] = advisories(ctx)
      assert three.content =~ "3 times in a row"
      assert five.content =~ "5 times in a row"
      assert eight.content =~ "8 times in a row"

      assert Enum.map(advisories(ctx), &Message.get_metadata(&1, :loop_guard)) == [3, 5, 8]
    end

    test "the wording gets firmer at each threshold" do
      ctx = drive(List.duplicate(turn("bash", %{"cmd" => "ls"}), 8))

      assert [three, five, eight] = advisories(ctx)
      assert three.content =~ "Re-read what the previous result actually said"
      assert five.content =~ "Change approach now"
      assert eight.content =~ "Stop making this call"
    end

    test ":thresholds is configurable" do
      deps = %{loop_guard_config: %{thresholds: [2]}}
      ctx = drive(List.duplicate(turn("bash", %{"cmd" => "ls"}), 2), deps)

      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "2 times in a row"
    end
  end

  describe "what breaks a chain" do
    test "a differing argument resets the chain" do
      ls = turn("bash", %{"cmd" => "ls"})
      ctx = drive([ls, ls, turn("bash", %{"cmd" => "pwd"}), ls, ls])

      # Five bash calls, but never three of the same one in a row.
      assert advisories(ctx) == []
    end

    test "a new user message resets the chain" do
      ls = turn("bash", %{"cmd" => "ls"})
      ctx = drive([ls, ls, [Message.user("try something else")], ls, ls])

      assert advisories(ctx) == []
    end

    test "an injected system message does not reset the chain" do
      ls = turn("bash", %{"cmd" => "ls"})
      injected = [Message.system("[Relevant Knowledge]\nls lists a directory.")]
      ctx = drive([ls, ls, injected, ls])

      # Memory and KnowledgeBase inject system messages mid-conversation; the
      # guard must not depend on whether they are in the plugin list.
      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "3 times in a row"
    end

    test "a plain answer resets the chain" do
      ls = turn("bash", %{"cmd" => "ls"})
      ctx = drive([ls, ls, [Message.assistant("Nothing there.")], ls, ls])

      assert advisories(ctx) == []
    end
  end

  describe "argument canonicalization" do
    test "arguments differing only in key order are treated as identical" do
      # Providers may hand `arguments` over as the raw JSON string, where key
      # order is a byte difference for the same call.
      ctx =
        drive([
          turn("bash", ~s({"cmd":"ls","cwd":"/tmp"})),
          turn("bash", ~s({"cwd":"/tmp","cmd":"ls"})),
          turn("bash", ~s({"cmd":"ls","cwd":"/tmp"}))
        ])

      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "3 times in a row"
    end

    test "nested arguments differing in key order and key style are identical" do
      # The nested map is what a shallow canonicalizer gets wrong: it normalizes
      # the outer keys and leaves `%{since: ...}` atom-keyed, so it never matches
      # `%{"since" => ...}` and the chain silently resets.
      ctx =
        drive([
          turn("search", %{"filter" => %{"lang" => "ex", "since" => 2024}, "q" => "loop"}),
          turn("search", %{"q" => "loop", "filter" => %{since: 2024, lang: "ex"}}),
          turn("search", %{"filter" => %{"since" => 2024, "lang" => "ex"}, "q" => "loop"})
        ])

      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "3 times in a row"
    end

    test "a string argument value is not confused with the number it spells" do
      ctx =
        drive([
          turn("page", %{"n" => "2"}),
          turn("page", %{"n" => 2}),
          turn("page", %{"n" => "2"})
        ])

      assert advisories(ctx) == []
    end
  end

  describe "excluded tools" do
    @deps %{loop_guard_config: %{excluded_tools: ["todo_write"]}}

    test "an excluded tool between two identical calls neither increments nor resets" do
      ls = turn("bash", %{"cmd" => "ls"})
      bookkeeping = turn("todo_write", %{"items" => ["check ls"]})
      ctx = drive([ls, ls, bookkeeping, ls], @deps)

      # Resetting would leave a chain of 1 and no advisory at all; incrementing
      # would report four calls instead of the three that were actually repeated.
      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "3 times in a row"
      assert advisory.content =~ "`bash`"
    end

    test "an excluded call after an advisory does not re-announce the same threshold" do
      ls = turn("bash", %{"cmd" => "ls"})
      ctx = drive([ls, ls, ls, turn("todo_write", %{"items" => ["x"]})], @deps)

      # The excluded call leaves the chain at 3, so the next request observes the
      # same length again. Firing on "chain is a threshold" alone would announce
      # 3 twice; the threshold recorded in the advisory's own metadata is what
      # makes "already announced" derivable.
      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "3 times in a row"
    end

    test "a run of excluded calls never triggers an advisory" do
      ctx = drive(List.duplicate(turn("todo_write", %{"items" => ["x"]}), 5), @deps)

      assert advisories(ctx) == []
    end

    test "exclusion is case-insensitive" do
      ls = turn("bash", %{"cmd" => "ls"})
      ctx = drive([ls, ls, turn("TODO_Write", %{"items" => ["x"]}), ls], @deps)

      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "3 times in a row"
    end
  end

  describe "denied calls" do
    test "a denied call still counts toward the chain" do
      denial =
        "Error: tool 'bash' requires approval and the request was denied."

      denied = turn("bash", %{"cmd" => "rm -rf /"}, denial)
      ctx = drive([denied, denied, denied])

      # The chain is read off the requests, not the results: a model retrying a
      # call it is not permitted to make is the loop worth catching.
      assert [advisory] = advisories(ctx)
      assert advisory.content =~ "3 times in a row"
      assert tool_contents(ctx) == List.duplicate(denial, 3)
    end
  end

  describe "the transcript stays true" do
    test "the advisory is a separate message and the tool results are byte-identical" do
      transcript = List.flatten(List.duplicate(turn("bash", %{"cmd" => "ls"}), 3))
      quiet = Context.add_messages(start(), transcript)
      loud = request(quiet)

      assert [advisory] = advisories(loud)

      # Appended, never merged into or wrapped around anything already there.
      assert loud.messages == quiet.messages ++ [advisory]

      # And the results the tool actually returned are untouched — only the pair
      # of assertions rules out an advisory smuggled into a result's content.
      assert tool_contents(quiet) == ["ok", "ok", "ok"]
      assert tool_contents(loud) == tool_contents(quiet)
    end

    test "a conversation with no repeats is returned untouched" do
      quiet =
        Context.add_messages(start(), [
          assistant_call("bash", %{"cmd" => "ls"}),
          Message.tool("call_1", "a.ex", name: "bash"),
          assistant_call("file_read", %{"path" => "a.ex"}),
          Message.tool("call_1", "defmodule A do end", name: "file_read"),
          Message.assistant("Here you go.")
        ])

      assert request(quiet).messages == quiet.messages
    end

    test "guidance only: the tool list and needs_response pass through" do
      transcript = List.flatten(List.duplicate(turn("bash", %{"cmd" => "ls"}), 3))
      ctx = Context.add_messages(start(), transcript)

      tool = %Nous.Tool{
        name: "bash",
        description: "Run a command",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        function: fn _ctx, _args -> "ok" end
      }

      {guarded, tools} = LoopGuard.before_request(agent(), ctx, [tool])

      assert tools == [tool]
      assert [_advisory] = advisories(guarded)
      # Blocking a looping model is a separate decision: the run continues.
      assert guarded.needs_response
    end
  end
end
