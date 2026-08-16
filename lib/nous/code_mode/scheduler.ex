defmodule Nous.CodeMode.Scheduler do
  @moduledoc """
  Orders the tool sub-calls a Code Mode program makes.

  A program is a *batch* of tool calls the model wrote as code — loops, fan-out,
  branches — and nothing in the program says how those calls may interleave. The
  scheduler decides, and it decides conservatively.

  ## One driver lane

  Every ordering decision (classify, start, commit) happens inside this
  GenServer's own process, so the lane *is* the serialized mailbox: there is no
  bespoke lock, no ETS counter, nothing to get wrong under contention. State is a
  submission-ordered `pending` queue, an `inflight` set, and a head-of-line
  `cursor` that commits settled sub-calls strictly in submission order — a call
  that finishes early waits for its predecessors, so the program observes one
  deterministic order regardless of how the work actually raced.

  Execution itself fans out through `Task.Supervisor.async_nolink/2` on
  `Nous.TaskSupervisor` — the same supervisor and the same
  a-crash-is-a-result policy `Nous.AgentRunner.ToolExecution` uses for parallel
  native tool calls. That module uses `Task.Supervisor.async_stream_nolink/4`
  because it has the whole batch up front; here sub-calls arrive one at a time
  from a running program, so a stream over a finished list is the wrong shape.
  `$callers` is propagated the same way regardless (see "Caller chain" below).

  ## Exclusive by default

  A tool is treated as EXCLUSIVE unless its module exports
  `concurrency_safe?/1` and that function returns exactly `true` for the call's
  arguments. Absent attribute, unloadable module, wrong return, raise, throw or
  exit — all mean exclusive. This is fail-safe, not fail-open: a tool that does
  not say it is safe to run concurrently is assumed unsafe, because the failure
  mode of guessing wrong is interleaved side effects on someone else's data.

  An exclusive call **drains the pool, runs alone, and holds the barrier through
  its commit** — not merely through execution, which would let a concurrent call
  commit inside its window. See `t:mode/0` and the `drive/1` comments.

  ## What the program can see

  A failed sub-call arrives inside the program as
  `{:error, %{"tool" => name, "message" => message}}` — a plain map of two
  strings. Never a struct, never a stacktrace, never a `%Nous.Errors.ToolError{}`
  with its `:original_error` still attached. Model-authored code is one
  prompt-injection hop from the transcript, so the operator's Logger gets the
  detail and the program gets two strings.

  ## Arguments are snapshotted twice

  At submission the scheduler materializes two independent JSON-shaped snapshots
  of the arguments: one dispatched to the tool, one written to the session log.
  Neither path can influence the other, so a tool cannot desync the audit record
  from what actually ran. Normalizing both is also what makes the audit record
  *true*: what the tool received and what the log says are the same shape, and a
  program cannot smuggle a live BEAM handle (pid, ref, port, closure) into a tool
  through the transport.

  ## Session events, outside model history

  Each sub-dispatch appends exactly one BOOKKEEPING `:tool_call` event to the
  `Nous.Agent.Context` the scheduler was handed, at the moment it starts, in
  submission order. Bookkeeping events project to no message
  (`Nous.Session.Log.derive_messages/1`), so `ctx.messages` is unchanged by any
  number of sub-dispatches: only what the program logs or returns re-enters the
  model's context.

  There are two ways to read that trail back. `context/1` is for a caller that
  handed in a real `Nous.Agent.Context`. `logged_events/1` is for one that owns
  none: `Nous.Tools.RunCode` is handed a `%Nous.RunContext{}`, which has no
  session log at all, so it forwards the pairs as
  `Nous.Tool.ContextUpdate.log_event/3` operations and the runner appends them
  to the context that does exist.

  ## Caller chain

  `$callers` is not propagated across `GenServer.start_link/3`, so the scheduler
  captures the starting process's chain and reinstalls it in its own process
  dictionary. Sub-call tasks therefore see `[scheduler, starter | ...]` and
  process-scoped overrides — `Nous.ModelDispatcher.put_dispatcher/1`, Mox
  allowances, Ecto sandbox ownership — keep working inside a sub-call.

  ## Shape

      {:ok, sched} = Scheduler.start_link(dispatch: dispatch, context: ctx)

      # Phase D hands this straight to Nous.CodeMode.bindings/4 as `:dispatch`,
      # and every granted-tool closure routes through the lane.
      Scheduler.dispatch_fun(sched)

      # Or drive it directly: submit many, await in any order.
      {:ok, ticket} = Scheduler.submit(sched, tool, %{"q" => "elixir"}, run_ctx)
      Scheduler.await(sched, ticket)

  The scheduler is one plain module plus one GenServer. It is deliberately not
  supervised: it lives and dies with a single `run_code` call, and `stop/2`
  releases every outstanding caller with an error rather than leaving a program
  blocked on a lane that no longer exists.
  """

  use GenServer

  require Logger

  alias Nous.Agent.Context
  alias Nous.Tool

  @default_max_parallel 10

  # An error message is not a data channel. A tool that returns a megabyte of
  # text should not get to spend the program's (and the model's) budget on it.
  @max_message_chars 2_000

  @opaque_message "tool call failed"
  @crashed_message "tool call did not complete"
  @abandoned_message "code run is over; tool call abandoned"
  @gone_message "code run is over; scheduler is gone"

  @typedoc """
  A scheduler process.
  """
  @type server :: GenServer.server()

  @typedoc """
  Handle for one submitted sub-call. Carries the tool name so `await/3` can name
  the tool even when the scheduler dies before answering.
  """
  @type ticket :: {reference(), String.t()}

  @typedoc """
  What a failed sub-call looks like *inside the program*: two strings and nothing
  else, under the keys `"tool"` and `"message"`.
  """
  @type error :: %{required(String.t()) => String.t()}

  @typedoc """
  The result of one sub-call, as the program sees it.
  """
  @type outcome :: {:ok, term()} | {:error, error()}

  @typedoc """
  How a sub-call actually reaches the tool pipeline.

  Supplied by the caller — the scheduler never calls `Nous.ToolExecutor` itself,
  so it can be driven by a stub with no runtime, no registry and no agent.
  `{:ok, value} | {:error, reason}` only: any other return is a contract breach
  by Nous, logged and surfaced to the program as an opaque failure rather than
  passed through unvetted.
  """
  @type dispatch :: (Tool.t(), map(), term() -> {:ok, term()} | {:error, term()})

  @typedoc """
  `:parallel` may share the pool with up to `max_parallel - 1` others.
  `:exclusive` requires an empty pool and holds the barrier through its commit.
  """
  @type mode :: :parallel | :exclusive

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start a scheduler for one Code Mode run.

  ## Options

    * `:dispatch` (required) — `t:dispatch/0`, how a sub-call reaches the tool
      pipeline.
    * `:context` — the `Nous.Agent.Context` sub-dispatch events are appended to.
      Defaults to a fresh `Nous.Agent.Context.new/0`. Read it back with
      `context/1`.
    * `:max_parallel` — positive integer, default `10`. The ceiling on
      concurrently *executing* sub-calls; exclusive calls ignore it downwards by
      requiring a ceiling of one.
    * `:call_id` — the outer `run_code` call id, used to build the
      `"<call_id>:code:<n>"` correlation id on each session event.
    * `:name` — optional GenServer name.

  Returns `{:error, {:contract, message}}` for misconfiguration, matching
  `Nous.CodeRuntime`'s vocabulary: a malformed scheduler is Nous misusing its own
  seam, and the `run_code` call that carried it should fail cleanly rather than
  take down the run.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {gen_opts, opts} = Nous.Util.split_gen_opts(opts)

    with {:ok, dispatch} <- validate_dispatch(Keyword.get(opts, :dispatch)),
         {:ok, max_parallel} <-
           validate_max_parallel(Keyword.get(opts, :max_parallel, @default_max_parallel)),
         {:ok, ctx} <- validate_context(Keyword.get(opts, :context)) do
      config = %{
        dispatch: dispatch,
        max_parallel: max_parallel,
        ctx: ctx,
        call_id: Keyword.get(opts, :call_id),
        # Captured HERE, in the starting process: `$callers` does not survive
        # GenServer.start_link/3.
        callers: [self() | Process.get(:"$callers", [])]
      }

      GenServer.start_link(__MODULE__, config, gen_opts)
    end
  end

  @doc """
  Queue a sub-call and return immediately.

  The outcome is delivered to `owner` as `{:sub_call, ref, outcome}` when the
  call *commits* — that is, when every earlier sub-call has already committed.
  One process may hold many outstanding tickets, which is what lets a provider
  bridge an async guest without a process per pending host call.

  Returns `{:error, error}` only when the scheduler is already gone; a submission
  never raises, because a binding that explodes is a worse failure than a program
  that reads an error.
  """
  @spec submit(server(), Tool.t(), map(), term(), pid()) :: {:ok, ticket()} | {:error, error()}
  def submit(scheduler, %Tool{} = tool, args, run_ctx, owner \\ self())
      when is_map(args) and is_pid(owner) do
    case safe_call(scheduler, {:submit, tool, args, run_ctx, owner}) do
      {:ok, ref} -> {:ok, {ref, tool.name}}
      :gone -> {:error, error(tool.name, @gone_message)}
    end
  end

  @doc """
  Block until a submitted sub-call commits.

  Monitors the scheduler, so a lane that dies mid-call answers with an error
  instead of blocking the program forever. `timeout` defaults to `:infinity`:
  bounding a run is the runtime provider's job — its budgets are the deadline
  that a program cannot ask to extend — and the scheduler must not invent a
  second, shorter one.
  """
  @spec await(server(), ticket(), timeout()) :: outcome()
  def await(scheduler, ticket, timeout \\ :infinity)

  def await(scheduler, {ref, tool_name}, timeout) when is_reference(ref) do
    monitor = Process.monitor(scheduler)

    receive do
      {:sub_call, ^ref, outcome} ->
        Process.demonitor(monitor, [:flush])
        outcome

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, error(tool_name, @gone_message)}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, error(tool_name, "timed out waiting for the sub-call to commit")}
    end
  end

  @doc """
  Submit a sub-call and block until it commits.

  This is what a binding closure calls. Failure is always data: the caller gets
  `{:error, %{"tool" => _, "message" => _}}`, never an exit and never a raise.
  """
  @spec call(server(), Tool.t(), map(), term()) :: outcome()
  def call(scheduler, %Tool{} = tool, args, run_ctx) do
    case submit(scheduler, tool, args, run_ctx) do
      {:ok, ticket} -> await(scheduler, ticket)
      {:error, _} = error -> error
    end
  end

  @doc """
  The scheduler as a `t:dispatch/0` function.

  This is the Phase D seam: hand it to `Nous.CodeMode.bindings/4` as `:dispatch`
  and every granted-tool closure routes through the lane, with zero changes on
  either side.
  """
  @spec dispatch_fun(server()) :: dispatch()
  def dispatch_fun(scheduler) do
    fn %Tool{} = tool, args, run_ctx -> call(scheduler, tool, args, run_ctx) end
  end

  @doc """
  The context, carrying one bookkeeping `:tool_call` event per *started*
  sub-dispatch.

  `messages` is untouched — that is the whole point of logging sub-dispatches as
  bookkeeping events.
  """
  @spec context(server()) :: Context.t()
  def context(scheduler), do: GenServer.call(scheduler, :context, :infinity)

  @doc """
  The bookkeeping events this scheduler appended, as `{type, data}` pairs in
  submission order.

  This is the read for a transport that owns no `Nous.Agent.Context`, and so has
  nothing useful to do with `context/1`: `Nous.Tools.RunCode` forwards these as
  `Nous.Tool.ContextUpdate.log_event/3` operations, which is how a sub-dispatch
  reaches the real session log.

  A scheduler that is already gone answers `[]` and says so at `warning` level.
  Silently losing an audit trail is the one outcome this path exists to prevent;
  it is unreachable while the caller still holds the link `start_link/1` made,
  and loud if a future caller drops it.
  """
  @spec logged_events(server()) :: [{Nous.Session.Event.type(), map()}]
  def logged_events(scheduler) do
    case safe_call(scheduler, :logged_events) do
      :gone ->
        Logger.warning(
          "code-mode scheduler #{inspect(scheduler)} is gone; its sub-dispatch session " <>
            "events could not be collected and are lost"
        )

        []

      events when is_list(events) ->
        events
    end
  end

  @doc """
  Whether `tool` may run alongside other sub-calls, given `args`.

  Exclusive unless `tool.module` exports `concurrency_safe?/1` and it returns
  exactly `true`. A missing module, a missing export, a non-`true` return, or a
  raise / throw / exit inside the predicate all mean `:exclusive`.
  """
  @spec concurrency_mode(Tool.t(), map()) :: mode()
  def concurrency_mode(%Tool{module: module} = tool, args) do
    if predicate?(module) do
      classify(module, args)
    else
      :exclusive
    end
  catch
    kind, reason ->
      # Reading the attribute is itself untrusted work. Fail safe, loudly.
      Logger.warning(
        "concurrency_safe?/1 for tool #{inspect(tool.name)} failed; treating it as exclusive: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :exclusive
  end

  @doc """
  Tear the lane down, releasing every outstanding caller with an error.

  Queued sub-calls are abandoned, in-flight tasks are terminated, and a sub-call
  that already produced a result still delivers it — in submission order. Safe to
  call on a scheduler that is already gone.
  """
  @spec stop(server(), term()) :: :ok
  def stop(scheduler, reason \\ :normal) do
    GenServer.stop(scheduler, reason)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  One independently materialized, JSON-shaped snapshot of `args`.

  Scalars pass through, maps and lists are rebuilt with string keys, and anything
  that is not JSON — a struct, pid, reference, port or closure — is rendered with
  `inspect/1`. The escape hatch costs an exotic value its type; it never costs the
  snapshot its serializability, which is what keeps a session event appendable and
  keeps a live BEAM handle out of both the audit log and the tool.

  Called twice per sub-call, on the raw arguments, so the dispatched and logged
  snapshots are separate terms that cannot influence each other.
  """
  @spec snapshot(term()) :: term()
  def snapshot(args), do: normalize(args)

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(config) do
    # Reinstall the starting process's caller chain so async_nolink/2 hands it
    # to every sub-call task.
    Process.put(:"$callers", config.callers)

    {:ok,
     %{
       dispatch: config.dispatch,
       max_parallel: config.max_parallel,
       call_id: config.call_id,
       ctx: config.ctx,
       # Reverse-ordered {type, data} pairs of every event appended to `ctx`, for
       # a transport that has no Context of its own to read them out of. See
       # `logged_events/1`.
       logged: [],
       next_seq: 0,
       # Head-of-line commit cursor: the seq that is allowed to commit next.
       cursor: 0,
       pending: :queue.new(),
       inflight: %{},
       settled: %{},
       # seq of the exclusive sub-call holding the barrier, or nil.
       exclusive: nil
     }}
  end

  @impl true
  def handle_call({:submit, tool, args, run_ctx, owner}, _from, state) do
    seq = state.next_seq

    # TWO INDEPENDENT SNAPSHOTS, taken here, before anything runs. Not two
    # references to one term: a tool that mutates state its arguments reach
    # cannot make the audit record disagree with what was dispatched.
    dispatched = snapshot(args)

    entry = %{
      seq: seq,
      ref: make_ref(),
      owner: owner,
      tool: tool,
      run_ctx: run_ctx,
      dispatched: dispatched,
      logged: snapshot(args),
      # Classified on the snapshot the tool will actually receive, not on the
      # raw term, so the predicate and the tool agree about the arguments.
      mode: concurrency_mode(tool, dispatched)
    }

    state = %{state | next_seq: seq + 1, pending: :queue.in(entry, state.pending)}

    {:reply, {:ok, entry.ref}, drive(state)}
  end

  @impl true
  def handle_call(:context, _from, state), do: {:reply, state.ctx, state}

  @impl true
  def handle_call(:logged_events, _from, state),
    do: {:reply, Enum.reverse(state.logged), state}

  @impl true
  def handle_info({ref, outcome}, state) when is_map_key(state.inflight, ref) do
    # The task answered. Its :DOWN is now noise.
    Process.demonitor(ref, [:flush])
    {{entry, _pid}, inflight} = Map.pop!(state.inflight, ref)

    {:noreply, drive(%{state | inflight: inflight, settled: settle(state, entry, outcome)})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.inflight, ref) do
    # The task died without answering — killed, or an exit signal from outside.
    # Whatever the reason says, the program gets none of it.
    {{entry, _pid}, inflight} = Map.pop!(state.inflight, ref)

    Logger.warning(
      "code-mode sub-call #{inspect(entry.tool.name)} died: #{Exception.format_exit(reason)}"
    )

    outcome = {:error, error(entry.tool.name, @crashed_message)}

    {:noreply, drive(%{state | inflight: inflight, settled: settle(state, entry, outcome)})}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.pending
    |> :queue.to_list()
    |> Enum.each(&abandon/1)

    Enum.each(state.inflight, fn {_ref, {entry, pid}} ->
      Task.Supervisor.terminate_child(Nous.TaskSupervisor, pid)
      abandon(entry)
    end)

    # These really did run. Deliver the truth, still in submission order.
    state.settled
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.each(fn {_seq, {entry, outcome}} -> deliver(entry, outcome) end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # The lane
  # ---------------------------------------------------------------------------

  # Commit first, then start, then stop. Running commit before start is what
  # makes the exclusive barrier free: by the time an exclusive call is eligible
  # (empty pool), every earlier call has necessarily already committed, so
  # `cursor == seq` below is an invariant this ordering guarantees rather than a
  # condition it hopes for.
  defp drive(state) do
    case commit_head(state) do
      {:ok, state} ->
        drive(state)

      :none ->
        case start_next(state) do
          {:ok, state} -> drive(state)
          :none -> state
        end
    end
  end

  defp commit_head(state) do
    case Map.pop(state.settled, state.cursor) do
      {nil, _settled} ->
        :none

      {{entry, outcome}, settled} ->
        deliver(entry, outcome)

        # The barrier is released HERE, at commit — not when the task settled.
        # An exclusive call owns the lane through its own commit, so no
        # concurrent call can start, finish or commit inside its window.
        exclusive = if state.exclusive == entry.seq, do: nil, else: state.exclusive

        {:ok, %{state | settled: settled, cursor: state.cursor + 1, exclusive: exclusive}}
    end
  end

  defp start_next(state) do
    case :queue.out(state.pending) do
      {:empty, _pending} ->
        :none

      {{:value, entry}, pending} ->
        if startable?(state, entry) do
          {:ok, start_entry(%{state | pending: pending}, entry)}
        else
          :none
        end
    end
  end

  # Submission order is start order, so only the head of the queue is ever asked.
  defp startable?(%{exclusive: seq}, _entry) when is_integer(seq), do: false

  defp startable?(state, %{mode: :exclusive, seq: seq}) do
    map_size(state.inflight) == 0 and state.cursor == seq
  end

  defp startable?(state, %{mode: :parallel}) do
    map_size(state.inflight) < state.max_parallel
  end

  defp start_entry(state, entry) do
    dispatch = state.dispatch

    # Audit first, then run: the record exists before the tool can do anything,
    # including tearing the run down. Appending here also means the payload is
    # validated at start, not whenever someone gets around to reading the trail.
    {type, data} = event = dispatch_event(state, entry)
    ctx = Context.log_event(state.ctx, type, data)

    task =
      Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
        run_dispatch(dispatch, entry)
      end)

    exclusive = if entry.mode == :exclusive, do: entry.seq, else: state.exclusive

    %{
      state
      | inflight: Map.put(state.inflight, task.ref, {entry, task.pid}),
        exclusive: exclusive,
        ctx: ctx,
        logged: [event | state.logged]
    }
  end

  # Built at START, inside the lane, so the audit record exists before the tool
  # can do anything — including tearing the run down — and lands in submission
  # order because starts are FIFO.
  #
  # ONE construction site, two destinations: the `Context` this scheduler holds
  # and the `logged` list a transport reads. Re-deriving that list from the log
  # instead would mean guessing which events were ours in a Context the caller
  # may have arrived with events already in.
  defp dispatch_event(state, entry) do
    {:tool_call,
     %{
       id: sub_call_id(state.call_id, entry.seq),
       name: entry.tool.name,
       arguments: entry.logged,
       mode: entry.mode,
       seq: entry.seq,
       source: :code_mode
     }}
  end

  defp sub_call_id(nil, seq), do: "code:#{seq}"
  defp sub_call_id(call_id, seq), do: "#{call_id}:code:#{seq}"

  defp settle(state, entry, outcome) do
    Map.put(state.settled, entry.seq, outcome_pair(entry, outcome))
  end

  defp outcome_pair(entry, {:ok, _value} = outcome), do: {entry, outcome}
  defp outcome_pair(entry, {:error, _error} = outcome), do: {entry, outcome}

  # A task that returned something the contract does not allow is Nous misusing
  # its own seam. The program gets nothing informative; the operator gets it all.
  defp outcome_pair(entry, other) do
    Logger.error(
      "code-mode dispatch for #{inspect(entry.tool.name)} returned an unexpected shape: " <>
        inspect(other)
    )

    {entry, {:error, error(entry.tool.name, @opaque_message)}}
  end

  defp deliver(entry, outcome), do: send(entry.owner, {:sub_call, entry.ref, outcome})

  defp abandon(entry), do: deliver(entry, {:error, error(entry.tool.name, @abandoned_message)})

  # ---------------------------------------------------------------------------
  # Dispatch, inside the task
  # ---------------------------------------------------------------------------

  defp run_dispatch(dispatch, entry) do
    case dispatch.(entry.tool, entry.dispatched, entry.run_ctx) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, error(entry.tool.name, message_for(reason))}
      other -> other
    end
  catch
    kind, reason ->
      # The whole failure, with its stacktrace, goes to the operator.
      Logger.warning(
        "code-mode sub-call #{inspect(entry.tool.name)} raised: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error, error(entry.tool.name, raised_message(kind, reason, __STACKTRACE__))}
  end

  # A raise carries a message the tool author wrote for a caller to read, so the
  # program may see it. A throw or an exit carries a term nobody wrote for
  # publication, so it does not.
  defp raised_message(:error, reason, stacktrace) do
    message_for(Exception.normalize(:error, reason, stacktrace))
  end

  defp raised_message(_kind, _reason, _stacktrace), do: @opaque_message

  defp error(tool_name, message), do: %{"tool" => tool_name, "message" => message}

  defp message_for(reason) when is_binary(reason), do: clamp(reason)

  defp message_for(reason)
       when is_atom(reason) and not is_nil(reason) and not is_boolean(reason) do
    Atom.to_string(reason)
  end

  defp message_for(exception) when is_exception(exception) do
    clamp(Exception.message(exception))
  rescue
    # An exception whose own message/1 raises is not going to get a second
    # chance to leak anything.
    _error -> @opaque_message
  end

  # Tuples, maps, non-exception structs: whatever internals they hold, they were
  # not written for the program to read. `inspect/1` here is exactly how a
  # `%Nous.Errors.ToolError{original_error: ...}` would leak.
  defp message_for(_reason), do: @opaque_message

  defp clamp(message) do
    if String.length(message) > @max_message_chars do
      String.slice(message, 0, @max_message_chars) <> "… (truncated)"
    else
      message
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshots
  # ---------------------------------------------------------------------------

  defp normalize(term)
       when is_binary(term) or is_number(term) or is_boolean(term) or is_nil(term),
       do: term

  defp normalize(term) when is_list(term), do: Enum.map(term, &normalize/1)

  # Before the generic map clause: a struct is not a JSON object.
  defp normalize(%_struct{} = term), do: inspect(term)

  defp normalize(term) when is_map(term) do
    Map.new(term, fn {key, value} -> {normalize_key(key), normalize(value)} end)
  end

  defp normalize(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.map(&normalize/1)
  end

  defp normalize(term) when is_atom(term), do: Atom.to_string(term)

  # pid, reference, port, function
  defp normalize(term), do: inspect(term)

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_number(key), do: to_string(key)
  defp normalize_key(key), do: inspect(key)

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  defp predicate?(nil), do: false

  defp predicate?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :concurrency_safe?, 1)
  end

  defp predicate?(_module), do: false

  defp classify(module, args) do
    case module.concurrency_safe?(args) do
      true -> :parallel
      _other -> :exclusive
    end
  end

  defp validate_dispatch(dispatch) when is_function(dispatch, 3), do: {:ok, dispatch}

  defp validate_dispatch(other) do
    {:error, {:contract, ":dispatch must be a 3-arity function, got #{inspect(other)}"}}
  end

  defp validate_max_parallel(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp validate_max_parallel(other) do
    {:error, {:contract, ":max_parallel must be a positive integer, got #{inspect(other)}"}}
  end

  defp validate_context(nil), do: {:ok, Context.new()}
  defp validate_context(%Context{} = ctx), do: {:ok, ctx}

  defp validate_context(other) do
    {:error, {:contract, ":context must be a Nous.Agent.Context, got #{inspect(other)}"}}
  end

  defp safe_call(scheduler, message) do
    GenServer.call(scheduler, message, :infinity)
  catch
    :exit, _reason -> :gone
  end
end
