# Message construction fast path (perf-analysis Phase 2).
#
# The role helpers (system/user/assistant/tool) construct %Message{} directly
# via build/1; new!/1 keeps the full Ecto changeset path for external attrs.
# Helpers used to delegate to new!/1, so "helper vs new!/1" is the
# before/after comparison — re-run after touching Message construction to
# guard the win.
#
#   Run: mix run bench/message_bench.exs   (benchee is a :dev dependency)

alias Nous.Message

user_content = "What is the weather in Paris today? " <> String.duplicate("context ", 15)

tool_calls = [
  %{"id" => "call_1", "name" => "search", "arguments" => %{"q" => "elixir", "k" => 5}}
]

tool_result = "result: " <> String.duplicate("x", 120)

jobs = %{
  "user helper (direct build)" => fn ->
    Message.user(user_content)
  end,
  "user via new!/1 (changeset)" => fn ->
    Message.new!(%{role: :user, content: user_content})
  end,
  "assistant+tool_calls helper (direct build)" => fn ->
    Message.assistant("Searching", tool_calls: tool_calls)
  end,
  "assistant+tool_calls via new!/1 (changeset)" => fn ->
    Message.new!(%{role: :assistant, content: "Searching", tool_calls: tool_calls})
  end,
  "tool helper (direct build)" => fn ->
    Message.tool("call_1", tool_result, name: "search")
  end,
  "tool via new!/1 (changeset)" => fn ->
    Message.new!(%{role: :tool, content: tool_result, tool_call_id: "call_1", name: "search"})
  end
}

Benchee.run(jobs, warmup: 1, time: 3, memory_time: 1, print: [fast_warning: false])

# ---------------------------------------------------------------------------
# Transcript appends (plan 03 phase B).
#
# `ctx.messages` used to be a list the runner appended to with `++ [msg]`; it is
# now a view materialized from the session event log after every append. Plan 03
# flags that as the change's main performance risk, so the pre-log `++ [msg]` is
# benchmarked beside the new path at two transcript sizes, plus the sequential
# case, which is where a super-linear append would show up.
#
#   Run: mix run bench/message_bench.exs

alias Nous.Agent.Context

transcript = fn n ->
  Enum.map(1..n, fn i -> Message.user("turn #{i} " <> String.duplicate("context ", 12)) end)
end

small = transcript.(10)
large = transcript.(200)

ctx_small = Context.new(messages: small)
ctx_large = Context.new(messages: large)

reply = Message.assistant("reply")
batch = Enum.map(1..10, fn i -> Message.user("batch #{i}") end)

sequential = fn append, start ->
  fn -> Enum.reduce(1..50, start.(), fn i, acc -> append.(acc, Message.user("m#{i}")) end) end
end

append_jobs = %{
  "add_message/2 @10 (log fold)" => fn -> Context.add_message(ctx_small, reply) end,
  "++ [msg] @10 (pre-log baseline)" => fn -> small ++ [reply] end,
  "add_message/2 @200 (log fold)" => fn -> Context.add_message(ctx_large, reply) end,
  "++ [msg] @200 (pre-log baseline)" => fn -> large ++ [reply] end,
  "add_messages/2 x10 @200 (log fold)" => fn -> Context.add_messages(ctx_large, batch) end,
  "++ batch x10 @200 (pre-log baseline)" => fn -> large ++ batch end,
  "50 sequential add_message/2 (log fold)" =>
    sequential.(&Context.add_message/2, fn -> Context.new() end),
  "50 sequential ++ [msg] (pre-log baseline)" =>
    sequential.(fn acc, msg -> acc ++ [msg] end, fn -> [] end),
  "Context.new(messages: 200) (seed + fold)" => fn -> Context.new(messages: large) end
}

Benchee.run(append_jobs, warmup: 1, time: 3, memory_time: 1, print: [fast_warning: false])
