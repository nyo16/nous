# Transcripts

A transcript is the ordered list of `Nous.Message` structs that make up a
conversation. `Nous.Transcript` is the toolbox for keeping that list a
manageable size -- measuring it, deciding when it is too long, and compacting
older turns into a summary without an LLM call.

## What a transcript is

There is no `%Nous.Transcript{}` struct. A transcript is a plain
`[Nous.Message.t()]`, and every function in `Nous.Transcript` takes that list
and returns a new one. Nothing is mutated and nothing is stored.

Every run hands you one:

| Source | Contents |
|--------|----------|
| `result.all_messages` | The full conversation, including the system prompt and every tool result |
| `result.new_messages` | Only the messages added from the first assistant reply onward |
| `result.context.messages` | Same list as `all_messages`, reachable from the `Nous.Agent.Context` you can serialize and resume |
| `Nous.AgentServer.get_history/1` | The live message list held by a long-running agent process |

```elixir
{:ok, result} = Nous.run(agent, "Summarize the last quarter")

result.all_messages
#=> [%Nous.Message{role: :system, ...}, %Nous.Message{role: :user, ...}, ...]
```

Note that `Nous.run/3` returns `all_messages`/`new_messages`, not a
`messages` key. Whichever list you hold onto, it is the same shape that
`Nous.Transcript` and `Nous.Messages` operate on, and the same shape you pass
back in via `messages:` to continue a conversation.

Compaction is opt-in: the agent loop never calls `Nous.Transcript` for you. For
automatic, LLM-powered summarization inside the loop, add the
`Nous.Plugins.Summarization` plugin instead.

## Building a transcript

Construct messages with the `Nous.Message` builders, or take the list a run
gives you:

```elixir
transcript = [
  Nous.Message.system("You are a terse assistant."),
  Nous.Message.user("What is the capital of France?"),
  Nous.Message.assistant("Paris.")
]
```

Tool turns are two messages -- the assistant message carrying the call, and the
`:tool` message carrying its result:

```elixir
transcript = [
  Nous.Message.user("What is the weather in Paris?"),
  Nous.Message.assistant("Checking.",
    tool_calls: [%{id: "call_1", name: "get_weather", arguments: %{"city" => "Paris"}}]
  ),
  Nous.Message.tool("call_1", "18C, clear", name: "get_weather")
]
```

Feed a transcript back into a new run to continue it:

```elixir
{:ok, result} = Nous.run(agent, messages: transcript ++ [Nous.Message.user("And tomorrow?")])
```

## Measuring a transcript

### `estimate_tokens/1`

Rough token count for a single string: UTF-8 byte length divided by four.
Accepts `nil` and `""`.

```elixir
Nous.Transcript.estimate_tokens("Hello world")
#=> 2

Nous.Transcript.estimate_tokens("Hello world, how are you?")
#=> 6

Nous.Transcript.estimate_tokens(nil)
#=> 0
```

This is deliberately cheap, not accurate -- it is a byte ratio, not a
tokenizer. Four bytes per token is a passable average for English prose; it
under-counts code and JSON and heavily over-counts CJK. Use a real tokenizer
when you need to be exact; use this when you need a decision in microseconds.
It is the same arithmetic the agent runner uses for its pre-request token
reservation, so the two never disagree.

### `estimate_messages_tokens/1`

Sums the text of every message in bytes, then divides once -- so it matches
`estimate_tokens/1` on the concatenated text instead of accumulating a
rounding error per message.

```elixir
messages = [Nous.Message.user("Hello"), Nous.Message.assistant("Hi there")]

Nous.Transcript.estimate_messages_tokens(messages)
#=> 3
```

### `should_compact?/2`

A message-count predicate: `true` when the list is longer than
`compact_after`.

```elixir
messages = for i <- 1..25, do: Nous.Message.user("msg #{i}")

Nous.Transcript.should_compact?(messages, 20)
#=> true
```

## Compacting a transcript

