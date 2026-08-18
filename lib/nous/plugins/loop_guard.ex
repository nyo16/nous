defmodule Nous.Plugins.LoopGuard do
  @moduledoc """
  Plugin that notices an agent repeating the same tool call and injects
  escalating guidance.

  Opt-in. Nothing changes for an agent that does not list it:

      agent = Nous.new("openai:gpt-4o", plugins: [Nous.Plugins.LoopGuard])

  A "repeat" is a consecutive run of assistant messages making the same
  `{tool_name, arguments}` call, comparing arguments by canonical form so key
  order and atom-vs-string keys cannot defeat the match. At each configured
  threshold the plugin appends one advisory message to the transcript. It never
  blocks the call, never edits a tool result, and never ends the run — a looping
  model is told, not stopped, because blocking one is a separate decision with no
  evidence behind it yet.

  ## Configuration (via `deps[:loop_guard_config]`)

    * `:thresholds` — chain lengths that trigger an advisory. Default `[3, 5, 8]`.
      Sorted and de-duplicated; the Nth threshold gets the Nth wording tier, and a
      list longer than the three tiers reuses the firmest one.
    * `:excluded_tools` — tool names that are transparent to the chain: they
      neither increment it nor reset it, so a bookkeeping call (a todo write, a
      progress ping) cannot launder a loop by sitting between two identical
      calls. Default `[]`; matched case-insensitively. Nothing is excluded by
      default because this repo ships no bookkeeping tool to name.

  `:deps` is passed to `Nous.run/3`, not `Nous.new/2`:

      {:ok, result} =
        Nous.run(agent, "...",
          deps: %{loop_guard_config: %{thresholds: [4, 8], excluded_tools: ["todo_write"]}}
        )

  ## What counts

    * Denied calls count. A call blocked by the permission policy, an approval
      handler or a hook still appears in the assistant message that requested it,
      and a model retrying a call it is not allowed to make is exactly the loop
      worth catching. The chain is read off the requests, never off the results.
    * A new user message resets the chain — it is a new instruction.
    * A tool result does not: it is the echo of a call already counted from the
      assistant message that made it.
    * An injected system message does not either. `Nous.Plugins.Memory` and
      `Nous.Plugins.KnowledgeBase` put context there mid-conversation, and letting
      an unrelated plugin's injection reset the chain would make the guard
      silently depend on the plugin list.
    * An assistant message with no tool calls resets the chain: the model answered
      instead of calling, so the run of identical calls is over.
  """

  @behaviour Nous.Plugin

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.ToolCall

  @default_thresholds [3, 5, 8]

  # `before_request/3` rather than `after_response/3`. The advisory is a reaction
  # to what the repeated calls returned, so it has to sit *after* those tool
  # results and immediately before the model decides again — which is exactly the
  # transcript position `before_request/3` appends into. `after_response/3` runs
  # while the response's tool calls are still unexecuted, so the advisory would
  # land ahead of the very results it is reacting to and read as a comment on the
  # wrong turn.
  @impl true
  def before_request(_agent, ctx, tools) do
    config = Map.get(ctx.deps, :loop_guard_config, %{})
    thresholds = config |> Map.get(:thresholds, @default_thresholds) |> thresholds()
    excluded = config |> Map.get(:excluded_tools, []) |> excluded_names()

    with {[_ | _] = signatures, chain, announced} <- scan(ctx.messages, excluded),
         {threshold, tier} <- pending(thresholds, chain, announced) do
      text = advisory(tier, label(signatures), chain)

      # User role, not system. `Nous.Message.split_system/1` — the Anthropic and
      # Gemini request path — hoists EVERY system message into the top-level
      # system parameter, so a system-role advisory would be lifted out of the
      # transcript and pinned to the front of the prompt, which is the one place
      # it must not be: it is a remark about the turn that just happened.
      #
      # `:source` marks the event as injected context, like Memory and
      # KnowledgeBase do; `:metadata` marks the projected *message*, which is
      # what the next scan reads. Both are needed: `:source` lives only in the
      # event data and never reaches `ctx.messages`.
      message = Message.user(text, metadata: %{loop_guard: threshold})

      {Context.add_message(ctx, message, source: :loop_guard), tools}
    else
      _no_advisory_due -> {ctx, tools}
    end
  end

  # --- the chain -------------------------------------------------------------

  # The chain is DERIVED from the transcript on every request, not counted into
  # `deps`. A stored counter is a second source of truth that has to be reset by
  # hand on every boundary the transcript already records, and it does not survive
  # `Nous.Session.fork/2`, a save/restore, or a run resumed from `context:` — a
  # forked session would inherit its parent's count. Walking backwards costs one
  # pass over a message list per LLM request, which is free next to the request.
  #
  # Returns `{signatures, chain, announced}`: the repeated call's canonical
  # signature list, how many consecutive times it was requested, and the
  # thresholds already announced inside this same chain.
  defp scan(messages, excluded) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0, []}, fn message, {sigs, chain, announced} ->
      case classify(message, excluded) do
        :transparent -> {:cont, {sigs, chain, announced}}
        {:announced, threshold} -> {:cont, {sigs, chain, [threshold | announced]}}
        :boundary -> {:halt, {sigs, chain, announced}}
        {:calls, calls} when sigs == [] -> {:cont, {calls, 1, announced}}
        {:calls, ^sigs} -> {:cont, {sigs, chain + 1, announced}}
        {:calls, _different} -> {:halt, {sigs, chain, announced}}
      end
    end)
  end

  # An advisory this plugin injected is transparent AND carries the threshold it
  # announced. Without the marker the injected user message would read as a new
  # instruction on the next scan and reset the chain it was reporting on, so the
  # guard could never escalate past its first threshold. Carrying the threshold in
  # the marker also makes "already announced" derivable, so a chain that stalls at
  # one length (the model calls only excluded tools for a turn) cannot re-announce
  # the same threshold. The alternative — firing on `chain in thresholds` alone —
  # double-announces in exactly that case.
  defp classify(%Message{} = message, excluded) do
    case marker(message) do
      nil -> classify_role(message, excluded)
      threshold -> {:announced, threshold}
    end
  end

  defp classify_role(%Message{role: :tool}, _excluded), do: :transparent
  defp classify_role(%Message{role: :system}, _excluded), do: :transparent
  defp classify_role(%Message{role: :user}, _excluded), do: :boundary

  defp classify_role(%Message{role: :assistant, tool_calls: [_ | _] = calls}, excluded) do
    case signatures(calls, excluded) do
      # Every call in the message was excluded, so the message is bookkeeping.
      [] -> :transparent
      sigs -> {:calls, sigs}
    end
  end

  defp classify_role(%Message{role: :assistant}, _excluded), do: :boundary

  # A JSON round trip through persistence stringifies nested metadata keys, so the
  # marker has to be readable under both key styles or a restored session would
  # forget it had already warned. The value is a positive integer, so `||` cannot
  # swallow a legitimate one.
  defp marker(%Message{} = message) do
    Message.get_metadata(message, :loop_guard) || Message.get_metadata(message, "loop_guard")
  end

  # Parallel calls in one assistant message are compared as a whole ordered list:
  # the message either requested the same set of work again or it did not, and
  # comparing only the first call would miss a two-call loop.
  defp signatures(calls, excluded) do
    Enum.flat_map(calls, fn call ->
      name = call |> ToolCall.field(:name, "") |> to_string() |> String.downcase()

      if name in excluded do
        []
      else
        [{name, canonical_args(ToolCall.field(call, :arguments, %{}))}]
      end
    end)
  end

  # --- argument canonicalization ---------------------------------------------

  # Providers hand `arguments` over either already decoded or as the raw JSON
  # string, and the string form is what lets key order defeat a naive comparison:
  # `{"a":1,"b":2}` and `{"b":2,"a":1}` are different bytes for the same call.
  # Decoded here rather than through `Nous.Messages.OpenAI.decode_arguments/1`,
  # which logs a warning on malformed JSON — the runner already surfaces that as a
  # tool error, and a read-only inspection running once per request must not
  # re-log it on every iteration.
  defp canonical_args(args) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, decoded} -> canonical(decoded)
      # Not JSON. An opaque argument blob compares as its own bytes.
      {:error, _reason} -> args
    end
  end

  defp canonical_args(args), do: canonical(args)

  # Keys are normalized to strings and sorted at every depth. String keys arrive
  # from providers, atom keys from hand-built calls and tool tests, and the two
  # forms of one call must compare equal. Sorting is not redundant with BEAM map
  # equality: a map over 32 keys is a hash-array-mapped trie whose `Enum` order is
  # not term order, and only a sorted list is a canonical term for such a map.
  #
  # Decoding is deliberately NOT recursive — a string *value* stays a string, so
  # `%{"n" => "42"}` and `%{"n" => 42}` remain the different calls they are.
  defp canonical(%_struct{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(args) when is_map(args) do
    args
    |> Enum.map(fn {key, value} -> {canonical_key(key), canonical(value)} end)
    |> Enum.sort()
  end

  # List order is part of the value, so it survives untouched.
  defp canonical(args) when is_list(args), do: Enum.map(args, &canonical/1)
  defp canonical(args), do: args

  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key), do: key

  # --- configuration ---------------------------------------------------------

  # Sorted because the tier that pairs with a threshold is its position, and
  # de-duplicated because a repeated threshold would otherwise announce twice.
  # A threshold of 1 is dropped: a chain of one is a single call, not a repeat,
  # and firing on it would advise on every tool call the agent ever makes.
  defp thresholds(thresholds) when is_list(thresholds) do
    thresholds
    |> Enum.filter(&(is_integer(&1) and &1 > 1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp thresholds(_invalid), do: @default_thresholds

  # A plain list, not a `MapSet`. This holds a handful of tool names at most, so
  # a set allocates a map to avoid a comparison chain shorter than building it —
  # and `MapSet`'s opaque internals cross a function boundary here, which
  # dialyzer reports as `call_without_opaque`. A list is both cheaper and
  # honestly typed, which beats suppressing the warning.
  defp excluded_names(names) when is_list(names) do
    Enum.map(names, fn name -> name |> to_string() |> String.downcase() end)
  end

  defp excluded_names(_invalid), do: []

  # The highest threshold this chain has reached and not yet announced, paired
  # with its position in the list — that position IS the wording tier.
  # Thresholds are ascending, so the last survivor is the highest.
  defp pending(thresholds, chain, announced) do
    thresholds
    |> Enum.with_index()
    |> Enum.filter(fn {threshold, _tier} -> threshold <= chain and threshold not in announced end)
    |> List.last()
  end

  # --- advisory text ---------------------------------------------------------

  defp label(signatures) do
    Enum.map_join(signatures, ", ", fn {name, _args} -> "`#{name}`" end)
  end

  # Three tiers, escalating in firmness rather than in alarm. This text is prompt
  # surface: wording that shouts derails a task that is legitimately repetitive —
  # a paginated fetch, a poll, a retry with a real backoff — far more often than
  # it rescues a stuck one. A `:thresholds` list longer than three reuses the
  # firmest tier rather than inventing wording nobody wrote.
  defp advisory(tier, label, count) do
    "Loop check: this exact tool call has now been made #{count} times in a row, " <>
      "with identical arguments each time: #{label}. " <> guidance(min(tier, 2))
  end

  defp guidance(0) do
    "The result will not change on its own. Re-read what the previous result " <>
      "actually said before repeating it; if it does not contain what you need, " <>
      "change the arguments, try a different tool, or say what is blocking you."
  end

  defp guidance(1) do
    "Repeating it will not produce a different result. Change approach now: " <>
      "different arguments, a different tool, or report plainly what you could " <>
      "not determine."
  end

  defp guidance(2) do
    "Stop making this call. Summarise what you have established, state what is " <>
      "still unknown and why this call cannot resolve it, and end your turn."
  end
end
