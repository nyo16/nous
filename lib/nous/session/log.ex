defmodule Nous.Session.Log do
  @moduledoc """
  An append-only event log with a model-visible surface derived by folding.

  The log is the source of truth. `derive_messages/1` projects it into the
  `[%Nous.Message{}]` list every existing caller already reads, so the log can be
  internal while `result.messages` stays byte-identical (plan constraint D2).

  ## Replace, don't delete

      {:ok, log} = Log.append(log, :assistant_message, %{content: "…"})
      {:ok, log} = Log.append(log, :system_message, %{
        content: "[summary of 1-40]",
        surface_op: {:replace, 1, 40}
      })

  After that append, `derive_messages/1` shows the summary in place of events 1
  through 40, while `events/1` still returns all of them. Compaction stops
  destroying history — which is the whole point, and what makes fork, rewind and
  audit possible later.

  ## Cost

  Folding on every read would make the O(n) append this replaced look cheap. The
  fold is memoized against `replace_generation` — a counter bumped only by a
  replace — plus the event count, so an ordinary append extends the cached list
  instead of rebuilding it, and a replace invalidates it exactly once.

  ## What is *not* in the log

  The system prompt **rewrite** performed per request by
  `Nous.AgentRunner.PromptAssembly` is assembly-time state, not history: it is
  derived from agent config, plugins and skills at request time, it is replaced
  wholesale on every request, and logging each rewrite would append N copies of
  the same text to a durable log. System messages that are genuinely part of the
  transcript — the initial one, and the summary
  `Nous.Plugins.Summarization` appends — are `:system_message` events like any
  other. See `Nous.Session.Event`.
  """

  alias Nous.Message
  alias Nous.Session.Event

  require Logger

  @typedoc """
  `events` is kept newest-first so an append is O(1); `events/1` reverses.

  `cache` holds `{replace_generation, event_count, messages}` — see the moduledoc
  on cost.
  """
  @type t :: %__MODULE__{
          events: [Event.t()],
          next_seq: non_neg_integer(),
          replace_generation: non_neg_integer(),
          cache: {non_neg_integer(), non_neg_integer(), [Message.t()]} | nil
        }

  defstruct events: [], next_seq: 0, replace_generation: 0, cache: nil

  @doc """
  An empty log.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Append an event.

  `seq` is assigned here and is always contiguous — it equals the event's index,
  which is what lets `{:replace, start, stop}` name a range without storing
  pointers.

  Returns `{:error, reason}` on an invalid event; a bad event must never take down
  a live run.

  `time` defaults to now. Pass it explicitly when the event records something that
  already happened, which is required in two places: appending an existing
  `%Nous.Message{}` must reproduce that message's own `created_at` (the fold
  stamps from the event time, so re-stamping would make `add_message/2` lossy),
  and rebuilding a log from persisted events must keep their original times rather
  than the moment of the restore.

  ## Examples

      iex> log = Nous.Session.Log.new()
      iex> {:ok, log} = Nous.Session.Log.append(log, :user_message, %{content: "hi"})
      iex> {:ok, log} = Nous.Session.Log.append(log, :assistant_message, %{content: "hello"})
      iex> Enum.map(Nous.Session.Log.events(log), & &1.seq)
      [0, 1]

  """
  @spec append(t(), Event.type(), map(), DateTime.t() | nil) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = log, type, data, time \\ nil) when is_map(data) do
    case Event.new(log.next_seq, type, data, time) do
      {:ok, event} -> {:ok, put_event(log, event)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Append an event, logging and returning the log unchanged on failure.

  For call sites inside the agent loop, where losing one bookkeeping event is
  strictly better than failing the user's run. The failure is never silent.
  """
  @spec append!(t(), Event.type(), map(), DateTime.t() | nil) :: t()
  def append!(%__MODULE__{} = log, type, data, time \\ nil) do
    case append(log, type, data, time) do
      {:ok, log} ->
        log

      {:error, reason} ->
        Logger.warning(
          "Nous.Session.Log: dropping invalid #{inspect(type)} event (#{inspect(reason)}). " <>
            "The run continues, but this session's log is now incomplete."
        )

        log
    end
  end

  @doc """
  Every event ever appended, oldest first, including shadowed ones.
  """
  @spec events(t()) :: [Event.t()]
  def events(%__MODULE__{events: events}), do: Enum.reverse(events)

  @doc """
  Events from `seq` onward, oldest first. Costs O(number returned), not O(log).

  `events/1` reverses the whole list, which is fine for a one-off read and wrong
  for anything on the append path — publishing newly committed events runs on
  every append, and so does a consumer catching up from a known seq. Because
  events are stored newest-first, taking the tail walks only what is new.

  `seq` at or beyond the end returns `[]`.

  ## Examples

      iex> log = Nous.Session.Log.new()
      iex> {:ok, log} = Nous.Session.Log.append(log, :user_message, %{content: "a"})
      iex> {:ok, log} = Nous.Session.Log.append(log, :user_message, %{content: "b"})
      iex> Nous.Session.Log.since(log, 1) |> Enum.map(& &1.data.content)
      ["b"]
      iex> Nous.Session.Log.since(log, 5)
      []

  """
  @spec since(t(), non_neg_integer()) :: [Event.t()]
  def since(%__MODULE__{events: events, next_seq: next_seq}, seq)
      when is_integer(seq) and seq >= 0 do
    events
    |> Enum.take(max(next_seq - seq, 0))
    |> Enum.reverse()
  end

  @doc """
  The number of events, shadowed ones included.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{next_seq: next_seq}), do: next_seq

  @doc """
  The surface events, in the order the model sees them: surface-typed events that
  no later replace has shadowed.

  A replacing event takes the position of the range it replaces, **not** its own
  append position. A summary of events 0–40 belongs where those events were; put
  at the end it would read as "here is the conversation, and now a summary of the
  part that came before it", and it would leave a `:tool` message at the head with
  no assistant prelude, which every provider rejects.

  ## Examples

      iex> log = Nous.Session.Log.new()
      iex> {:ok, log} = Nous.Session.Log.append(log, :user_message, %{content: "one"})
      iex> {:ok, log} = Nous.Session.Log.append(log, :step_start, %{})
      iex> {:ok, log} = Nous.Session.Log.append(log, :assistant_message, %{content: "two"})
      iex> Enum.map(Nous.Session.Log.surface(log), & &1.type)
      [:user_message, :assistant_message]

  """
  @spec surface(t()) :: [Event.t()]
  def surface(%__MODULE__{} = log) do
    all = events(log)
    shadowed = shadowed_seqs(all)

    all
    |> Enum.filter(fn event ->
      Event.surface?(event) and not MapSet.member?(shadowed, event.seq)
    end)
    |> Enum.sort_by(&position/1)
  end

  # `Enum.sort_by/2` is stable, so events sharing a position (a replace and a
  # later plain append that happens to start there) keep their append order.
  defp position(%Event{seq: seq} = event) do
    case Event.surface_op(event) do
      {:replace, start, _stop} -> start
      :append -> seq
    end
  end

  @doc """
  Fold the surface into `{seq, message}` pairs, in the order the model sees them.

  This is the primitive; `derive_messages/1` drops the seqs. Compaction needs the
  pairs: to replace "these messages" it has to name a seq range, and the mapping
  from message position to originating event is exactly what the projection rules
  decide. Re-deriving that mapping outside this module means re-implementing the
  drop rule below, which is how the two would silently diverge.

  Projection rules:

    * `:system_message`, `:user_message`, `:assistant_message` → a message of that
      role, reproduced field for field
    * `:tool_result` → a `:tool` message carrying `tool_call_id` and `name`
    * everything else → nothing

  Nothing else is filtered. An assistant event with neither content nor tool calls
  still projects: it is what happened, and dropping it made
  `Nous.Agent.Context.last_message/1` and output extraction disagree with the log.

  Memoized; see the moduledoc on cost.
  """
  @spec derive_indexed(t()) :: [{non_neg_integer(), Message.t()}]
  def derive_indexed(%__MODULE__{
        cache: {gen, count, indexed},
        replace_generation: gen,
        next_seq: count
      }),
      do: indexed

  def derive_indexed(%__MODULE__{} = log) do
    log |> surface() |> Enum.flat_map(&project_indexed/1)
  end

  @doc """
  The message list every caller sees: `derive_indexed/1` without the seqs.
  """
  @spec derive_messages(t()) :: [Message.t()]
  def derive_messages(%__MODULE__{} = log) do
    log |> derive_indexed() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  `derive_messages/1`, returning the log with the fold memoized.

  Callers that hold the log (`Nous.Agent.Context`) should use this so a later read
  is free. The cache holds the indexed pairs, so a later `derive_indexed/1` is
  free too.
  """
  @spec materialize(t()) :: {[Message.t()], t()}
  def materialize(%__MODULE__{} = log) do
    indexed = derive_indexed(log)

    {Enum.map(indexed, &elem(&1, 1)),
     %{log | cache: {log.replace_generation, log.next_seq, indexed}}}
  end

  @doc """
  Seed a log from a flat message list, one surface event per message, in order.

  This is the v1→v2 persistence bridge and what `Nous.run(agent, messages: [...])`
  uses. Messages with an unrecognised role are dropped with a warning rather than
  guessed at.

  Each event takes its message's own `created_at` as its time, so seeding is
  lossless: `seed/1 |> derive_messages/1` returns the input list, timestamps
  included. Re-stamping here would make `Nous.Agent.Context.new(messages: …)`
  quietly rewrite the history it was handed.
  """
  @spec seed([Message.t()]) :: t()
  def seed(messages) when is_list(messages) do
    Enum.reduce(messages, new(), fn message, log ->
      case seed_event(message) do
        {type, data} ->
          append!(log, type, data, Map.get(message, :created_at))

        :skip ->
          Logger.warning(
            "Nous.Session.Log.seed/1: dropping a message with unsupported role " <>
              "#{inspect(Map.get(message, :role))}"
          )

          log
      end
    end)
  end

  # ---------------------------------------------------------------------------

  defp put_event(log, event) do
    generation =
      case Event.surface_op(event) do
        {:replace, _start, _stop} -> log.replace_generation + 1
        :append -> log.replace_generation
      end

    %{
      log
      | events: [event | log.events],
        next_seq: log.next_seq + 1,
        replace_generation: generation,
        cache: extend_cache(log, event, generation)
    }
  end

  # An ordinary append can extend the cached fold in place — that is what keeps
  # the common path off an O(n) rebuild. A replace invalidates it; the next read
  # pays once.
  defp extend_cache(%{cache: {gen, count, indexed}} = log, event, generation)
       when gen == generation and count == log.next_seq do
    {generation, log.next_seq + 1, indexed ++ project_indexed(event)}
  end

  defp extend_cache(_log, _event, _generation), do: nil

  # Shadowing is by **position**, not by raw seq, and that distinction is
  # load-bearing once more than one replace exists.
  #
  # A replace that rewrites a single event in place — pruning an oversized tool
  # result, say — has a HIGH seq but the LOW position of the event it replaced. A
  # later summary covering that region names a *position* range; if shadowing
  # matched raw seqs, the pruning event's own seq would sit outside the range and
  # its message would survive inside the summarized region. That yields an
  # orphaned tool result (its assistant message shadowed, the result not), which
  # every provider rejects, and a stale summary that outlives its own
  # replacement, so compaction would not be repeatable.
  #
  # `seq < replacing.seq` is also how "a replace cannot swallow the future" is
  # stated: an event appended after the replace is never shadowed by it. With no
  # replaces in the log, `position/1` is the identity on seq, so this is a strict
  # generalization of the simpler rule.
  defp shadowed_seqs(events) do
    positions = Map.new(events, &{&1.seq, position(&1)})

    Enum.reduce(events, MapSet.new(), fn event, acc ->
      case Event.surface_op(event) do
        {:replace, start, stop} ->
          Enum.reduce(events, acc, fn candidate, acc ->
            pos = Map.fetch!(positions, candidate.seq)

            if candidate.seq < event.seq and pos >= start and pos <= stop do
              MapSet.put(acc, candidate.seq)
            else
              acc
            end
          end)

        :append ->
          acc
      end
    end)
  end

  # Pair each projected message with the seq of the event that produced it, so a
  # caller can name a range without re-deriving the drop rule.
  defp project_indexed(%Event{seq: seq} = event) do
    Enum.map(project(event), &{seq, &1})
  end

  # A projection REPRODUCES a message; it never re-derives one. Every field comes
  # straight out of the event, and the struct is built directly rather than through
  # `Message.system/1` and friends.
  #
  # Going through the constructors was wrong three ways, each found by a test:
  #
  #   * they stamp `created_at` from the clock, so the fold was not deterministic —
  #     re-materializing after each append rewrote every timestamp to the moment of
  #     the last append, and two folds of one log could never compare equal;
  #   * they take only the fields their signature names, so `metadata` and `name`
  #     were dropped. `metadata` is where multimodal content lives
  #     (`metadata.content_parts`, which all three provider adapters read back), so
  #     a vision run silently lost its images while appearing to work;
  #   * they COERCE their input. `Message.user/2` treats list content as content
  #     parts and calls `ContentPart.to_text/1`, which only knows `%ContentPart{}`
  #     — so a hand-built message whose content is a list of plain maps crashed the
  #     fold with a `FunctionClauseError`.
  #
  # Building the struct sidesteps all three. It also skips validation, which is
  # correct here: these fields were validated when the message was first created,
  # and a projection that "fixes up" history is a projection that lies about it.
  #
  # For the same reason, the fold FILTERS NOTHING. The plan called for skipping an
  # assistant event with neither content nor tool calls, on the grounds that some
  # providers reject an empty assistant turn — but that is a fact about what a
  # *request* may contain, not about what happened, and this is history. Dropping
  # it was measurably a D2 break: `Context.last_message/1` returned the user
  # message instead, `BasicAgent.extract_output/2` found nothing, and a run whose
  # model replied with empty content (a content filter, a `max_tokens` cutoff, a
  # provider hiccup, streaming before the first delta) turned from `{:ok, ""}` into
  # `{:error, :no_output}`. If a provider needs empty turns removed, the request
  # builder is where that belongs; the fold reproduces, it does not decide.
  defp project(%Event{type: :system_message} = event), do: [reproduce(:system, event)]
  defp project(%Event{type: :user_message} = event), do: [reproduce(:user, event)]
  defp project(%Event{type: :assistant_message} = event), do: [reproduce(:assistant, event)]
  defp project(%Event{type: :tool_result} = event), do: [reproduce(:tool, event)]
  defp project(%Event{}), do: []

  defp reproduce(role, %Event{time: time, data: data}) do
    %Message{
      role: role,
      content: Map.get(data, :content),
      reasoning_content: Map.get(data, :reasoning_content),
      tool_calls: Map.get(data, :tool_calls) || [],
      tool_call_id: Map.get(data, :tool_call_id),
      name: Map.get(data, :name),
      metadata: Map.get(data, :metadata) || %{},
      created_at: time
    }
  end

  defp seed_event(%Message{role: :system} = msg), do: {:system_message, message_data(msg)}
  defp seed_event(%Message{role: :user} = msg), do: {:user_message, message_data(msg)}

  defp seed_event(%Message{role: :assistant} = msg) do
    {:assistant_message,
     msg |> message_data() |> Map.put(:tool_calls, msg.tool_calls || []) |> put_reasoning(msg)}
  end

  defp seed_event(%Message{role: :tool} = msg) do
    {:tool_result, msg |> message_data() |> Map.put(:tool_call_id, msg.tool_call_id)}
  end

  defp seed_event(_other), do: :skip

  # `name` is stored for every role, not just `:tool` — it is legal on all four
  # and OpenAI uses it, and the projection reads it back from here.
  defp message_data(%Message{} = msg) do
    %{content: msg.content, metadata: msg.metadata || %{}, name: msg.name}
  end

  defp put_reasoning(data, %Message{reasoning_content: nil}), do: data

  defp put_reasoning(data, %Message{reasoning_content: r}),
    do: Map.put(data, :reasoning_content, r)
end
