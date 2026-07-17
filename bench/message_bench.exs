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
