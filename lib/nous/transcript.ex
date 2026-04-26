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

      # Estimate token count
      tokens = Nous.Transcript.estimate_tokens("Hello world, how are you?")
      #=> 5

  """

  alias Nous.Message

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

  # Move messages from `recent` into `old` (or vice versa) so the boundary
  # never splits a tool_call/tool_result pair. Two cases:
  #
  # 1. The last message in `old` is an :assistant with tool_calls but the
  #    matching :tool result(s) are at the head of `recent` - those tool
  #    results are orphans without their assistant prelude. Move them into
  #    `old` so they are summarized along with their assistant message.
  #
  # 2. The first message in `recent` is a :tool result whose matching
  #    assistant tool_call sits in `old`. Same fix - pull the orphan tool
  #    results back into `old`.
  defp balance_tool_call_boundary(old, recent) do
    # Pull leading :tool messages from recent into old until the head is
    # a non-tool message. Their corresponding assistant message is in old.
    {orphan_tools, recent_rest} =
      Enum.split_while(recent, fn msg -> msg.role == :tool end)

    {old ++ orphan_tools, recent_rest}
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
  Estimates the token count of a string using word count as a proxy.

  This is a rough estimate (~1.3 tokens per word for English text).
  For precise counting, use a proper tokenizer.

  ## Examples

      iex> Nous.Transcript.estimate_tokens("Hello world")
      2

      iex> Nous.Transcript.estimate_tokens("")
      0

  """
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    text |> String.split() |> length()
  end

  @doc """
  Estimates total tokens across a list of messages.

  ## Examples

      iex> messages = [Nous.Message.user("Hello"), Nous.Message.assistant("Hi there")]
      iex> Nous.Transcript.estimate_messages_tokens(messages)
      3

  """
  @spec estimate_messages_tokens([Message.t()]) :: non_neg_integer()
  def estimate_messages_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + estimate_tokens(Message.extract_text(msg))
    end)
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
