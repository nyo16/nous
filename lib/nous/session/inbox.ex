defmodule Nous.Session.Inbox do
  @moduledoc """
  Two ordered queues of messages waiting to enter a run: `next_turn` and
  `next_step`.

  This is what makes an agent something you can talk to *while it is working*.
  A run claims from the inbox at two boundaries — once when a turn opens, and
  again at every step boundary — so a message that arrives mid-run joins the
  **next** model request instead of being lost, queued behind a minutes-long
  tool call, or cancelling the work already in flight.

  ## One primitive, three presets

  `send/4` is the primitive: a message, a `target` queue, and whether the send
  should `wakeup` an idle agent. The three presets are the only combinations
  anyone has needed:

  | Preset       | Target       | Wakes an idle agent? | Meaning                                            |
  |--------------|--------------|----------------------|----------------------------------------------------|
  | `followup/2` | `:next_turn` | yes                  | "answer this after you finish what you are doing"  |
  | `steer/2`    | `:next_step` | yes                  | "read this before your next model request"         |
  | `inject/2`   | `:next_step` | **no**               | "have this to hand *if* you make another request"  |

  The fourth combination — `:next_turn` without a wake — is deliberately not a
  preset: a turn only opens when something starts it, so a non-waking turn
  message would sit until an unrelated run happened to begin. `send/4` still
  allows it for anyone who wants exactly that.

  `inject/2` is the subtle one, and it is the whole reason the primitive takes
  `wakeup` separately from `target`: injected context **waits for the next
  admitted request rather than starting one**. Injecting into an idle agent
  costs nothing and does nothing observable until the agent runs again for some
  other reason. Steering an idle agent starts it.

  ## Ordering

  Each queue is FIFO: messages are claimed in the order they were sent.

  The two queues are never merged and never compete. They are drained at
  different moments in a run, and that ordering — not a priority rule — is what
  decides who goes first when both hold messages:

      turn opens ──▶ claim(:next_turn) ──▶ step boundary ──▶ claim(:next_step) ──▶ model request

  So with both queues populated, everything in `next_turn` lands in the
  transcript ahead of everything in `next_step`, because the turn's claim
  happens before the first step's. Within each queue, send order is preserved.
  On later steps of the same turn only `next_step` is claimed — `next_turn` is
  already empty, and anything arriving there afterwards waits for a genuinely
  new turn.

  ## Pure data

  No processes, no timers, no pids. The inbox is a value its owner keeps (for
  agents driven by `Nous.AgentServer`, that owner is the server's state), and
  claiming returns the drained inbox rather than mutating anything.

  It is also **serializable**: `send/4` normalizes a binary to a
  `Nous.Message`, and nothing else ever enters the queues. A pid in here would
  fail `Nous.Session.Event.new/4`'s serializability validation the moment it
  reached the log, and would be meaningless after a restart anyway.

  ## Not part of streaming

  `Nous.AgentRunner.run_stream/3` runs exactly one iteration and is out of
  scope for turns, steps and the inbox by design. It never claims, so nothing
  queued here can reach it.

  ## Example

      iex> alias Nous.Session.Inbox
      iex> inbox = Inbox.new() |> Inbox.inject("recall: the deploy is frozen") |> Inbox.steer("stop and summarize")
      iex> Inbox.wake?(inbox)
      true
      iex> {claimed, inbox} = Inbox.claim(inbox, :next_step)
      iex> Enum.map(claimed, & &1.content)
      ["recall: the deploy is frozen", "stop and summarize"]
      iex> Inbox.pending?(inbox)
      false

  """

  alias __MODULE__
  alias Nous.Message

  @typedoc "Which boundary a message waits for."
  @type target :: :next_turn | :next_step

  @typedoc """
  One queued message plus the wake intent of the `send/4` that queued it.

  `wakeup` belongs to the entry rather than to the inbox as a whole because it
  has to survive being queued: a `steer/2` that arrives while the last step of a
  run is already in flight is still pending when the run ends, and it is that
  entry — not a flag somebody set on the side — that says a new run is owed.
  """
  @type entry :: %{message: Message.t(), wakeup: boolean()}

  @type t :: %Inbox{next_turn: [entry()], next_step: [entry()]}

  defstruct next_turn: [], next_step: []

  @targets [:next_turn, :next_step]

  @doc """
  An empty inbox.
  """
  @spec new() :: t()
  def new, do: %Inbox{}

  @doc """
  Queue `message` on `target`, recording whether it should wake an idle agent.

  The primitive behind `followup/2`, `steer/2` and `inject/2`. `message` may be
  a `Nous.Message` or a binary, which becomes a user message.

  ## Examples

      iex> inbox = Nous.Session.Inbox.send(Nous.Session.Inbox.new(), "hi", :next_step, false)
      iex> Nous.Session.Inbox.wake?(inbox)
      false

  """
  @spec send(t(), Message.t() | String.t(), target(), boolean()) :: t()
  def send(%Inbox{} = inbox, message, target, wakeup)
      when target in @targets and is_boolean(wakeup) do
    entry = %{message: normalize(message), wakeup: wakeup}

    # Append at the tail to keep the queue FIFO without a reversal step. These
    # queues hold what a human managed to type while a model was thinking, so
    # the O(n) append is measured in single digits and buys readable state that
    # every caller can inspect and serialize.
    Map.update!(inbox, target, &(&1 ++ [entry]))
  end

  @doc """
  Queue `message` for the next **turn**, waking an idle agent.

  "Answer this once you have finished what you are doing." It does not
  interrupt a run in flight, and it does not join the current turn.
  """
  @spec followup(t(), Message.t() | String.t()) :: t()
  def followup(%Inbox{} = inbox, message), do: send(inbox, message, :next_turn, true)

  @doc """
  Queue `message` for the next **step**, waking an idle agent.

  Mid-run steering: the next model request in the current run sees it. On an
  idle agent it starts a run.
  """
  @spec steer(t(), Message.t() | String.t()) :: t()
  def steer(%Inbox{} = inbox, message), do: send(inbox, message, :next_step, true)

  @doc """
  Queue `message` for the next **step** without waking anything.

  Context for a request the agent was going to make anyway. On an idle agent
  this is inert: it waits for the next admitted request rather than starting
  one.
  """
  @spec inject(t(), Message.t() | String.t()) :: t()
  def inject(%Inbox{} = inbox, message), do: send(inbox, message, :next_step, false)

  @doc """
  Take everything queued on `target`, in send order, and return the drained
  inbox.

  The other queue is untouched.

  ## Examples

      iex> alias Nous.Session.Inbox
      iex> inbox = Inbox.new() |> Inbox.followup("later") |> Inbox.steer("now")
      iex> {claimed, inbox} = Inbox.claim(inbox, :next_turn)
      iex> Enum.map(claimed, & &1.content)
      ["later"]
      iex> Inbox.pending?(inbox, :next_step)
      true

  """
  @spec claim(t(), target()) :: {[Message.t()], t()}
  def claim(%Inbox{} = inbox, target) when target in @targets do
    entries = Map.fetch!(inbox, target)
    {Enum.map(entries, & &1.message), Map.put(inbox, target, [])}
  end

  @doc """
  Whether anything at all is queued.
  """
  @spec pending?(t()) :: boolean()
  def pending?(%Inbox{next_turn: [], next_step: []}), do: false
  def pending?(%Inbox{}), do: true

  @doc """
  Whether anything is queued on `target`.
  """
  @spec pending?(t(), target()) :: boolean()
  def pending?(%Inbox{} = inbox, target) when target in @targets,
    do: Map.fetch!(inbox, target) != []

  @doc """
  How many messages are queued across both queues.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%Inbox{next_turn: next_turn, next_step: next_step}),
    do: length(next_turn) + length(next_step)

  @doc """
  Whether any queued message asked for a wake.

  This is the question an idle agent's owner asks — both when a message arrives
  and again when a run finishes. Because the answer is carried by the entries
  themselves, a `steer/2` that lands too late for the run in flight is still
  answered by the next transition instead of needing a flag to remember it.

  ## Examples

      iex> alias Nous.Session.Inbox
      iex> Inbox.new() |> Inbox.inject("fyi") |> Inbox.wake?()
      false
      iex> Inbox.new() |> Inbox.inject("fyi") |> Inbox.steer("go") |> Inbox.wake?()
      true

  """
  @spec wake?(t()) :: boolean()
  def wake?(%Inbox{next_turn: next_turn, next_step: next_step}) do
    Enum.any?(next_turn, & &1.wakeup) or Enum.any?(next_step, & &1.wakeup)
  end

  defp normalize(%Message{} = message), do: message
  defp normalize(text) when is_binary(text), do: Message.user(text)
end
