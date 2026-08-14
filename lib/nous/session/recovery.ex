defmodule Nous.Session.Recovery do
  @moduledoc """
  Close what a crash left open in a session log — by appending, never by
  truncating.

  A crash mid-run leaves an **orphaned `:turn_start`**: a turn that opened and
  never closed. That is the only durable trace of "we died in the middle of
  something", and it is what this module looks for. The repair is new events:

    * one synthetic `:tool_result` per tool call the turn still owed, each
      carrying a **risk class** (see below), and
    * a `:turn_end` with `reason: :interrupted` — the one reason no live loop
      ever emits, so finding it in a log is unambiguous evidence of a crash
      rather than of an ordinary exit. `Nous.AgentRunner.IterationLoop` closes a
      turn with `:complete` or `:rejected` only (its `@live_turn_end_reasons`);
      a loop that exits `{:error, reason}` returns no context at all, so nothing
      downstream could persist a `:turn_end` for it. `:interrupted` is reserved
      for this module, and covers both the crash and that lost-tail case.

  Nothing is deleted and nothing is rewritten. Truncating back to the last clean
  boundary is the easy repair and it is the wrong one: the turn really did
  happen, its tool calls really may have fired, and a log that drops the
  evidence cannot answer the only question a human has after a crash — *did that
  side effect happen?*

  Recovery is **idempotent**. Recovering an already-recovered log finds no
  orphan (its `:turn_start` now has a `:turn_end`) and appends nothing.
  Detection keys on the event *type* only, never on `reason` or on any risk
  metadata, so a persisted blob that came back through JSON with
  `"interrupted"` where an atom used to be cannot change the outcome. Event
  types survive a restore through a literal whitelist
  (`Nous.Agent.Context.deserialize/1`), which is what makes them safe to
  dispatch on at all.

  ## The risk classes, and how each is derived

  A synthetic result carries `metadata.risk`, one of:

    * `:tool_not_started` — the call never reached the executor. It did not run
      and had no side effects.
    * `:tool_outcome_unknown` — the call may have run and its result was lost.
      A human has to check before retrying.

  The distinction is what a person actually needs after a crash, so it is read
  off the log rather than guessed. In order, first match wins:

  | # | What the log shows | Class |
  | - | ------------------ | ----- |
  | 1 | a `:tool_call` event for this id, and no `:tool_result` | `:tool_outcome_unknown` |
  | 2 | no `:tool_call` event for this id, but the turn logged `:tool_call` for *other* ids | `:tool_not_started` |
  | 3 | the turn logged no dispatch at all, and the call's enclosing `:step_start` has a matching `:step_end` | `:tool_not_started` |
  | 4 | anything else | `:tool_outcome_unknown` |

  Why each rule says what it says:

    * **1.** A `:tool_call` event is written when the call is handed to the
      executor. Its presence means dispatch happened, so the tool may well have
      run — an unknown outcome, never a safe "did not run", even if the
      enclosing step later closed.
    * **2.** Absence of a `:tool_call` event is only *evidence* when the log is
      known to record dispatches. If the turn recorded one for a sibling call,
      this call's silence means it never got that far.
    * **3.** With no dispatch bookkeeping to read, the step boundary is the next
      best fact. `:step_end` is emitted even when the step errored, so a step
      that closed had nothing in flight: a call still owing a result at that
      point was never dispatched.
    * **4.** The fallback is deliberately the pessimistic one. Wrongly saying
      "may have run" costs a human one check; wrongly saying "did not run" is
      how a duplicate charge or a second `rm -rf` happens.

  ## Relationship to `Nous.Agent.Context.patch_dangling_tool_calls/1`

  That function stays exactly as it is: the **in-memory fast path**. It reads
  `ctx.messages`, finds assistant tool calls with no matching tool result
  anywhere in the transcript, and appends one generic synthetic result each. It
  is turn-blind, which is its strength — it needs no bookkeeping events, so it
  works on a v1-seeded log, on a context a user hand-assembled, and on
  everything `Nous.run/3` produces today.

  This module is the **durable, turn-aware** generalization. It fires only on an
  orphaned `:turn_start`, repairs only what that turn owed, and classifies each
  repair. The differences are the point:

    * A clean log — every turn closed — is left completely untouched. No
      synthetic events at all, even if it contains a dangling call, because a
      closed turn owing a result is not a crash, and inventing history for it
      would be the fold lying.
    * A log with no turn events has no orphan, so recovery is a no-op and
      `patch_dangling_tool_calls/1` is the only repair available.

  When both apply, run recovery **first**. Its classified results satisfy the
  owed calls, after which `patch_dangling_tool_calls/1` finds nothing dangling
  and does nothing. The other order loses the classification: the generic result
  lands first and recovery sees the call as already answered.

  ## Where turns come from, and where they do not

  `Nous.run_stream/3` runs exactly one iteration and is explicitly out of scope
  for turns — it emits no `:turn_start`, so a streamed session can never present
  an orphan here, and `patch_dangling_tool_calls/1` remains its repair. That is
  a deliberate scope decision, not an omission.
  """

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Session.Event
  alias Nous.Session.Log

  require Logger

  @typedoc "Anything recovery can read: a context, a log, or a loaded event list."
  @type source :: Context.t() | Log.t() | [Event.t()]

  @typedoc "How much a lost tool result endangers a human's assumptions."
  @type risk :: :tool_not_started | :tool_outcome_unknown

  @typedoc "One event recovery wants to append: `{type, data}`."
  @type repair :: {Event.type(), map()}

  @not_started_content "Tool call was interrupted before it was dispatched. " <>
                         "It did not run and had no side effects. Retry if needed."

  @unknown_content "Tool call was dispatched but the session was interrupted before its " <>
                     "result was recorded. It MAY have run and MAY have had side effects. " <>
                     "Verify state before retrying."

  @doc """
  Whether the log was left mid-turn, i.e. whether a crash needs repairing.

  ## Examples

      iex> log = Nous.Session.Log.new()
      iex> {:ok, log} = Nous.Session.Log.append(log, :turn_start, %{turn: 1})
      iex> Nous.Session.Recovery.interrupted?(log)
      true
      iex> {:ok, log} = Nous.Session.Log.append(log, :turn_end, %{turn: 1, reason: :complete})
      iex> Nous.Session.Recovery.interrupted?(log)
      false

  """
  @spec interrupted?(source()) :: boolean()
  def interrupted?(source), do: open_turns(source) != []

  @doc """
  The `:turn_start` events that never got a `:turn_end`, innermost first.

  Turns do not nest, so this is empty or a single event in every log a healthy
  emitter produces. It returns a list anyway because a corrupted or
  double-started log must be describable rather than crash the load — and
  because `Nous.Session.fork/2` needs to name the turn a boundary landed inside.
  """
  @spec open_turns(source()) :: [Event.t()]
  def open_turns(source), do: source |> event_list() |> scan() |> Map.fetch!(:turn_stack)

  @doc """
  The events recovery would append, in append order, without appending them.

  One `{:tool_result, data}` per owed call, then one `{:turn_end, data}` per
  orphaned turn. Empty for a clean log — which is the whole guarantee that
  recovery never touches a session that did not crash.

  Exposed because "what would you change, and why" is a question an operator
  asks *before* accepting a repair, and because a caller holding neither a log
  nor a context (a raw event list straight off a persistence backend) can still
  inspect the damage.
  """
  @spec plan(source()) :: [repair()]
  def plan(source) do
    scan = source |> event_list() |> scan()
    Enum.flat_map(scan.turn_stack, &repairs(&1, scan))
  end

  @doc """
  Apply `plan/1`, appending the repairs.

  Returns the same kind it was given. A `Nous.Session.Log` gets the events
  appended directly; a `Nous.Agent.Context` gets them through `add_message/3`
  and `log_event/3` so `messages` and the fold stay in lockstep — a synthetic
  tool result is a surface event, and writing it any other way would leave the
  two disagreeing.

  A clean log comes back untouched, including its fold cache: `plan/1` is empty,
  so nothing is appended and nothing re-materializes.

  `needs_response` is deliberately preserved on the context path, matching
  `patch_dangling_tool_calls/1`. Appending a tool result normally flips it to
  `true`, which would make repairing a crashed session equivalent to deciding to
  resume it. Recovery's job is to make history honest; whether to run again is
  the caller's call.
  """
  @spec recover(Log.t()) :: Log.t()
  @spec recover(Context.t()) :: Context.t()
  def recover(target)

  def recover(%Log{} = log), do: Enum.reduce(plan(log), log, &apply_repair/2)

  def recover(%Context{} = ctx) do
    case plan(ctx) do
      [] ->
        ctx

      repairs ->
        %{Enum.reduce(repairs, ctx, &apply_repair/2) | needs_response: ctx.needs_response}
    end
  end

  # ---------------------------------------------------------------------------

  defp apply_repair({type, data}, %Log{} = log), do: Log.append!(log, type, data)

  defp apply_repair({:tool_result, data}, %Context{} = ctx) do
    Context.add_message(
      ctx,
      Message.tool(data.tool_call_id, data.content, name: data.name, metadata: data.metadata)
    )
  end

  defp apply_repair({type, data}, %Context{} = ctx), do: Context.log_event(ctx, type, data)

  defp event_list(%Context{log: log}), do: Log.events(log)
  defp event_list(%Log{} = log), do: Log.events(log)
  defp event_list(events) when is_list(events), do: events

  # One pass over the log answers every question the rules ask. Turns and steps
  # are paired with a stack rather than by their `turn`/`step` numbers: the
  # numbers are advisory data an emitter may omit, while the pairing is
  # structural and always present.
  defp scan(events), do: Enum.reduce(events, initial_scan(), &observe/2)

  defp initial_scan do
    %{
      # Open scopes, newest first. Whatever is still here at the end is orphaned.
      turn_stack: [],
      step_stack: [],
      closed_steps: MapSet.new(),
      # Ids the log recorded a dispatch for, and the turns that recorded any.
      dispatched: MapSet.new(),
      dispatch_turns: MapSet.new(),
      # Ids that already have a result — from the run, or from a prior recovery.
      resulted: MapSet.new(),
      steps_per_turn: %{},
      owed: [],
      seen: MapSet.new()
    }
  end

  defp observe(%Event{type: :turn_start} = event, acc) do
    %{acc | turn_stack: [event | acc.turn_stack]}
  end

  defp observe(%Event{type: :turn_end} = event, %{turn_stack: []} = acc) do
    Logger.warning(
      "Nous.Session.Recovery: :turn_end at seq #{event.seq} closes no open turn; " <>
        "this log's turn bookkeeping is inconsistent"
    )

    acc
  end

  defp observe(%Event{type: :turn_end}, %{turn_stack: [_closed | rest]} = acc) do
    %{acc | turn_stack: rest}
  end

  defp observe(%Event{type: :step_start, seq: seq}, acc) do
    %{
      acc
      | step_stack: [seq | acc.step_stack],
        steps_per_turn: Map.update(acc.steps_per_turn, current_turn(acc), 1, &(&1 + 1))
    }
  end

  defp observe(%Event{type: :step_end}, %{step_stack: []} = acc), do: acc

  defp observe(%Event{type: :step_end}, %{step_stack: [closed | rest]} = acc) do
    %{acc | step_stack: rest, closed_steps: MapSet.put(acc.closed_steps, closed)}
  end

  defp observe(%Event{type: :tool_call, data: data}, acc) do
    case call_id(data) do
      nil ->
        acc

      id ->
        acc
        |> Map.put(:dispatched, MapSet.put(acc.dispatched, id))
        |> Map.put(:dispatch_turns, MapSet.put(acc.dispatch_turns, current_turn(acc)))
        |> owe(id, call_name(data))
    end
  end

  # An assistant message names its calls before anything dispatches them, so it
  # is the earlier and more reliable source of "what is owed" — and the only one
  # on a log whose emitter writes no `:tool_call` events at all.
  defp observe(%Event{type: :assistant_message, data: data}, acc) do
    data
    |> Map.get(:tool_calls)
    |> List.wrap()
    |> Enum.reduce(acc, fn call, acc ->
      case call_id(call) do
        nil -> acc
        id -> owe(acc, id, call_name(call))
      end
    end)
  end

  defp observe(%Event{type: :tool_result, data: data}, acc) do
    case call_id(data) do
      nil -> acc
      id -> %{acc | resulted: MapSet.put(acc.resulted, id)}
    end
  end

  defp observe(%Event{}, acc), do: acc

  # First sighting wins: the assistant message that named the call is inside the
  # step that owed the result, whereas a later `:tool_call` event could have been
  # re-logged elsewhere. `dispatched` answers rule 1 independently, so nothing is
  # lost by not overwriting.
  defp owe(acc, id, name) do
    if MapSet.member?(acc.seen, id) do
      acc
    else
      entry = %{id: id, name: name, turn: current_turn(acc), step: current_step(acc)}
      %{acc | owed: [entry | acc.owed], seen: MapSet.put(acc.seen, id)}
    end
  end

  defp current_turn(%{turn_stack: [%Event{seq: seq} | _]}), do: seq
  defp current_turn(%{turn_stack: []}), do: nil

  defp current_step(%{step_stack: [seq | _]}), do: seq
  defp current_step(%{step_stack: []}), do: nil

  # Owed calls are attributed to the turn that was open when they were recorded,
  # so a turn only ever repairs its own debts. A call recorded outside any turn
  # belongs to no orphan and is left to `patch_dangling_tool_calls/1`.
  defp repairs(%Event{} = orphan, scan) do
    results =
      scan.owed
      |> Enum.reverse()
      |> Enum.filter(&owed_by?(&1, orphan, scan))
      |> Enum.map(&{:tool_result, result_data(&1, classify(&1, scan))})

    results ++ [turn_end(orphan, scan)]
  end

  defp owed_by?(call, %Event{seq: turn_seq}, scan) do
    call.turn == turn_seq and not MapSet.member?(scan.resulted, call.id)
  end

  # The rule table in the moduledoc, in order. Keep the two in step.
  defp classify(call, scan) do
    cond do
      MapSet.member?(scan.dispatched, call.id) -> :tool_outcome_unknown
      MapSet.member?(scan.dispatch_turns, call.turn) -> :tool_not_started
      closed_step?(scan, call.step) -> :tool_not_started
      true -> :tool_outcome_unknown
    end
  end

  defp closed_step?(_scan, nil), do: false
  defp closed_step?(scan, step), do: MapSet.member?(scan.closed_steps, step)

  # `risk` rides inside `metadata`, whose contents nothing validates or
  # dispatches on, and which the fold reproduces onto the projected message —
  # so it reaches a LiveView and a human unchanged. Putting it at the top level
  # of the event data would make it a persisted key every reader has to know.
  defp result_data(call, risk) do
    %{
      tool_call_id: call.id,
      name: call.name,
      content: content_for(risk),
      metadata: %{synthetic: true, risk: risk}
    }
  end

  defp content_for(:tool_not_started), do: @not_started_content
  defp content_for(:tool_outcome_unknown), do: @unknown_content

  # Shaped like the live `:turn_end` (`turn`, `steps`, `reason`) so a reader
  # folding turns needs no special case for a recovered one; `reason` is the
  # only thing that marks it.
  defp turn_end(%Event{} = orphan, scan) do
    data = %{reason: :interrupted, steps: Map.get(scan.steps_per_turn, orphan.seq, 0)}
    {:turn_end, put_turn_number(data, orphan)}
  end

  defp put_turn_number(data, %Event{data: %{turn: turn}}) when is_integer(turn),
    do: Map.put(data, :turn, turn)

  defp put_turn_number(data, %Event{}), do: data

  # A call's id arrives under four spellings: `:tool_call_id` on a
  # `:tool_result`, `:id` inside an assistant message's `tool_calls` and on a
  # `:tool_call` event, and either of those as a string key once the event has
  # been through a JSON round trip.
  defp call_id(map) when is_map(map),
    do: first_value(map, [:tool_call_id, "tool_call_id", :id, "id"])

  defp call_id(_other), do: nil

  defp call_name(map) when is_map(map), do: first_value(map, [:name, "name"])
  defp call_name(_other), do: nil

  defp first_value(map, keys), do: Enum.find_value(keys, &stringify(Map.get(map, &1)))

  # Ids are strings everywhere in this codebase, but they come out of provider
  # payloads and persisted blobs, so coerce the two harmless alternatives rather
  # than dropping a call and leaving it dangling. Never `String.to_atom/1` —
  # this is untrusted input, and nothing here needs an atom.
  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value) or is_atom(value), do: to_string(value)
  defp stringify(_other), do: nil
end
