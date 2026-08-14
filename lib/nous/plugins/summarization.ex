defmodule Nous.Plugins.Summarization do
  @moduledoc """
  Plugin for managing context window size via pruning and summarization.

  When the conversation exceeds a configurable token threshold, this plugin
  first prunes oversized tool results (free, no model call) and only pays for
  an LLM summarization if the transcript is still over budget afterwards.

  ## Usage

      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.Summarization],
        deps: %{
          summarization_config: %{
            max_context_tokens: 170_000,
            keep_recent: 10,
            summary_model: "openai:gpt-4o-mini"
          }
        }
      )

  ## Configuration (via deps)

  - `:max_context_tokens` - Token threshold to trigger compaction (default: 100_000)
  - `:keep_recent` - Number of recent messages to keep intact (default: 10)
  - `:max_result_chars` - Tool results longer than this are truncated before
    any model call is considered (default: 8192)
  - `:summary_model` - Model string for the summarization call (default: the
    conversation's own model, which is also the only setting that preserves
    the provider's prefix cache — see below)
  - `:summary_count` - Read-only counter of completed summarizations
  - `:compaction_in_progress` - Read-only marker; see "Crash visibility"

  ## Compaction pipeline

  1. Prune oversized tool results in place. This never changes the message
     count or order, so it can never break a `tool_call`/`tool_result` pair.
  2. Re-estimate the transcript. If pruning alone brought it under the
     threshold, stop here — no model call, no cost.
  3. Otherwise split off the recent messages and replace the older ones with
     a model-written summary.

  The pruned messages are kept whichever branch runs, and whether or not the
  summarization call succeeds: they are strictly cheaper than what they
  replaced.

  ## Where the logic lives

  This plugin is the live compaction entry point — it is what actually runs
  during an agent run. `Nous.Transcript` is the shared library it calls for
  the parts that must behave identically everywhere: pruning
  (`Nous.Transcript.prune_tool_results/2`), tool-pair-safe boundaries
  (`Nous.Transcript.balance_tool_call_boundary/2`) and token estimation
  (`Nous.Transcript.estimate_messages_tokens/1`). There is deliberately only
  one implementation of each; this module holds no boundary logic of its own.

  ## Prefix-cache friendliness

  The summarization request replays the conversation's own system prompt,
  tools and messages verbatim and appends the instruction as a final user
  turn. Providers key their KV prefix cache on the literal request prefix, so
  a bespoke summarizer prompt with no tools would miss the cache entirely and
  re-bill every token of the conversation being summarized.

  Only the response TEXT is kept: reasoning and tool calls are discarded, so
  a summary can never plant an unanswered `tool_call` in the transcript.

  Setting `:summary_model` to a different model gives up that cache reuse,
  and — because the conversation is replayed verbatim — sends the raw
  conversation, tool results included, to that model's provider.

  ## Telemetry

  Every compaction emits, in order:

    * `[:nous, :compaction, :start]` —
      measurements `%{system_time:, monotonic_time:}`,
      metadata `%{agent_name:, messages_before:}`
    * `[:nous, :compaction, :stop]` —
      measurements `%{duration:, bytes_before:, bytes_after:}`,
      metadata `%{agent_name:, messages_before:, messages_after:, llm_called:,
      summarized:, provider:, model:, usage:}`
    * `[:nous, :compaction, :exception]` —
      measurements `%{duration:}`,
      metadata `%{agent_name:, messages_before:, messages_after:, llm_called:,
      kind:, reason:, stacktrace:}`

  ## Crash visibility

  `:compaction_in_progress` is set in `deps[:summarization_config]` before the
  `:start` event and cleared only after `:stop`. A compaction that dies in the
  middle therefore leaves the marker set and an orphaned `:start` with no
  matching `:stop`, instead of looking like a clean no-op.

  ## Safety

  - Never splits tool_call/tool_result pairs
  - Keeps system prompt intact
  - Falls back to keeping the (pruned) messages if summarization fails
  """

  @behaviour Nous.Plugin

  alias Nous.AgentRunner.RequestDispatch
  alias Nous.Message
  alias Nous.Model
  alias Nous.ModelDispatcher
  alias Nous.Transcript

  require Logger

  @default_max_tokens 100_000
  @default_keep_recent 10
  @default_max_result_chars 8192
  @default_summary_temperature 0.3
  @default_summary_max_tokens 1000

  @summary_instruction """
  Summarize the conversation above into a compact briefing that a fresh model \
  instance could continue from. Preserve decisions, established facts, file \
  paths, identifiers, and open questions; drop pleasantries and superseded \
  detail. Answer with the summary as plain prose (3-5 paragraphs max) and do \
  not call any tools.
  """

  @impl true
  def init(_agent, ctx) do
    # Ensure summarization config exists in deps
    config = ctx.deps[:summarization_config] || %{}

    put_config(ctx, %{
      max_context_tokens: Map.get(config, :max_context_tokens, @default_max_tokens),
      keep_recent: Map.get(config, :keep_recent, @default_keep_recent),
      max_result_chars: Map.get(config, :max_result_chars, @default_max_result_chars),
      summary_model: Map.get(config, :summary_model),
      summary_count: Map.get(config, :summary_count, 0),
      compaction_in_progress: Map.get(config, :compaction_in_progress, false)
    })
  end

  @impl true
  def before_request(agent, ctx, tools) do
    config = ctx.deps[:summarization_config] || %{}
    max_tokens = Map.get(config, :max_context_tokens, @default_max_tokens)

    if ctx.usage.total_tokens > max_tokens do
      Logger.info(
        "Compaction triggered: #{ctx.usage.total_tokens} tokens exceeds #{max_tokens} limit"
      )

      warn_if_orphaned(config)
      {compact(agent, ctx, config, max_tokens), tools}
    else
      {ctx, tools}
    end
  end

  # A marker still standing from a previous turn means that compaction died
  # between :start and :stop. It is not fatal — the transcript is whatever the
  # crash left behind — but it is the only in-band signal that it happened.
  defp warn_if_orphaned(config) do
    if Map.get(config, :compaction_in_progress, false) do
      Logger.warning(
        "Previous compaction never completed (compaction_in_progress still set); " <>
          "look for a [:nous, :compaction, :start] with no matching :stop"
      )
    end
  end

  defp compact(agent, ctx, config, max_tokens) do
    start_time = System.monotonic_time()
    messages_before = length(ctx.messages)
    bytes_before = transcript_bytes(ctx.messages)

    # Ordering is load-bearing: the marker goes UP before :start and comes
    # DOWN only after :stop/:exception. Clearing it first — or in an `after`
    # block — would make a compaction that crashed halfway indistinguishable
    # from one that finished, which is exactly the failure this marker exists
    # to make visible.
    ctx = put_config(ctx, %{compaction_in_progress: true})

    :telemetry.execute(
      [:nous, :compaction, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{agent_name: agent.name, messages_before: messages_before}
    )

    # Pruning is pure list rewriting and sits OUTSIDE the try on purpose: if
    # it raises, that is a bug in Nous.Transcript, and dressing it up as a
    # "compaction exception" would bury it. The orphaned :start is the signal.
    max_result_chars = Map.get(config, :max_result_chars, @default_max_result_chars)
    pruned = Transcript.prune_tool_results(ctx.messages, max_result_chars)
    ctx = %{ctx | messages: pruned}

    telemetry_base = %{
      agent_name: agent.name,
      messages_before: messages_before,
      bytes_before: bytes_before,
      start_time: start_time
    }

    try do
      maybe_summarize(agent, ctx, config, max_tokens)
    rescue
      exception ->
        emit_exception(telemetry_base, ctx, :error, exception, __STACKTRACE__)
        ctx
    catch
      kind, reason ->
        emit_exception(telemetry_base, ctx, kind, reason, __STACKTRACE__)
        ctx
    else
      {result_ctx, outcome} ->
        emit_stop(telemetry_base, result_ctx, outcome)
        put_config(result_ctx, %{compaction_in_progress: false})
    end
  end

  # Prune first, re-measure, and skip the model entirely if the pressure
  # cleared. Note the two numbers are not on the same scale: the trigger uses
  # `ctx.usage.total_tokens`, which is what the PROVIDER billed for the
  # previous turn (system prompt, tool schemas and generated output included),
  # while this is a local byte-ratio estimate of the message text alone. The
  # estimate is therefore a lower bound, and skipping only when even the lower
  # bound is under the limit errs toward summarizing when we did not have to —
  # never toward blowing the context window.
  defp maybe_summarize(agent, ctx, config, max_tokens) do
    estimated = Transcript.estimate_messages_tokens(ctx.messages)

    if estimated > max_tokens do
      summarize_older_messages(agent, ctx, config)
    else
      Logger.info(
        "Pruning cleared context pressure (~#{estimated} estimated tokens <= " <>
          "#{max_tokens}); skipping the summarization request"
      )

      {ctx, %{llm_called: false, summarized: false}}
    end
  end

  defp summarize_older_messages(agent, ctx, config) do
    keep_recent = Map.get(config, :keep_recent, @default_keep_recent)
    {system_msgs, conversation} = Enum.split_with(ctx.messages, &(&1.role == :system))

    {old_messages, recent_messages} =
      conversation
      |> Enum.split(max(length(conversation) - keep_recent, 0))
      |> then(fn {old, recent} -> Transcript.balance_tool_call_boundary(old, recent) end)

    if old_messages == [] do
      {ctx, %{llm_called: false, summarized: false}}
    else
      run_summarizer(agent, ctx, config, {system_msgs, old_messages, recent_messages})
    end
  end

  defp run_summarizer(agent, ctx, config, {system_msgs, old_messages, recent_messages}) do
    model = summary_model(agent, config)
    outcome = %{llm_called: true, provider: model.provider, model: model.model}

    case request_summary(agent, model, config, system_msgs, old_messages) do
      {:ok, response} ->
        apply_summary(ctx, config, response, {system_msgs, recent_messages}, outcome)

      {:error, reason} ->
        Logger.warning("Summarization failed, keeping pruned messages: #{inspect(reason)}")
        {ctx, Map.merge(outcome, %{summarized: false, error: reason})}
    end
  end

  defp apply_summary(ctx, config, response, {system_msgs, recent_messages}, outcome) do
    usage = response.metadata[:usage]

    case summary_text(response) do
      {:ok, text} ->
        summary_msg = Message.system("[Conversation Summary]\n#{text}")

        ctx = %{ctx | messages: system_msgs ++ [summary_msg | recent_messages]}
        ctx = put_config(ctx, %{summary_count: Map.get(config, :summary_count, 0) + 1})

        {ctx, Map.merge(outcome, %{summarized: true, usage: usage})}

      {:error, reason} ->
        Logger.warning("Summarization returned no text, keeping pruned messages")
        {ctx, Map.merge(outcome, %{summarized: false, error: reason, usage: usage})}
    end
  end

  # Only the TEXT survives. The request deliberately carries the
  # conversation's real tool schemas (that is what keeps the prefix
  # cacheable), so the model is free to answer with a tool call instead of
  # prose, and reasoning models attach reasoning_content on the side. Copying
  # either into the summary would put a tool_call with no matching
  # tool_result into a durable system message — which every provider rejects
  # on the next turn. A response with no usable text is a failed
  # summarization, not an empty summary: replacing real history with "" would
  # destroy the conversation.
  defp summary_text(response) do
    case String.trim(Message.extract_text(response)) do
      "" -> {:error, :empty_summary}
      text -> {:ok, text}
    end
  end

  # Replay the conversation verbatim — same system messages, same tool
  # schemas, same history, in the same order — and append the instruction as
  # the final user turn. Providers key their KV prefix cache on the literal
  # request prefix, so anything else re-bills the whole conversation at full
  # price on every compaction.
  defp request_summary(agent, model, config, system_msgs, old_messages) do
    messages = system_msgs ++ old_messages ++ [Message.user(@summary_instruction)]
    settings = summary_settings(agent, model, config)

    ModelDispatcher.resolve().request(model, messages, settings)
  end

  defp summary_settings(agent, model, config) do
    base =
      agent.model_settings
      |> Map.put(
        :temperature,
        Map.get(config, :summary_temperature, @default_summary_temperature)
      )
      |> Map.put(:max_tokens, Map.get(config, :summary_max_tokens, @default_summary_max_tokens))

    case agent.tools do
      [] ->
        base

      tools ->
        Map.put(base, :tools, RequestDispatch.convert_tools_for_provider(model.provider, tools))
    end
  end

  defp summary_model(agent, config) do
    case Map.get(config, :summary_model) do
      nil -> agent.model
      %Model{} = model -> model
      model_string when is_binary(model_string) -> Model.parse(model_string)
    end
  end

  # --- Telemetry ---------------------------------------------------------

  defp emit_stop(base, ctx, outcome) do
    :telemetry.execute(
      [:nous, :compaction, :stop],
      %{
        duration: System.monotonic_time() - base.start_time,
        bytes_before: base.bytes_before,
        bytes_after: transcript_bytes(ctx.messages)
      },
      %{
        agent_name: base.agent_name,
        messages_before: base.messages_before,
        messages_after: length(ctx.messages),
        llm_called: Map.get(outcome, :llm_called, false),
        summarized: Map.get(outcome, :summarized, false),
        provider: Map.get(outcome, :provider),
        model: Map.get(outcome, :model),
        usage: Map.get(outcome, :usage)
      }
    )
  end

  defp emit_exception(base, ctx, kind, reason, stacktrace) do
    Logger.warning("Compaction raised, keeping pruned messages: #{inspect(reason)}")

    :telemetry.execute(
      [:nous, :compaction, :exception],
      %{duration: System.monotonic_time() - base.start_time},
      %{
        agent_name: base.agent_name,
        messages_before: base.messages_before,
        messages_after: length(ctx.messages),
        # The only thing between :start and this rescue is the summarization
        # request; pruning is outside the try.
        llm_called: true,
        kind: kind,
        reason: reason,
        stacktrace: stacktrace
      }
    )
  end

  defp transcript_bytes(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + byte_size(Message.extract_text(msg)) end)
  end

  # Merges into whatever is currently in deps rather than a captured copy, so
  # successive updates within one compaction cannot clobber each other.
  defp put_config(ctx, updates) do
    config = Map.merge(ctx.deps[:summarization_config] || %{}, updates)
    %{ctx | deps: Map.put(ctx.deps, :summarization_config, config)}
  end
end
