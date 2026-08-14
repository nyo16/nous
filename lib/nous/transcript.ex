defmodule Nous.Transcript do
  @moduledoc """
  Lightweight conversation history compaction.

  Provides utility functions for managing conversation message lists
  without requiring an LLM call. For LLM-powered summarization,
  see `Nous.Plugins.Summarization`.

  ## Usage

      messages = [msg1, msg2, msg3, ..., msg20]

      # Keep last 10 messages, summarize the rest
      compacted = Nous.Transcript.compact(messages, 10)

      # Auto-compact: every 20 messages, keep last 10
      compacted = Nous.Transcript.maybe_compact(messages, every: 20, keep_last: 10)

      # Auto-compact: at 80% of token budget
      compacted = Nous.Transcript.maybe_compact(messages,
        token_budget: 128_000,
        keep_last: 10
      )

      # Both triggers (whichever fires first)
      compacted = Nous.Transcript.maybe_compact(messages,
        every: 30,
        token_budget: 128_000,
        threshold: 0.8,
        keep_last: 10
      )

      # Run compaction in the background (returns a Task)
      task = Nous.Transcript.compact_async(messages, 10)
      compacted = Task.await(task)

      # Fire-and-forget with callback
      Nous.Transcript.compact_async(messages, 10, fn compacted ->
        send(self(), {:compacted, compacted})
      end)

      # Prune oversized tool results in place (no LLM, no reordering)
      pruned = Nous.Transcript.prune_tool_results(messages, 8192)

      # Estimate token count (coarse ~4-bytes-per-token heuristic)
      tokens = Nous.Transcript.estimate_tokens("Hello world, how are you?")
      #=> 6

  ## Token estimates are coarse

  `estimate_tokens/1` and `estimate_messages_tokens/1` divide UTF-8 byte
  length by 4. That ratio is roughly right for English prose and
  systematically wrong elsewhere: it under-counts code and JSON (dense in
  punctuation, which tokenizes finely) and badly over-counts CJK text (3
  bytes per character, often ~1 token per character). Both `maybe_compact/2`
  triggers are built on it, so `:token_budget` is approximate in both
  directions — size the budget with headroom, or measure with a real
  tokenizer and drive compaction from `compact/2` directly.

  """

  alias Nous.Message

  # Pruning budget. 8 KiB is roughly two pages of output — past that a tool
  # result is almost always a dump, and the head/tail split (4:1, matching
  # where signal sits in logs and file reads) preserves what a model needs
  # to decide what to do next.
  @default_max_result_chars 8192
  @prune_head_chars 4096
  @prune_tail_chars 1024

  @doc """
  Compacts a message list by keeping the last `keep_last` messages.

  If messages exceed the threshold, older messages are replaced with a
  summary system message. System messages at the start are always preserved.

  Returns the original list if it's already within the limit.

  ## Examples

      iex> messages = for i <- 1..20, do: Nous.Message.user("Message \#{i}")
      iex> compacted = Nous.Transcript.compact(messages, 10)
      iex> length(compacted)
      11

  """
  @spec compact([Message.t()], pos_integer()) :: [Message.t()]
  def compact(messages, keep_last) when length(messages) <= keep_last do
    messages
  end

  def compact(messages, keep_last) when is_integer(keep_last) and keep_last > 0 do
    # Preserve leading system messages
    {system_msgs, rest} = split_leading_system(messages)

    if length(rest) <= keep_last do
      messages
    else
      {old, recent} = Enum.split(rest, length(rest) - keep_last)
      # Critical: never split a tool_use/tool_result pair across the
      # boundary - Anthropic, OpenAI, and Gemini all 400 if we do.
      # Walk forward from `recent` until we no longer dangle tool calls or
      # have orphan tool results at the head.
      {old, recent} = balance_tool_call_boundary(old, recent)
      summary = summarize(old)
      system_msgs ++ [summary | recent]
    end
  end

  @doc """
  Moves messages across an `{old, recent}` boundary so it never splits a
  `tool_call`/`tool_result` pair.

  Anthropic, OpenAI and Gemini all reject a request whose tool results have
  no preceding assistant `tool_call` (and vice versa), so any code that
  splits a conversation — compaction, summarization, windowing — must pass
  its boundary through here.

  Leading `:tool` messages in `recent` are orphans: their assistant prelude
  is the last message of `old`. They are moved into `old`, which both closes
  the pair and keeps every message in its original relative order.

  The reverse case needs no work: if `old` ends with an assistant
  `tool_call`, its results are the very next messages, so they are exactly
  the leading `:tool` messages this function pulls back.

  ## Examples

      iex> old = [Nous.Message.assistant("calling", tool_calls: [%{id: "c1"}])]
      iex> recent = [Nous.Message.tool("c1", "done"), Nous.Message.user("next")]
      iex> {old, recent} = Nous.Transcript.balance_tool_call_boundary(old, recent)
      iex> {length(old), length(recent)}
      {2, 1}

  """
  @spec balance_tool_call_boundary([Message.t()], [Message.t()]) ::
          {[Message.t()], [Message.t()]}
  def balance_tool_call_boundary(old, recent) when is_list(old) and is_list(recent) do
    {orphan_tools, recent_rest} =
      Enum.split_while(recent, fn msg -> msg.role == :tool end)

    {old ++ orphan_tools, recent_rest}
  end

  @doc """
  Truncates oversized tool results in place, without an LLM call.

  A single tool result — a 1 MB file read, a wide `SELECT`, a verbose build
  log — can dominate a context window and is re-sent on every subsequent
  turn. This rewrites the content of any `:tool` message whose text exceeds
  `max_result_chars`, keeping the head and tail (where the useful signal
  almost always is) and replacing the middle with a marker naming how many
  bytes were dropped.

  Structural guarantees, relied on by callers that split conversations:

    * the returned list has the same length, in the same order — only
      content is rewritten, so a `tool_call`/`tool_result` pair can never be
      broken by pruning;
    * non-`:tool` messages are returned identically;
    * a tool result whose content is not plain text (a content-part list)
      is returned identically rather than flattened into a string.

  ## Examples

      iex> big = Nous.Message.tool("c1", String.duplicate("x", 20_000))
      iex> [pruned] = Nous.Transcript.prune_tool_results([big])
      iex> String.contains?(pruned.content, "bytes elided")
      true

      iex> small = Nous.Message.tool("c1", "ok")
      iex> Nous.Transcript.prune_tool_results([small]) == [small]
      true

  """
  @spec prune_tool_results([Message.t()], pos_integer()) :: [Message.t()]
  def prune_tool_results(messages, max_result_chars \\ @default_max_result_chars)

  def prune_tool_results(messages, max_result_chars)
      when is_list(messages) and is_integer(max_result_chars) and max_result_chars > 0 do
    Enum.map(messages, &prune_message(&1, max_result_chars))
  end

  # Only :tool messages with plain-text content are prunable. Everything
  # else — including a multimodal content-part list — is passed through
  # untouched: mangling parts into a string would lose the images.
  defp prune_message(%Message{role: :tool, content: content} = msg, max_result_chars)
       when is_binary(content) do
    if oversized?(content, max_result_chars) do
      %{msg | content: truncate_middle(content)}
    else
      msg
    end
  end

  defp prune_message(msg, _max_result_chars), do: msg

  # byte_size/1 is O(1) and never smaller than the codepoint count, so it
  # settles the overwhelmingly common "well under the cap" case without
  # walking the binary. Only a candidate pays for String.length/1.
  defp oversized?(content, max_result_chars) do
    byte_size(content) > max_result_chars and String.length(content) > max_result_chars
  end

  defp truncate_middle(content) do
    head = String.slice(content, 0, @prune_head_chars)
    tail = String.slice(content, -@prune_tail_chars, @prune_tail_chars)
    dropped = byte_size(content) - byte_size(head) - byte_size(tail)

    head <>
      "\n\n[... #{dropped} bytes elided by transcript pruning; kept #{@prune_head_chars} leading" <>
      " and #{@prune_tail_chars} trailing characters ...]\n\n" <> tail
  end

  @doc """
  Automatically compacts messages when a trigger condition is met.

  Returns the original messages unchanged if no trigger fires.
  Supports message count, token budget, or both (OR logic).

  ## Options

    * `:every` — compact when message count exceeds this number
    * `:token_budget` — total token budget for the conversation
    * `:threshold` — fraction of token budget that triggers compaction (default `0.8`)
    * `:keep_last` — how many recent messages to keep (required)

  ## Examples

      # Compact every 20 messages
      messages = Nous.Transcript.maybe_compact(messages, every: 20, keep_last: 10)

      # Compact at 80% of 128k token budget
      messages = Nous.Transcript.maybe_compact(messages,
        token_budget: 128_000,
        keep_last: 10
      )

      # Both triggers — whichever fires first
      messages = Nous.Transcript.maybe_compact(messages,
        every: 30,
        token_budget: 128_000,
        threshold: 0.75,
        keep_last: 10
      )

  """
  @spec maybe_compact([Message.t()], keyword()) :: [Message.t()]
  def maybe_compact(messages, opts) when is_list(opts) do
    keep_last = Keyword.fetch!(opts, :keep_last)
    every = Keyword.get(opts, :every)
    token_budget = Keyword.get(opts, :token_budget)
    threshold = Keyword.get(opts, :threshold, 0.8)

    triggered =
      triggered_by_count?(messages, every) or
        triggered_by_tokens?(messages, token_budget, threshold)

    if triggered do
      compact(messages, keep_last)
    else
      messages
    end
  end

  @doc """
  Like `maybe_compact/2` but runs asynchronously with a callback.

  The callback receives `{:compacted, messages}` if compaction happened,
  or `{:unchanged, messages}` if no trigger fired.

  ## Examples

      Nous.Transcript.maybe_compact_async(messages,
        [every: 20, keep_last: 10],
        fn
          {:compacted, msgs} -> GenServer.cast(self, {:update, msgs})
          {:unchanged, _msgs} -> :ok
        end
      )

  """
  @spec maybe_compact_async([Message.t()], keyword(), (term() -> any())) :: {:ok, pid()}
  def maybe_compact_async(messages, opts, callback) when is_function(callback, 1) do
    Task.Supervisor.start_child(Nous.TaskSupervisor, fn ->
      keep_last = Keyword.fetch!(opts, :keep_last)
      every = Keyword.get(opts, :every)
      token_budget = Keyword.get(opts, :token_budget)
      threshold = Keyword.get(opts, :threshold, 0.8)

      triggered =
        triggered_by_count?(messages, every) or
          triggered_by_tokens?(messages, token_budget, threshold)

      if triggered do
        callback.({:compacted, compact(messages, keep_last)})
      else
        callback.({:unchanged, messages})
      end
    end)
  end

  @doc """
  Compacts messages asynchronously under `Nous.TaskSupervisor`.

  Returns a `Task` that resolves to the compacted message list.
  Useful when compaction runs inside a GenServer and you don't
  want to block the current process.

  ## Examples

      task = Nous.Transcript.compact_async(messages, 10)
      # ... do other work ...
      compacted = Task.await(task)

  ## With a callback (fire-and-forget)

      Nous.Transcript.compact_async(messages, 10, fn compacted ->
        send(self(), {:compacted, compacted})
      end)

  """
  @spec compact_async([Message.t()], pos_integer()) :: Task.t()
  def compact_async(messages, keep_last) do
    Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
      compact(messages, keep_last)
    end)
  end

  @doc """
  Compacts messages in the background with a callback.

  Starts a fire-and-forget task under `Nous.TaskSupervisor`.
  The callback receives the compacted message list when done.
  Returns `{:ok, pid}`.

  ## Examples

      {:ok, _pid} = Nous.Transcript.compact_async(messages, 10, fn compacted ->
        GenServer.cast(self, {:update_messages, compacted})
      end)

  """
  @spec compact_async([Message.t()], pos_integer(), ([Message.t()] -> any())) ::
          {:ok, pid()}
  def compact_async(messages, keep_last, callback) when is_function(callback, 1) do
    Task.Supervisor.start_child(Nous.TaskSupervisor, fn ->
      compacted = compact(messages, keep_last)
      callback.(compacted)
    end)
  end

  @doc """
  Estimates the token count of a string as UTF-8 bytes divided by four.

  A coarse byte-ratio estimate, not a tokenizer. Four bytes per token is a
  passable average for English prose; it under-counts code, JSON and other
  punctuation-dense text (which tokenizes far finer than 4 bytes per token)
  and heavily over-counts CJK, where a 3-byte character is often a single
  token. Anything that must be exact — a hard context-window check, billing
  — needs a real tokenizer.

  This is deliberately the same arithmetic as the agent runner's pre-request
  reservation estimate (`Nous.AgentRunner.RequestDispatch.estimate_request_tokens/1`),
  so the framework has one token heuristic rather than two that disagree.

  ## Examples

      iex> Nous.Transcript.estimate_tokens("Hello world")
      2

      iex> Nous.Transcript.estimate_tokens("antidisestablishmentarianism")
      7

      iex> Nous.Transcript.estimate_tokens("")
      0

  """
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    div(byte_size(text), 4)
  end

  @doc """
  Estimates total tokens across a list of messages.

  Sums message text in bytes and divides once, so the result matches
  `estimate_tokens/1` on the concatenated text rather than accumulating a
  rounding error per message. Same caveats as `estimate_tokens/1`: it is a
  byte ratio, not a tokenizer.

  ## Examples

      iex> messages = [Nous.Message.user("Hello"), Nous.Message.assistant("Hi there")]
      iex> Nous.Transcript.estimate_messages_tokens(messages)
      3

  """
  @spec estimate_messages_tokens([Message.t()]) :: non_neg_integer()
  def estimate_messages_tokens(messages) when is_list(messages) do
    messages
    |> Enum.reduce(0, fn msg, acc -> acc + byte_size(Message.extract_text(msg)) end)
    |> div(4)
  end

  @doc """
  Checks if a message list should be compacted based on a threshold.

  ## Examples

      iex> messages = for i <- 1..25, do: Nous.Message.user("msg \#{i}")
      iex> Nous.Transcript.should_compact?(messages, 20)
      true

  """
  @spec should_compact?([Message.t()], pos_integer()) :: boolean()
  def should_compact?(messages, compact_after) do
    length(messages) > compact_after
  end

  # -- Private --

  defp triggered_by_count?(_messages, nil), do: false
  defp triggered_by_count?(messages, every), do: length(messages) > every

  defp triggered_by_tokens?(_messages, nil, _threshold), do: false

  defp triggered_by_tokens?(messages, token_budget, threshold) do
    estimated = estimate_messages_tokens(messages)
    estimated > token_budget * threshold
  end

  defp split_leading_system(messages) do
    Enum.split_while(messages, fn msg ->
      msg.role == :system
    end)
  end

  defp summarize(messages) do
    count = length(messages)

    content =
      messages
      |> Enum.map(&summarize_one/1)
      |> Enum.join("\n")

    Message.system("[Compacted #{count} earlier messages]\n#{content}")
  end

  # L-12: never echo tool_result content verbatim into the summary - tool
  # results frequently carry API keys, PII pulled from MCP, or other data
  # that scanning/redaction policies would otherwise scrub. The compacted
  # summary becomes a permanent system message that survives further
  # compactions, so any leak here is durable. Show a structural marker
  # instead. Other roles still get a short preview for context.
  defp summarize_one(%{role: :tool} = msg) do
    name = Map.get(msg, :name) || "unknown"
    "  [tool] <result for #{inspect(name)} omitted from summary>"
  end

  defp summarize_one(msg) do
    role = msg.role || :unknown
    text = Message.extract_text(msg)
    preview = text |> String.slice(0..100) |> String.replace("\n", " ")
    "  [#{role}] #{preview}"
  end
end