### `compact/2`

Keeps the last `keep_last` messages and replaces everything older with a single
`:system` summary message.

```elixir
messages = for i <- 1..20, do: Nous.Message.user("Message #{i}")

compacted = Nous.Transcript.compact(messages, 10)
length(compacted)
#=> 11
```

What it guarantees:

- **Leading system messages survive.** Any run of `:system` messages at the head
  of the list is preserved verbatim and sits in front of the summary, so the
  system prompt is never summarized away.
- **The list is returned untouched** when it is already short enough --
  `length(messages) <= keep_last`, or when the non-system remainder fits in
  `keep_last`.
- **Tool pairs are never split.** If the kept tail would begin with orphan
  `:tool` results whose assistant message fell into the summarized half, those
  results are pulled back into the summarized half. The tail can therefore be
  slightly shorter than `keep_last`, but it never opens with a tool result the
  provider cannot match -- Anthropic, OpenAI and Gemini all return a 400 for
  that.
- **Tool output is not echoed into the summary.** Tool results are replaced with
  a structural marker, `[tool] <result for "get_weather" omitted from summary>`,
  because the summary becomes a durable system message and tool results
  routinely carry keys and PII. Other roles get a one-line preview of their
  first ~100 characters.

The summary message looks like this:

```elixir
summary = List.first(Nous.Messages.find_by_role(compacted, :system))

summary.content
#=> "[Compacted 10 earlier messages]\n  [user] Message 1\n  [user] Message 2\n..."
```

`keep_last` must be a positive integer; any other value raises
`FunctionClauseError` for a list long enough to need compacting.

### `maybe_compact/2`

Compacts only when a trigger fires, otherwise returns the list unchanged. This
is the function you call on every turn.

| Option | Type | Default | Effect |
|--------|------|---------|--------|
| `:keep_last` | `pos_integer()` | (required) | How many recent messages to keep |
| `:every` | `pos_integer()` | `nil` | Trigger when message count exceeds this number |
| `:token_budget` | `pos_integer()` | `nil` | Total token budget for the conversation |
| `:threshold` | `float()` | `0.8` | Fraction of `:token_budget` that triggers compaction |

Triggers are OR'd -- whichever fires first wins. With neither `:every` nor
`:token_budget` set nothing ever triggers, and a missing `:keep_last` raises
`KeyError`.

```elixir
# Compact every 20 messages
messages = Nous.Transcript.maybe_compact(messages, every: 20, keep_last: 10)

# Compact at 80% of a 128k token budget
messages = Nous.Transcript.maybe_compact(messages,
  token_budget: 128_000,
  keep_last: 10
)

# Both triggers, custom threshold
messages = Nous.Transcript.maybe_compact(messages,
  every: 30,
  token_budget: 128_000,
  threshold: 0.75,
  keep_last: 10
)
```

In a long-lived process, that is a one-liner per turn:

```elixir
defmodule ChatSession do
  use GenServer

  @impl true
  def handle_info({:agent_complete, result}, state) do
    messages = Nous.Transcript.maybe_compact(result.all_messages,
      every: 40,
      token_budget: 128_000,
      keep_last: 12
    )

    {:noreply, %{state | messages: messages}}
  end
end
```

### Asynchronous compaction

Compaction is pure Elixir, but on a very long transcript it is still work you
may not want on the critical path. Three functions move it onto a task under
`Nous.TaskSupervisor`, which the `:nous` application starts for you.

`compact_async/2` returns a `Task` you await:

```elixir
task = Nous.Transcript.compact_async(messages, 10)
# ... do other work ...
compacted = Task.await(task)
```

`compact_async/3` is fire-and-forget with a callback receiving the compacted
list, and returns `{:ok, pid}`:

```elixir
parent = self()

{:ok, _pid} =
  Nous.Transcript.compact_async(messages, 10, fn compacted ->
    send(parent, {:transcript_compacted, compacted})
  end)
```

