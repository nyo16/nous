defmodule Nous.Session.Invariant do
  @moduledoc """
  Every model-visible request must be reconstructable from the session log.

  `Nous.Session.Log` is the source of truth and `ctx.messages` is a view over it
  (see `Nous.Agent.Context`). That only buys fork, rewind, replay, non-destructive
  compaction and audit if the list actually handed to a provider is the list the
  fold produces — otherwise the log records a conversation the model never had,
  and every feature built on replaying it is quietly wrong. This module is that
  assertion, checked on the agent loop's request path.

  ## The rule, exactly

  `check/2` walks the request and `Nous.Session.Log.derive_indexed/1` in lockstep
  and requires, position for position, the same `role`, `content`, `tool_calls`,
  `tool_call_id` and `name`. There are exactly two exemptions, and both are
  assembly-time system-prompt state that is deliberately not in the log:

    1. **The overlay slot.** `Nous.Agent.Context.put_system_prompt_overlay/2`
       holds the fragment `Nous.AgentRunner.PromptAssembly` re-derives from agent
       config, plugins and skills on every run. `Context`'s `apply_overlay/2`
       either concatenates it onto the transcript's leading system message or,
       when the fold has no leading system message, **prepends a system message
       that no event produced**. So a leading `:system` message in the request
       facing a non-`:system` head in the fold is skipped, and that is the only
       length difference tolerated. `Nous.Agents.BasicAgent.build_messages/2`
       prepends `ctx.system_prompt` the same way when the transcript carries no
       system message at all; the same exemption covers it.
    2. **System content.** Where both sides hold a `:system` message, its content
       is not compared — only the role and the position. The overlay is
       concatenated into that content, and a behaviour may substitute its own
       assembled prompt wholesale (`Nous.Agents.ReActAgent` and
       `Nous.Agents.KnowledgeBaseAgent` reject the transcript's system messages
       and prepend a freshly built one). System text is re-derived per request, so
       the log cannot say what it should be; asserting on it would be asserting on
       agent config.

  Everything else is exact. A user, assistant or tool message no event produced,
  an event-derived message the request dropped, and the same messages in a
  different order are all violations — including a *mid-transcript* system
  message the request omitted, which is a genuine loss of model-visible history
  (a `Nous.Plugins.Summarization` summary is a system message, and it stands in
  for every event it shadowed).

  `metadata` and `created_at` are not compared. They are not part of the request
  ordering the log has to reproduce, and the request's messages are the fold's
  own terms in the common case, so the fields that matter are compared by
  pointer.

  ## The orphaned tool result

  Checked on the request alone: a `:tool` message whose `tool_call_id` appears in
  no **preceding** assistant message's `tool_calls`. This is the provider-400
  class the whole boundary-balancing machinery exists to prevent, and it survives
  a perfectly reconstructable request — a positional `{:replace, start, stop}`
  over an unbalanced range shadows an assistant message and leaves its result
  standing, so the *fold itself* is unbalanced. Any caller that picks its own
  range can do this; `Nous.Plugins.Summarization` avoids it only because it runs
  `Nous.Transcript.balance_tool_call_boundary/2` first.

  Reconstruction is reported before pairing: if the request does not match the
  fold, the pairing diagnosis is about a list we already know is wrong.

  ## What this actually catches

  A **request builder** that invents or drops messages at assembly time — a
  behaviour's `build_messages/2`, or anything else between the transcript and the
  provider — plus the orphaned tool result above.

  Notably *not* the legacy `%{ctx | messages: ...}` write D2 keeps alive:
  `Nous.Agent.Context`'s `sync/1` reseeds the log from whatever the caller
  assembled on the very next append, and the loop appends a `:step_start` before
  every request, so by dispatch the fold agrees with the request again. That
  write rewrites history rather than diverging from it, which is a different
  (documented, transitional) sin and not one a request-time check can see.

  ## Modes

  `config :nous, :session_invariant, :warn | :strict | :off` — default `:warn`.

    * `:warn` — emit `[:nous, :session, :invariant, :violation]` with the details
      as metadata and `Logger.warning/1`. **Never raises**, and that is the point:
      a user-supplied behaviour or plugin is entitled to assemble a request the
      transcript does not literally contain (dropping a mid-transcript system
      message is one of the shipped behaviours doing exactly that), and D2 keeps
      the legacy `%{ctx | messages: ...}` writers alive for at least one release.
      A checker that raised would take down a live, paid-for run over a
      bookkeeping discrepancy — wrong by construction.
    * `:strict` — telemetry, then raise `Nous.Session.Invariant.Violation`. This
      is for **our own test suite**, which is allowed to treat a divergence as a
      bug because it owns every writer. Do not turn it on in production.
    * `:off` — skip the check entirely, before any work. For hot paths that have
      measured the cost and decided against it.

  ## Cost

  This runs on every request, so `check/2` is one O(n) pass over the message list
  plus one O(n) pass for tool pairing, with no intermediate lists: the fold comes
  from `derive_indexed/1`, which is memoized in the log, and the per-message
  comparison hits `==` on terms the request and the fold physically share. Only a
  violation allocates, and what it reports is bounded (see `t:details/0`).

  ## What is not checked

  `Nous.Plugins.Summarization` asks the model to write a summary through
  `Nous.ModelDispatcher` directly. That request is a slice of the transcript plus
  an instruction, not the session's own request, and it is correctly invisible
  here. `Nous.AgentRunner.RequestDispatch` documents the one other request path
  that has no context in scope.
  """

  alias Nous.Agent.Context
  alias Nous.{Message, ToolCall}
  alias Nous.Session.Log

  require Logger

  defmodule Violation do
    @moduledoc """
    Raised by `Nous.Session.Invariant.verify/2` in `:strict` mode.

    `:details` is the `t:Nous.Session.Invariant.details/0` map that also travels
    as the telemetry metadata.
    """

    use Nous.Errors.Base, fields: [:details]

    @type t :: %__MODULE__{message: String.t(), details: map()}

    defp default_message(%{details: details}) do
      "session log invariant violated: #{inspect(details)}"
    end
  end

  @typedoc """
  `:warn` logs and emits telemetry, `:strict` raises, `:off` skips the check.
  """
  @type mode :: :off | :warn | :strict

  @typedoc """
  What went wrong.

    * `:extra_message` — the request carries a message no event produced
    * `:missing_message` — the fold produced a message the request dropped
    * `:order` — the same messages, in a different order
    * `:orphaned_tool_result` — a `:tool` message with no preceding tool call
  """
  @type kind :: :extra_message | :missing_message | :order | :orphaned_tool_result

  @typedoc """
  Telemetry metadata and `Violation` payload.

  Reconstruction violations carry `:index` (the first diverging position),
  `:request_length`, `:log_length` and `:extra`/`:missing`. The lengths and the
  index are all measured after the overlay slot is skipped, so they line up with
  each other. `:extra`/`:missing` are bounded lists of message *sketches*, not
  messages, so a violation cannot dump a multimodal transcript into a log line.

  `:orphaned_tool_result` carries the offending `:tool_call_id`.
  """
  @type details :: %{:kind => kind(), optional(atom()) => term()}

  @modes [:off, :warn, :strict]
  @default_mode :warn
  @violation_event [:nous, :session, :invariant, :violation]

  # A violation reports at most this many surplus/absent messages per side. The
  # cause is almost always the first one, and the metadata rides into a log line.
  @max_reported 5
  @preview_limit 120

  @doc """
  Check the request, then act on the configured mode.

  Returns `:ok` in every mode except `:strict`, where a violation raises
  `Nous.Session.Invariant.Violation`. `:off` short-circuits before any work, and
  a `nil` context (a request path with no session in scope) is a no-op.

  ## Examples

      iex> ctx = Nous.Agent.Context.new() |> Nous.Agent.Context.add_message(Nous.Message.user("hi"))
      iex> Nous.Session.Invariant.verify(ctx, ctx.messages)
      :ok

  """
  @spec verify(Context.t() | nil, [Message.t()]) :: :ok
  def verify(ctx, request_messages)

  def verify(%Context{} = ctx, request_messages) when is_list(request_messages) do
    case mode() do
      :off -> :ok
      mode -> report(mode, ctx, check(ctx, request_messages))
    end
  end

  def verify(nil, _request_messages), do: :ok

  @doc """
  Compare a request against the fold of `ctx.log`. Pure.

  Reads no configuration, logs nothing, emits nothing: `verify/2` is the side
  effect. See the moduledoc for the exact rule and for what the two lists are
  allowed to differ by.

  ## Examples

      iex> ctx = Nous.Agent.Context.new() |> Nous.Agent.Context.add_message(Nous.Message.user("hi"))
      iex> Nous.Session.Invariant.check(ctx, ctx.messages)
      :ok

      iex> ctx = Nous.Agent.Context.new() |> Nous.Agent.Context.add_message(Nous.Message.user("hi"))
      iex> {:violation, details} = Nous.Session.Invariant.check(ctx, [])
      iex> details.kind
      :missing_message

  """
  @spec check(Context.t(), [Message.t()]) :: :ok | {:violation, details()}
  def check(%Context{} = ctx, request_messages) when is_list(request_messages) do
    indexed = Log.derive_indexed(ctx.log)

    with :ok <- reconstructable(request_messages, indexed) do
      tool_pairing(request_messages)
    end
  end

  @doc """
  The configured mode: `config :nous, :session_invariant`, `:warn` when unset.

  A value that is neither a mode nor its string form falls back to the default
  and warns once per VM, rather than raising: a typo in one config line must not
  take down every run.

  ## Examples

      iex> Nous.Session.Invariant.mode() in Nous.Session.Invariant.modes()
      true

  """
  @spec mode() :: mode()
  def mode do
    case Application.get_env(:nous, :session_invariant) do
      nil -> @default_mode
      configured -> coerce_mode(configured)
    end
  end

  @doc """
  The three valid modes.
  """
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc """
  The telemetry event a violation emits: `#{inspect(@violation_event)}`.

  Measurements are `%{count: 1}`; metadata is `t:details/0` plus `:agent_name`
  and `:mode`.
  """
  @spec violation_event() :: [atom()]
  def violation_event, do: @violation_event

  # ---------------------------------------------------------------------------

  defp reconstructable(request, indexed) do
    request = skip_overlay_slot(request, indexed)

    case first_divergence(request, indexed, 0) do
      nil -> :ok
      index -> {:violation, classify(request, indexed, index)}
    end
  end

  # Exemption 1: the overlay (or `BasicAgent`'s `ctx.system_prompt`) can prepend a
  # leading system message that no event produced. It is only ever prepended when
  # the fold has no leading system message of its own, so an extra head is
  # identifiable structurally — no need to know the overlay text, and no way for
  # this to swallow a second system message.
  defp skip_overlay_slot([%Message{role: :system} | rest] = request, indexed) do
    case indexed do
      [{_seq, %Message{role: :system}} | _] -> request
      _ -> rest
    end
  end

  defp skip_overlay_slot(request, _indexed), do: request

  defp first_divergence([], [], _index), do: nil
  defp first_divergence([], [_ | _], index), do: index
  defp first_divergence([_ | _], [], index), do: index

  defp first_divergence([message | request], [{_seq, expected} | indexed], index) do
    if same?(message, expected) do
      first_divergence(request, indexed, index + 1)
    else
      index
    end
  end

  # Exemption 2: system content is assembly-time text the log cannot vouch for.
  # The `==` below is a pointer comparison in the common case, because the
  # request's messages ARE the terms the fold cached.
  defp same?(%Message{role: :system}, %Message{role: :system}), do: true
  defp same?(%Message{} = a, %Message{} = b), do: a == b or fingerprint(a) == fingerprint(b)
  defp same?(_a, _b), do: false

  defp fingerprint(%Message{role: :system}), do: :system

  defp fingerprint(%Message{} = message) do
    {message.role, message.content, message.tool_calls || [], message.tool_call_id, message.name}
  end

  # Only reached once a divergence exists, so this may allocate freely.
  defp classify(request, indexed, index) do
    expected = Enum.map(indexed, &elem(&1, 1))
    request_counts = counts(request)
    expected_counts = counts(expected)
    extra = surplus(request_counts, expected_counts)
    missing = surplus(expected_counts, request_counts)

    %{
      kind: reconstruction_kind(extra, missing),
      index: index,
      request_length: length(request),
      log_length: length(expected),
      extra: extra,
      missing: missing
    }
  end

  # Both non-empty means the request swapped one message for another: report it
  # as `:missing_message`, because losing logged history is the worse half and
  # `:extra`/`:missing` carry the rest of the story either way.
  defp reconstruction_kind(_extra, [_ | _]), do: :missing_message
  defp reconstruction_kind([_ | _], []), do: :extra_message
  defp reconstruction_kind([], []), do: :order

  defp counts(messages) do
    Enum.reduce(messages, %{}, fn message, acc ->
      Map.update(acc, fingerprint(message), 1, &(&1 + 1))
    end)
  end

  defp surplus(left, right) do
    left
    |> Enum.flat_map(fn {fingerprint, count} ->
      case count - Map.get(right, fingerprint, 0) do
        extra when extra > 0 -> List.duplicate(sketch(fingerprint), extra)
        _ -> []
      end
    end)
    |> Enum.take(@max_reported)
  end

  defp sketch(:system), do: %{role: :system}

  defp sketch({role, content, tool_calls, tool_call_id, name}) do
    %{
      role: role,
      preview: preview(content),
      tool_calls: length(tool_calls),
      tool_call_id: tool_call_id,
      name: name
    }
  end

  defp preview(nil), do: nil
  defp preview(content) when is_binary(content), do: String.slice(content, 0, @preview_limit)
  defp preview(content) when is_list(content), do: "[#{length(content)} content parts]"
  defp preview(content), do: inspect(content, printable_limit: @preview_limit)

  # One pass, and it walks the REQUEST: what the provider rejects is what the
  # provider was sent. A `nil` `tool_call_id` is in no `tool_calls` list either,
  # so it reports as the orphan it is.
  defp tool_pairing(messages) do
    messages
    |> Enum.reduce_while(MapSet.new(), fn
      %Message{role: :assistant, tool_calls: calls}, called when is_list(calls) ->
        {:cont, Enum.reduce(calls, called, &MapSet.put(&2, ToolCall.field(&1, :id)))}

      %Message{role: :tool, tool_call_id: id}, called ->
        if MapSet.member?(called, id),
          do: {:cont, called},
          else: {:halt, {:orphan, id}}

      _message, called ->
        {:cont, called}
    end)
    |> case do
      {:orphan, id} -> {:violation, %{kind: :orphaned_tool_result, tool_call_id: id}}
      _called -> :ok
    end
  end

  defp report(_mode, _ctx, :ok), do: :ok

  defp report(mode, %Context{} = ctx, {:violation, details}) do
    :telemetry.execute(
      @violation_event,
      %{count: 1},
      Map.merge(details, %{agent_name: ctx.agent_name, mode: mode})
    )

    case mode do
      :strict -> raise Violation, details: details
      :warn -> Logger.warning(violation_message(details))
    end

    :ok
  end

  defp violation_message(%{kind: :orphaned_tool_result} = details) do
    "Nous.Session.Invariant: the request carries a tool result whose tool_call_id " <>
      "appears in no preceding assistant message (#{inspect(details.tool_call_id)}). " <>
      "Providers reject this with a 400. A replace over a range that was not " <>
      "tool-pair-balanced is the usual cause; see " <>
      "Nous.Transcript.balance_tool_call_boundary/2."
  end

  defp violation_message(details) do
    "Nous.Session.Invariant: the request sent to the model is not reconstructable " <>
      "from the session log (#{details.kind} at position #{details.index}; request " <>
      "#{details.request_length} messages, log #{details.log_length}). " <>
      "#{inspect(Map.take(details, [:extra, :missing]))}. The log is the source of " <>
      "truth for fork, rewind, replay and audit, so a request that diverges from it " <>
      "means this session's recorded history is not what the model saw."
  end

  # Never String.to_atom/1 on configuration that may come from an env var: match a
  # literal whitelist instead.
  defp coerce_mode(mode) when mode in @modes, do: mode
  defp coerce_mode("off"), do: :off
  defp coerce_mode("warn"), do: :warn
  defp coerce_mode("strict"), do: :strict

  # Bad config falls back to the default instead of raising. Raising here would
  # let a typo in one config line take down every run — which is precisely the
  # failure mode `:warn` exists to avoid.
  defp coerce_mode(other) do
    warn_bad_config_once(other)
    @default_mode
  end

  @warned_key {__MODULE__, :bad_config_warned}

  defp warn_bad_config_once(configured) do
    if :persistent_term.get(@warned_key, nil) do
      :ok
    else
      :persistent_term.put(@warned_key, true)

      Logger.warning(
        "invalid `config :nous, :session_invariant` value #{inspect(configured)}; " <>
          "expected one of #{inspect(@modes)}. Falling back to #{inspect(@default_mode)}."
      )
    end
  end
end
