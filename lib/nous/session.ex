defmodule Nous.Session do
  @moduledoc """
  A session: an id, its event log, and — if it was forked — where it came from.

  ## What a session *is* at this stage, and what it is not

  Deliberately the smallest thing that carries `{id, log, parent}` honestly. It
  is a **handle on a log with provenance**, not a new persistence layer:

    * `id` is the session id every other part of the system already keys on —
      `Nous.AgentServer`'s `session_id`, the key a `Nous.Persistence` backend
      saves under, and the input to `Nous.PubSub.agent_topic/1`.
    * `log` is a `Nous.Session.Log`. It is the whole state; nothing here caches a
      projection of it.
    * `parent` is `nil`, or `%{session_id: id, seed_length: n}` — the session
      this one was forked from, and how many of this log's events were inherited
      from it. Because `seq` equals the index, `seed_length` is also the boundary:
      events with `seq < seed_length` came from the parent, everything at or
      after it belongs to this session.

  There is no new serialization format and no new backend. Persistence already
  has exactly one contract — the four-callback `Nous.Persistence` behaviour, with
  ETS as the only shipped implementation — and `Nous.Agent.Context.serialize/1`
  is already `version: 2` carrying the full event list. A session persists by
  going through those:

      {:ok, ctx} = Nous.Session.to_context(session)
      MyBackend.save(session.id, Nous.Agent.Context.serialize(ctx))

  **Known limit, stated rather than papered over:** that round trip carries the
  log, not the `parent` link. Recording provenance durably means adding a field
  to the v2 blob, which is a change to `Context.serialize/1` and belongs in the
  phase that owns it. Until then a fork's parentage is in-memory only, and a
  caller that needs it durable must store it alongside (it is two scalars).

  ## Forking

  `fork/2` copies a prefix of the log into a fresh session. It refuses a
  boundary that lands inside an open turn — see `fork/2` for why that is an
  error and not a clip.

  ## Rendering from the log

  Every event committed into a `Nous.Agent.Context` is broadcast as

      {:session_event, %Nous.Session.Event{}}

  on the context's `pubsub_topic` — which `Nous.AgentServer` sets to
  `Nous.PubSub.agent_topic(session_id)`, so this rides the existing topic scheme
  rather than adding one. A LiveView subscribing there can render the
  transcript, tool calls, turns and steps from the log itself instead of from
  ad-hoc callbacks, and `Nous.Session.Log.since/2` fills the gap between the
  last `seq` it rendered and the log it loads on reconnect.

  Bookkeeping events are published too — `:turn_start`, `:step_end` and friends
  are exactly what a UI needs to show progress, and the existing
  `{:agent_delta, _}`/`{:tool_call, _}` callback messages stay untouched
  alongside them. Publishing is a no-op when the context has no pubsub or no
  topic, which is every context built without them.
  """

  alias Nous.Agent.Context
  alias Nous.Session.Log
  alias Nous.Session.Recovery

  @typedoc """
  Where a forked session came from: the parent's id, and how many of this
  session's leading events were inherited from it.
  """
  @type parent :: %{session_id: String.t(), seed_length: non_neg_integer()}

  @type t :: %__MODULE__{
          id: String.t(),
          log: Log.t(),
          parent: parent() | nil
        }

  @typedoc """
  Where to cut a fork: the `seq` of the last event to inherit (inclusive, the
  same convention as `{:replace, start, stop}`), or `:last` for the whole log.
  """
  @type boundary :: non_neg_integer() | :last

  @enforce_keys [:id]
  defstruct [:id, :parent, log: %Log{}]

  @doc """
  Build a session.

  ## Options

    * `:id` — the session id. Generated if omitted.
    * `:log` — a `Nous.Session.Log` (default: empty).
    * `:parent` — provenance, when the caller already knows it. `fork/2` sets it.

  ## Examples

      iex> session = Nous.Session.new(id: "s1")
      iex> {session.id, Nous.Session.Log.count(session.log), session.parent}
      {"s1", 0, nil}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id) || generate_id(),
      log: Keyword.get(opts, :log) || Log.new(),
      parent: Keyword.get(opts, :parent)
    }
  end

  @doc """
  A session over the log a context is holding.

  The context keeps its own copy; this takes a handle on the same log, which is
  immutable, so the two cannot drift.
  """
  @spec from_context(Context.t(), keyword()) :: t()
  def from_context(%Context{} = ctx, opts \\ []) do
    new(Keyword.put_new(opts, :log, ctx.log))
  end

  @doc """
  Rebuild a runnable `Nous.Agent.Context` from a session's log.

  Goes through the shipped `version: 2` reader rather than assigning
  `ctx.log` directly: `messages` is a materialized view of the log, and a
  caller that sets one without the other leaves them out of step. Using the
  persistence path means a forked session loads by exactly the same code as a
  restored one, bookkeeping events included.

  Runtime-only fields (`pubsub`, `notify_pid`, callbacks, deps) come back empty,
  as they do for any restored context — `Nous.AgentServer` re-attaches its own.
  """
  @spec to_context(t()) :: {:ok, Context.t()} | {:error, term()}
  def to_context(%__MODULE__{log: log}) do
    events =
      Enum.map(Log.events(log), fn event ->
        %{seq: event.seq, type: event.type, time: event.time, data: event.data}
      end)

    Context.deserialize(%{version: 2, events: events})
  end

  @doc """
  Fork a session at `boundary`, copying the event prefix into a new session.

  `boundary` is a `t:boundary/0`: the `seq` of the last event to inherit, or
  `:last` for the whole log. Anything else comes back as
  `{:error, {:invalid_boundary, term}}` — the argument is validated rather than
  merely typed, because a boundary usually arrives from outside the code (a UI
  selection, a stored bookmark, a seq read back off a persisted blob).

  The fork records its parent's id and the number of events it inherited, so it
  stays traceable to its origin.

  Copied events keep their original `seq`. That is not cosmetic: a
  `{:replace, start, stop}` names a range by position, and renumbering the
  prefix would silently move every compaction range in it. It also means
  `seed_length` cleanly separates inherited history from the fork's own.

  ## Why an open turn is an error

      {:error, {:open_turn, seq}}

  A prefix that ends inside a turn that never closed would hand the fork a
  half-finished turn as its inheritance: tool calls owing results that will
  never arrive, and a turn a later reader cannot tell from one this fork
  abandoned itself. Clipping back to the last clean boundary is the other
  obvious option and it is worse — it silently returns something other than what
  the caller asked for, and the caller cannot tell it happened.

  `:last` is not special-cased. If the log's final turn is open, `:last` is a
  boundary inside an open turn and errors like any other. The caller has two
  honest fixes: `Nous.Session.Recovery.recover/1` first, which closes the turn
  with `reason: :interrupted` and makes `:last` legal, or pick an earlier
  boundary explicitly.

  ## Examples

      iex> log = Nous.Session.Log.new()
      iex> {:ok, log} = Nous.Session.Log.append(log, :user_message, %{content: "hi"})
      iex> {:ok, log} = Nous.Session.Log.append(log, :assistant_message, %{content: "yo"})
      iex> {:ok, fork} = Nous.Session.fork(Nous.Session.new(id: "parent", log: log), 0)
      iex> {fork.parent, Nous.Session.Log.count(fork.log)}
      {%{session_id: "parent", seed_length: 1}, 1}

  """
  @spec fork(t(), term()) :: {:ok, t()} | {:error, term()}
  def fork(session, boundary \\ :last)

  def fork(%__MODULE__{} = session, boundary) do
    with {:ok, take} <- resolve(session.log, boundary),
         prefix = Enum.take(Log.events(session.log), take),
         :ok <- reject_open_turn(prefix),
         {:ok, log} <- copy(prefix) do
      {:ok, new(log: log, parent: %{session_id: session.id, seed_length: length(prefix)})}
    end
  end

  # ---------------------------------------------------------------------------

  # `take` is an exclusive count, `boundary` an inclusive seq. They differ by one
  # because `seq` equals the index, which is also why `seed_length` doubles as
  # the inherited/own dividing line.
  defp resolve(%Log{} = log, :last), do: {:ok, Log.count(log)}

  defp resolve(%Log{} = log, seq) when is_integer(seq) and seq >= 0 do
    count = Log.count(log)
    if seq < count, do: {:ok, seq + 1}, else: {:error, {:boundary_out_of_range, seq, count}}
  end

  defp resolve(%Log{}, other), do: {:error, {:invalid_boundary, other}}

  defp reject_open_turn(prefix) do
    case Recovery.open_turns(prefix) do
      [] -> :ok
      [innermost | _] -> {:error, {:open_turn, innermost.seq}}
    end
  end

  # Replaying the prefix through `append/4` re-runs validation and rebuilds the
  # replace generation, and — because the prefix starts at seq 0 and `seq` is
  # contiguous — reassigns exactly the seqs the events already had. An event that
  # will not append is reported rather than skipped: dropping one would shift
  # every seq after it and corrupt the ranges this copy exists to preserve.
  defp copy(events) do
    Enum.reduce_while(events, {:ok, Log.new()}, fn event, {:ok, log} ->
      case Log.append(log, event.type, event.data, event.time) do
        {:ok, log} -> {:cont, {:ok, log}}
        {:error, reason} -> {:halt, {:error, {:uncopyable_event, event.seq, reason}}}
      end
    end)
  end

  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