`maybe_compact_async/3` is the trigger-aware version. It takes the same options
as `maybe_compact/2` and calls back with `{:compacted, messages}` or
`{:unchanged, messages}`, so the caller always learns the outcome:

```elixir
parent = self()

{:ok, _pid} =
  Nous.Transcript.maybe_compact_async(
    messages,
    [every: 20, keep_last: 10],
    fn
      {:compacted, msgs} -> send(parent, {:transcript_compacted, msgs})
      {:unchanged, _msgs} -> :ok
    end
  )
```

Inside a GenServer this is the safe pattern: hand the current list to the task,
keep serving calls, and swap the list in when the message arrives.

## API summary

| Function | Returns | Purpose |
|----------|---------|---------|
| `compact/2` | `[Message.t()]` | Keep the last N messages, summarize the rest |
| `maybe_compact/2` | `[Message.t()]` | `compact/2` behind a count and/or token trigger |
| `compact_async/2` | `Task.t()` | `compact/2` on a supervised task, awaitable |
| `compact_async/3` | `{:ok, pid()}` | `compact/2` on a supervised task, with a callback |
| `maybe_compact_async/3` | `{:ok, pid()}` | `maybe_compact/2` on a task, callback gets `{:compacted \| :unchanged, msgs}` |
| `prune_tool_results/2` | `[Message.t()]` | Truncate oversized tool results in place; count and order preserved |
| `balance_tool_call_boundary/2` | `{[Message.t()], [Message.t()]}` | Move an `{old, recent}` boundary off a `tool_call`/`tool_result` pair |
| `estimate_tokens/1` | `non_neg_integer()` | Coarse byte-ratio token estimate for a string |
| `estimate_messages_tokens/1` | `non_neg_integer()` | Same estimate summed over a message list |
| `should_compact?/2` | `boolean()` | Is the list longer than this message count? |

## When you would reach for a transcript

### Rendering a conversation

Drop the system prompt and the tool plumbing, and render what a human said and
what the model said back:

```elixir
defmodule ChatView do
  def render(messages) do
    messages
    |> Enum.reject(&Nous.Message.is_system?/1)
    |> Enum.reject(&Nous.Message.is_tool_related?/1)
    |> Enum.map_join("\n\n", fn msg ->
      "#{msg.role}: #{Nous.Message.extract_text(msg)}"
    end)
  end
end
```

### Debugging a tool loop

When an agent burns its iteration budget, the transcript is the evidence.
`Nous.Messages` has the readers:

```elixir
{:ok, result} = Nous.run(agent, "Find and book a flight")

Nous.Messages.count_by_role(result.all_messages)
#=> %{system: 1, user: 1, assistant: 4, tool: 4}

result.all_messages
|> Nous.Messages.extract_tool_calls()
|> Enum.map(&Nous.ToolCall.field(&1, :name))
#=> ["search_flights", "search_flights", "search_flights", "book_flight"]
```

Three identical `search_flights` calls in a row is a prompt problem, not a tool
problem. Pair this with `result.iterations` to see how much of the budget the
loop consumed.

### Exporting a run

Transcripts are plain structs, so an export is a `map/2` away:

```elixir
export =
  Enum.map(result.all_messages, fn msg ->
    %{
      role: msg.role,
      content: Nous.Message.extract_text(msg),
      tool_calls: msg.tool_calls,
      at: msg.created_at
    }
  end)

File.write!("run.json", JSON.encode!(export))
```

To persist and later *resume* a run rather than just archive it, serialize the
whole `Nous.Agent.Context` instead -- see
[Context & Dependencies](context.md).

## Related Resources

- [Context & Dependencies](context.md) -- `Agent.Context`, serialization, and resuming a run
- [Memory](memory.md) -- durable recall across runs, as opposed to in-conversation history
- [Phoenix LiveView Integration](liveview-integration.md) -- streaming a transcript to the browser
- [Production Best Practices](best_practices.md) -- context-window budgeting in production
