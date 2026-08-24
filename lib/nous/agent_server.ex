defmodule Nous.AgentServer do
  @moduledoc """
  GenServer wrapper for Nous agents with PubSub integration.

  This server:
  - Wraps a Nous agent (standard or ReAct)
  - Links to parent process (dies when parent dies)
  - Subscribes to PubSub for incoming messages
  - Publishes responses back via PubSub
  - Maintains conversation context for multi-turn conversations

  ## Context-Based State

  Uses `Nous.Agent.Context` to maintain conversation state:
  - Messages accumulate across turns
  - Tool calls are tracked
  - Usage is aggregated
  - Callbacks forward to PubSub

  ## Usage with LiveView

      defmodule MyAppWeb.ChatLive do
        use MyAppWeb, :live_view

        def mount(_params, _session, socket) do
          # Start agent linked to this LiveView
          {:ok, agent_pid} = AgentServer.start_link(
            session_id: socket.assigns.session_id,
            agent_config: %{
              model: "lmstudio:qwen3-vl-4b-thinking-mlx",
              instructions: "You are a helpful assistant",
              tools: []
            }
          )

          # Subscribe to responses. Always build the topic with
          # Nous.PubSub.agent_topic/1 — it is what this server publishes to.
          Phoenix.PubSub.subscribe(MyApp.PubSub, Nous.PubSub.agent_topic(socket.assigns.session_id))

          {:ok, assign(socket, agent_pid: agent_pid, messages: [])}
        end

        def handle_event("send_message", %{"message" => msg}, socket) do
          AgentServer.send_message(socket.assigns.agent_pid, msg)
          {:noreply, socket}
        end

        # Receive streaming deltas
        def handle_info({:agent_delta, text}, socket) do
          # Append text to current response
          {:noreply, update(socket, :current_response, &(&1 <> text))}
        end

        # Receive complete response
        def handle_info({:agent_complete, result}, socket) do
          messages = socket.assigns.messages ++ [%{role: :assistant, content: result.output}]
          {:noreply, assign(socket, messages: messages, current_response: "")}
        end

        # Receive tool calls
        def handle_info({:tool_call, call}, socket) do
          # Show tool call in UI
          {:noreply, socket}
        end
      end

  ## Message Interruption

  Calling `send_message/2` while the agent is already processing a request
  automatically cancels the in-flight execution and starts a new one. The
  server uses an `:atomics`-based flag so the running task can detect
  cancellation without message-passing overhead. Both the interrupted
  user message and the new one are preserved in the conversation context,
  so no input is lost.

  ## PubSub Events

  Subscribers on the `Nous.PubSub.agent_topic(session_id)` topic (currently
  `"nous:agent:<session_id>"`) receive the following messages:

  | Message                          | Description                             |
  |----------------------------------|-----------------------------------------|
  | `{:agent_status, :thinking}`     | A new run is about to start             |
  | `{:agent_status, :started}`      | The LLM provider acknowledged the call  |
  | `{:agent_delta, text}`           | A streaming text chunk                  |
  | `{:tool_call, call}`             | A tool invocation is in progress        |
  | `{:tool_result, result}`         | A tool returned its result              |
  | `{:agent_response, output}`      | The final text output of the run        |
  | `{:agent_complete, result}`      | The full result struct (output + context + usage) |
  | `{:agent_error, message}`        | An error occurred during execution      |
  | `{:agent_cancelled, reason}`     | The execution was cancelled             |
  | `{:session_event, %Nous.Session.Event{}}` | One committed log event — surface and bookkeeping alike |

  `{:session_event, _}` is published by `Nous.Agent.Context` itself for every
  event committed to the session log, which is why nothing in this server
  broadcasts it: `init/1` already points the run context at this topic. It is
  the message to render a transcript from, since it also carries the turn and
  step boundaries (`:turn_start`, `:step_start`, `:step_end`, `:turn_end`) that
  the ad-hoc callbacks above cannot express.

  ## Steering and injection

  `send_message/2` is the interrupting path: it cancels whatever is in flight
  and starts over. The inbox paths never interrupt anything — they queue a
  message and let the run claim it at its next boundary:

  | Call         | Queued for | Wakes an idle agent? |
  |--------------|------------|----------------------|
  | `followup/2` | next turn  | yes                  |
  | `steer/2`    | next step  | yes                  |
  | `inject/2`   | next step  | **no**               |

  `steer/2` and `inject/2` differ in exactly one bit, and it is the bit people
  get wrong. Worked example, on an agent that is idle after its last run:

      # Nothing happens. No model request, no tokens, no run. The note is queued
      # and will be handed to the next request the agent makes anyway.
      AgentServer.inject(pid, "FYI: the staging deploy is frozen until 14:00")

      # This starts a run. It claims the injected note *and* this message, in
      # that order, so both are in the first request's message list.
      AgentServer.steer(pid, "Which services are still pending release?")

  Mid-run, the distinction is about latency rather than about starting work:

      AgentServer.send_message(pid, "Audit every service for stale configs")
      # ... the agent is three tool calls deep ...
      AgentServer.steer(pid, "Actually, skip anything under /legacy")
      # The NEXT model request of that same run sees the instruction. The tool
      # call already in flight is neither interrupted nor cancelled, and the
      # message is not claimed by the request that is already on the wire.

  Both accept a binary or a `Nous.Message`, and both are safe to call whether or
  not a run is in flight.

  ## Run state

  The server keeps an explicit `run_state` of `:idle` or `:running`, and every
  transition into `:idle` goes through one function. That is what makes `wakeup`
  decidable: `steer/2` on an idle agent must start work and `inject/2` must not,
  and both answers depend on knowing — not inferring — whether a run is in
  flight.

  The upstream implementation this was ported from needs a `wakeRequested` latch
  to cover the window where a message lands after the last claim of a run that
  is about to end. There is no latch here. The wake intent rides on the queued
  message itself (see `Nous.Session.Inbox`), so the `:running -> :idle`
  transition just asks the inbox whether a run is still owed. Enqueueing and
  finishing are both serialized through this process's mailbox, so exactly one
  of the two starts the run.

  ## Lifecycle

  Each server starts an inactivity timer (default 5 minutes, configurable
  via `:inactivity_timeout`). The timer resets on every `send_message/2`
  call. When the timer fires, the server terminates with `:normal`.

  If a `:persistence` backend is configured, the conversation context is
  automatically saved after each successful agent run and restored on
  `start_link/1`.
  """

  use GenServer
  require Logger

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Session.{Inbox, Recovery}

  @type agent_config :: %{
          model: String.t(),
          instructions: String.t(),
          tools: list(),
          type: :standard | :react,
          model_settings: map()
        }

  @type state :: %{
          session_id: String.t(),
          agent: Nous.Agent.t(),
          context: Context.t(),
          pubsub: module() | nil,
          topic: String.t(),
          agent_type: :standard | :react,
          current_task: Task.t() | nil,
          draining: %{optional(reference()) => Task.t()},
          task_generation: non_neg_integer(),
          cancelled_ref: :atomics.atomics_ref(),
          inactivity_timeout: timeout(),
          inactivity_timer_ref: reference() | nil,
          persistence: module() | nil,
          run_state: :idle | :running,
          inbox: Inbox.t()
        }

  # Client API

  @default_inactivity_timeout :timer.minutes(5)

  # Iteration ceiling for every run this server starts.
  @max_run_iterations 15

  # An inbox claim is a queue read on a process that is never blocked waiting on
  # the claiming task, so this is a safety net against a server that has died or
  # wedged, not a tuning knob. The runner treats a timeout as "nothing claimed".
  @claim_timeout 5_000

  # Grace period for a demoted (draining) task to exit after its async
  # `:shutdown` before it is hard-killed. This is the grace the old in-handler
  # Task.shutdown/2 calls used to grant — minus the part where the server
  # blocked while granting it.
  @drain_kill_after 5_000

  @doc """
  Start an AgentServer linked to the calling process.

  ## Options

  - `:session_id` - Unique session identifier (required)
  - `:agent_config` - Agent configuration map (required)
  - `:pubsub` - PubSub module (default: MyApp.PubSub)
  - `:name` - Optional GenServer name (e.g., a Registry via tuple)
  - `:inactivity_timeout` - Inactivity timeout in ms (default: 5 minutes). Set to `:infinity` to disable.
  - `:persistence` - Persistence backend module (e.g., `Nous.Persistence.ETS`). When set, context is auto-saved after each response and restored on init.

  ## Agent Config

  - `:model` - Model string (e.g., "openai:gpt-4")
  - `:instructions` - System instructions
  - `:tools` - List of tool functions
  - `:type` - `:standard` or `:react` (default: :standard)
  - `:model_settings` - Model settings map
  - `:deps` - Initial dependencies for tools

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = Nous.Util.split_gen_opts(opts)
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Send a message to the agent.

  If a previous execution is still running, it is automatically cancelled
  before the new message is processed. The interrupted message and the new
  one both remain in the conversation context. Returns immediately — the
  agent run happens asynchronously and results are broadcast via PubSub.
  """
  @spec send_message(pid(), String.t()) :: :ok
  def send_message(pid, message) do
    GenServer.cast(pid, {:user_message, message})
  end

  @doc """
  Queue a message for the agent's next **step**, waking it if it is idle.

  Mid-run steering. The message is claimed by the next model request of the run
  already in flight — not by the request currently on the wire — and nothing is
  cancelled or discarded. On an idle agent it starts a run.

  `message` may be a binary or a `Nous.Message`. Returns immediately.

  Contrast `inject/2`, which queues to the same place and never starts a run.
  The moduledoc has a worked example of the difference.
  """
  @spec steer(GenServer.server(), Message.t() | String.t()) :: :ok
  def steer(server, message), do: GenServer.cast(server, {:enqueue, message, :next_step, true})

  @doc """
  Queue context for the agent's next **step** without waking it.

  Injected context waits for the next admitted request rather than starting one:
  on an idle agent this is inert until something else makes the agent run, and
  on a running agent it behaves exactly like `steer/2`.

  Use it for material the agent should have *if* it asks another question —
  retrieved documents, a changed permission, a note from another process — where
  spending a model request purely to deliver it would be wrong.

  `message` may be a binary or a `Nous.Message`. Returns immediately.
  """
  @spec inject(GenServer.server(), Message.t() | String.t()) :: :ok
  def inject(server, message), do: GenServer.cast(server, {:enqueue, message, :next_step, false})

  @doc """
  Queue a message for the agent's next **turn**, waking it if it is idle.

  "Answer this once you have finished what you are doing." Unlike
  `send_message/2` it never cancels the run in flight, and unlike `steer/2` it
  does not join that run: it is claimed when the next turn opens.

  `message` may be a binary or a `Nous.Message`. Returns immediately.
  """
  @spec followup(GenServer.server(), Message.t() | String.t()) :: :ok
  def followup(server, message),
    do: GenServer.cast(server, {:enqueue, message, :next_turn, true})

  @doc """
  Get conversation context.
  """
  @spec get_context(pid()) :: Context.t()
  def get_context(pid) do
    GenServer.call(pid, :get_context)
  end

  @doc """
  Get conversation history (messages only).
  """
  @spec get_history(pid()) :: list()
  def get_history(pid) do
    GenServer.call(pid, :get_history)
  end

  @doc """
  Clear conversation context and start fresh.

  Resets messages and tool-call history but preserves the configured
  dependencies (`:deps`) and system prompt.
  """
  @spec clear_history(pid()) :: :ok
  def clear_history(pid) do
    GenServer.cast(pid, :clear_history)
  end

  @doc """
  Cancel the current agent execution.

  Returns `{:ok, :cancelled}` when an execution was running and has been
  told to stop, or `{:ok, :no_execution}` when there was nothing to cancel.

  The server replies immediately — it never waits out the task's shutdown.
  It will:
  - Set the atomics cancellation flag so the task exits at the next check
  - Demote the running task and shut it down asynchronously (escalating to
    a hard kill if it ignores the graceful `:shutdown` for 5 s)
  - Broadcast `{:agent_cancelled, reason}` to PubSub subscribers
  - Reset the flag for future executions
  """
  @spec cancel_execution(pid()) :: {:ok, :cancelled} | {:ok, :no_execution}
  def cancel_execution(pid) do
    GenServer.call(pid, :cancel_execution)
  end

  @doc """
  Manually save the current context to the persistence backend.

  Returns `:ok` on success, `{:error, :no_persistence}` if no backend is configured,
  or `{:error, reason}` on failure.
  """
  @spec save_context(pid()) :: :ok | {:error, term()}
  def save_context(pid) do
    GenServer.call(pid, :save_context)
  end

  @doc """
  Load a previously saved context from the persistence backend.

  Replaces the current context with the loaded one. Patches any dangling tool
  calls that may have been interrupted mid-execution.

  Returns `:ok` on success, `{:error, :no_persistence}` if no backend is configured,
  or `{:error, reason}` on failure.
  """
  @spec load_context(pid(), String.t()) :: :ok | {:error, term()}
  def load_context(pid, session_id) do
    GenServer.call(pid, {:load_context, session_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_config = Keyword.fetch!(opts, :agent_config)
    pubsub = Keyword.get(opts, :pubsub) || Nous.PubSub.configured_pubsub()
    inactivity_timeout = Keyword.get(opts, :inactivity_timeout, @default_inactivity_timeout)
    persistence = Keyword.get(opts, :persistence)

    # Subscribe to messages for this session. Use the helper so the topic
    # matches what publishers via Nous.PubSub.agent_topic/1 send to —
    # previously this was a bare "agent:#{id}" string while the helper
    # returned "nous:agent:#{id}", so external publishers never reached us.
    topic = Nous.PubSub.agent_topic(session_id)
    Nous.PubSub.subscribe(pubsub, topic)

    # Create agent based on type
    agent_type = Map.get(agent_config, :type, :standard)

    agent =
      case agent_type do
        :react ->
          Nous.ReActAgent.new(
            agent_config.model,
            instructions: Map.get(agent_config, :instructions, ""),
            tools: Map.get(agent_config, :tools, []),
            model_settings: Map.get(agent_config, :model_settings, %{})
          )

        :standard ->
          Nous.Agent.new(
            agent_config.model,
            instructions: Map.get(agent_config, :instructions, ""),
            tools: Map.get(agent_config, :tools, []),
            model_settings: Map.get(agent_config, :model_settings, %{})
          )
      end

    # Start with a fresh context; restore persisted state in handle_continue
    # so init/1 doesn't block on persistence I/O. Without this, the parent
    # DynamicSupervisor (and any caller blocked on start_child — notably
    # Teams.Coordinator's spawn_agent handle_call) waits the full load time.
    initial_deps = Map.get(agent_config, :deps, %{})

    context =
      Context.new(
        deps: initial_deps,
        system_prompt: Map.get(agent_config, :instructions, ""),
        agent_name: "agent_server_#{session_id}",
        pubsub: pubsub,
        pubsub_topic: topic
      )

    Logger.info("AgentServer started for session: #{session_id}")

    # Schedule initial inactivity timer
    inactivity_timer_ref = schedule_inactivity_timeout(inactivity_timeout)

    # Atomics for lock-free cancellation checks from the task process.
    # Slot 1: cancel flag for the CURRENT run (reset when a new run starts).
    # Slot 2: current task generation. A task captures its own generation and
    # treats a mismatch as cancellation — so a demoted (draining) task stays
    # cancelled even after the flag is reset for its replacement.
    cancelled_ref = :atomics.new(2, signed: false)

    state = %{
      session_id: session_id,
      agent: agent,
      context: context,
      pubsub: pubsub,
      topic: topic,
      agent_type: agent_type,
      current_task: nil,
      # Superseded tasks that were told to shut down but have not yet died,
      # keyed by their monitor ref. Reaped by the {ref, result}/:DOWN clauses.
      draining: %{},
      # Monotonic task generation counter. Every spawned task captures the
      # generation it ran under; replies whose generation no longer matches
      # the current one are stale (the user sent a new message, called
      # clear_history, or cancelled) and MUST be discarded - otherwise a
      # task that completed milliseconds before the cancel can clobber the
      # freshly-cleared/updated context. See review finding C-5.
      task_generation: 0,
      cancelled_ref: cancelled_ref,
      inactivity_timeout: inactivity_timeout,
      inactivity_timer_ref: inactivity_timer_ref,
      persistence: persistence,
      # Whether a run is in flight. `current_task` alone was nearly this, but
      # it is cleared from five different handlers and an async_nolink task
      # announces its end through three different messages, so "is the agent
      # working?" was spread too thin to base a wake decision on.
      run_state: :idle,
      inbox: Inbox.new()
    }

    {:ok, state, {:continue, :load_persisted_context}}
  end

  @impl true
  def handle_continue(:load_persisted_context, state) do
    case maybe_load_context(state.persistence, state.session_id) do
      {:ok, loaded_ctx} ->
        Logger.info("Restored persisted context for session: #{state.session_id}")

        # Merge initial deps back in (they may contain runtime values like PIDs),
        # then repair an interrupted run. Recovery runs BEFORE the patch: it only
        # fires on an orphaned `:turn_start` and appends risk-classified results
        # (`:tool_not_started` vs `:tool_outcome_unknown`). Patching first would
        # satisfy the owed call with its generic "was interrupted and not
        # executed" result, recovery would then see nothing owed, and the log
        # would claim a tool never ran when it may well have. On a clean or
        # turn-less log recovery is a strict no-op, so the fast path is unchanged.
        new_context =
          loaded_ctx
          |> Context.merge_deps(state.context.deps)
          |> Recovery.recover()
          |> Context.patch_dangling_tool_calls()
          |> Map.merge(%{pubsub: state.pubsub, pubsub_topic: state.topic})

        {:noreply, %{state | context: new_context}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:user_message, message}, state) do
    # Bumping the generation FIRST means any reply that was already in our
    # mailbox (sent by the just-finishing previous task) is immediately
    # stale and will be filtered by handle_info before it can clobber state.
    state = bump_generation(state)

    # Demote any in-flight task; demotion is non-blocking, so the new run
    # starts immediately instead of after the old task's shutdown grace.
    state =
      if state.current_task do
        Logger.warning("Cancelling existing task for new message in session: #{state.session_id}")

        # Set cancelled flag to signal the task to stop
        :atomics.put(state.cancelled_ref, 1, 1)

        demote_current_task(state)
      else
        idle(state)
      end

    # NOTE: do NOT add the user message to the context here. do_agent_run passes
    # `message` as the prompt to AgentRunner.run/3, whose build_context appends
    # it exactly once. Adding it here too doubled the user message in every turn
    # (wasted tokens + corrupted saved history). The post-run context (which
    # includes the message + response) is stored back via :agent_response_ready.
    {:noreply, start_run(state, {:prompt, message})}
  end

  @impl true
  def handle_cast({:enqueue, message, target, wakeup}, state) do
    state = %{state | inbox: Inbox.send(state.inbox, message, target, wakeup)}
    state = reset_inactivity_timer(state)

    # A run in flight will claim this at its next boundary. Otherwise only a
    # waking send starts one — the entire difference between steer/2 and
    # inject/2, decided here against an unambiguous run_state.
    {:noreply, maybe_wake(state)}
  end

  @impl true
  def handle_cast({:_apply_loaded_context, ctx}, state) do
    # Internal cast posted by the async load task in :load_context.
    {:noreply, %{state | context: ctx}}
  end

  @impl true
  def handle_cast(:clear_history, state) do
    Logger.info("Clearing conversation context for session: #{state.session_id}")

    # Bump the generation and signal cancellation BEFORE clearing - otherwise
    # an in-flight task can deliver {:agent_response_ready, ...} after this
    # handler runs and silently re-populate the context we just cleared.
    state = bump_generation(state)
    :atomics.put(state.cancelled_ref, 1, 1)

    state =
      if state.current_task do
        # Old behaviour blocked here in Task.shutdown/2 for up to 2 s; now the
        # task drains asynchronously. A mid-run crash is still surfaced — by
        # the draining :DOWN clause instead of the shutdown return value.
        demote_current_task(state)
      else
        idle(state)
      end

    :atomics.put(state.cancelled_ref, 1, 0)

    # Create fresh context preserving deps and system prompt
    new_context =
      Context.new(
        deps: state.context.deps,
        system_prompt: state.context.system_prompt,
        agent_name: state.context.agent_name
      )

    # The queued input belonged to the conversation being discarded, so it goes
    # with it. Nothing is woken: clear_history is a reset, not a prompt.
    state = %{state | context: new_context, inbox: Inbox.new()}

    # Persist the cleared context off the mailbox so a slow backend can't
    # block. Fire-and-forget (see save_context_async/1 ordering note).
    save_context_async(state)

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_context, _from, state) do
    {:reply, state.context, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    # Return messages from context
    {:reply, state.context.messages, state}
  end

  @impl true
  def handle_call({:claim_inbox, target, generation}, _from, state) do
    # Called by the run task at its turn and step boundaries. Serializing claims
    # through this process is what makes "did the run see my steer?" decidable
    # instead of a race: a claim and an enqueue cannot interleave.
    #
    # The generation tag keeps a DRAINING task honest: demotion is
    # asynchronous, so a superseded task can still reach a claim boundary in
    # the window before its exit signal lands. Handing it messages would steal
    # steering queued for the run that replaced it, so a stale claim gets
    # nothing and the inbox is left untouched.
    if generation == state.task_generation do
      {messages, inbox} = Inbox.claim(state.inbox, target)
      {:reply, messages, %{state | inbox: inbox}}
    else
      {:reply, [], state}
    end
  end

  @impl true
  def handle_call(:cancel_execution, _from, state) do
    case state.current_task do
      nil ->
        Logger.info("No execution to cancel for session: #{state.session_id}")
        {:reply, {:ok, :no_execution}, state}

      _task ->
        Logger.info("Cancelling execution for session: #{state.session_id}")

        # Bump generation FIRST so a reply that is already in the mailbox is
        # filtered as stale rather than overwriting state.
        state = bump_generation(state)

        # Set cancelled flag - the runner will check this via atomics
        :atomics.put(state.cancelled_ref, 1, 1)

        # Demote the task and reply NOW. This handler used to block in
        # Task.shutdown/2 for up to 5 s, stalling every concurrent call on
        # this server (get_context, claim_inbox, ...) behind one cancel.
        state = demote_current_task(state)

        # Broadcast cancellation
        broadcast(state, {:agent_cancelled, "Execution cancelled by user"})

        # Reset the cancelled flag for future executions. The draining task
        # stops seeing the flag raised, but it does not need it: its
        # :shutdown exit signal is already on the way, and anything it still
        # sends is dropped by the generation filter.
        #
        # Idle (via the demotion), but deliberately WITHOUT the inbox wake:
        # the operator just asked this run to stop, and immediately starting
        # another because a steer was still queued would be the opposite of
        # cancelling. Anything queued waits for the next real prompt.
        :atomics.put(state.cancelled_ref, 1, 0)

        {:reply, {:ok, :cancelled}, state}
    end
  end

  @impl true
  def handle_call(:save_context, from, state) do
    case state.persistence do
      nil ->
        {:reply, {:error, :no_persistence}, state}

      _backend ->
        # Same reasoning as {:load_context, _} below: Context.serialize/1 over
        # the full message history plus a user-supplied backend doing arbitrary
        # IO (S3, Postgres under load) must not run on the server process, or
        # it stalls concurrent get_context / cancel_execution calls.
        #
        # The caller still sees a synchronous call: it stays blocked in
        # GenServer.call/3 until the task answers with GenServer.reply/2, so
        # the return value and the "save has landed when this returns"
        # guarantee are both preserved. Only the server stops blocking.
        #
        # Snapshot just the three fields do_save_context/1 needs, exactly as
        # save_context_async/1 does — not the whole state, which holds a live
        # %Task{} and atomics we don't want copied into the spawned process.
        snapshot = %{
          persistence: state.persistence,
          session_id: state.session_id,
          context: state.context
        }

        Task.Supervisor.start_child(Nous.TaskSupervisor, fn ->
          try do
            GenServer.reply(from, do_save_context(snapshot))
          rescue
            # The caller is blocked in GenServer.call/3. If serialize or
            # backend.save RAISES (rather than returning {:error, _}), an
            # unguarded task crash would never reply, wedging the caller until
            # its call timeout. Always answer.
            e -> GenServer.reply(from, {:error, Exception.message(e)})
          catch
            kind, reason -> GenServer.reply(from, {:error, {kind, reason}})
          end
        end)

        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:load_context, session_id}, from, state) do
    case state.persistence do
      nil ->
        {:reply, {:error, :no_persistence}, state}

      backend ->
        # Run the load + deserialize + patch in a supervised task so a
        # slow persistence backend (S3, Postgres under load) doesn't wedge
        # the GenServer and time out concurrent get_context / cancel calls.
        # Reply asynchronously via GenServer.reply/2 when the task is done.
        merge_deps = state.context.deps
        server = self()

        Task.Supervisor.start_child(Nous.TaskSupervisor, fn ->
          try do
            result =
              with {:ok, data} <- backend.load(session_id),
                   {:ok, ctx} <- Context.deserialize(data) do
                # Recovery before the patch — see handle_continue/2 above for
                # why the order is load-bearing.
                ctx =
                  ctx
                  |> Context.merge_deps(merge_deps)
                  |> Recovery.recover()
                  |> Context.patch_dangling_tool_calls()

                {:ok, ctx}
              end

            case result do
              {:ok, ctx} ->
                # Hand the context back to the server before replying so the
                # next call sees the new state.
                :ok = GenServer.cast(server, {:_apply_loaded_context, ctx})
                GenServer.reply(from, :ok)

              {:error, reason} ->
                GenServer.reply(from, {:error, reason})
            end
          rescue
            # The caller is blocked in GenServer.call/3. If backend.load or
            # deserialize RAISES (rather than returning {:error, _}), an
            # unguarded task crash would never reply, wedging the caller until
            # its call timeout. Always answer.
            e -> GenServer.reply(from, {:error, Exception.message(e)})
          catch
            kind, reason -> GenServer.reply(from, {:error, {kind, reason}})
          end
        end)

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:user_message, message}, state) do
    # Handle messages from PubSub
    handle_cast({:user_message, message}, state)
  end

  # Runner notifications arriving via `notify_pid` (set to this server at
  # `run_opts/2`). These are DRAINS, not publishers.
  #
  # The run context already carries `pubsub`/`pubsub_topic`
  # (see `run_opts/2`), so `Nous.Agent.Callbacks.execute/3` broadcasts every
  # one of these events to the very same topic. Re-broadcasting here did two
  # bad things: it delivered every event to subscribers twice, and — because
  # `init/1` subscribes this server to its OWN topic and
  # `Phoenix.PubSub.broadcast/3` does not exclude the sender — the broadcast
  # came straight back into this mailbox and was broadcast again, forever.
  # An idle agent burned a full core (~1.2e8 reductions/s, measured).
  #
  # Keep the clauses: without them these messages fall through to the
  # catch-all, which is fine but hides typos in the runner's event names.
  @impl true
  def handle_info({:agent_delta, _text}, state), do: {:noreply, state}

  @impl true
  def handle_info({:tool_call, _call}, state), do: {:noreply, state}

  @impl true
  def handle_info({:tool_result, _result}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_complete, _result}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_error, _error}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_start, _payload}, state) do
    # Forward start event
    broadcast(state, {:agent_status, :started})
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_message, _message}, state) do
    # LLM message received - could broadcast if needed
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response_ready, generation, context, _result}, state) do
    if generation == state.task_generation do
      state = %{state | context: strip_run_seam(context)}
      save_context_async(state)
      {:noreply, state}
    else
      # Stale reply from a previous task that completed milliseconds before
      # the user sent a new message / called clear_history / cancelled.
      # Discard - the current state already reflects the newer truth.
      Logger.debug(
        "Discarding stale :agent_response_ready (gen #{generation}, current #{state.task_generation})"
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:agent_task_completed, generation, _reason}, state) do
    if generation == state.task_generation do
      {:noreply, finish_run(state)}
    else
      # Stale completion from a previous task; current_task already points
      # to a newer task, do not clear it.
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, _result}, %{current_task: %Task{ref: ref}} = state)
      when is_reference(ref) do
    # async_nolink delivers the task's RETURN value as {ref, result} on success.
    # run_agent_and_respond communicates via explicit send/2 (not its return
    # value), so this message is informational only. Absorb it here (and flush
    # the now-redundant monitor) instead of letting it fall through to the
    # catch-all. This clause handles NORMAL completion; the :DOWN clause below
    # now only fires when the task crashes before returning a value (abnormal
    # exit), since [:flush] purges the :DOWN for the normal-exit case.
    Process.demonitor(ref, [:flush])
    {:noreply, finish_run(state)}
  end

  @impl true
  def handle_info({ref, _result}, %{draining: draining} = state)
      when is_reference(ref) and is_map_key(draining, ref) do
    # A demoted task completed normally before its exit signal landed. Its
    # {:agent_response_ready, ...} / {:agent_task_completed, ...} sends were
    # already dropped as stale by the generation filter; absorb the return
    # value, flush the monitor, and forget the task.
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | draining: Map.delete(draining, ref)}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{current_task: %Task{ref: ref}} = state
      ) do
    # Our current task's monitor fired; clear the task slot.
    {:noreply, finish_run(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{draining: draining} = state)
      when is_map_key(draining, ref) do
    # A draining task finished dying; drop its entry. :shutdown/:killed are
    # the expected ends of a demoted task (grace, then escalation). Anything
    # else is a mid-run crash, which the old synchronous shutdown used to
    # log — keep it visible.
    if reason not in [:normal, :shutdown, :killed] do
      Logger.warning(
        "Draining task for session #{state.session_id} exited abnormally: #{inspect(reason)}"
      )
    end

    {:noreply, %{state | draining: Map.delete(draining, ref)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Some other monitor fired (Phoenix.PubSub, future plugin monitor, or a
    # stale ref from a previous task). Don't clear current_task - that would
    # drop our newer task's bookkeeping.
    {:noreply, state}
  end

  @impl true
  def handle_info({:drain_kill, ref}, state) do
    # Grace period expired for a demoted task. If it is still draining, it
    # ignored the graceful :shutdown (trap_exit, wedged NIF, ...) — escalate
    # to the untrappable kill Task.shutdown/2 would have used, without ever
    # having blocked this server. The :DOWN clause above reaps the entry.
    case state.draining do
      %{^ref => %Task{pid: pid}} -> Process.exit(pid, :kill)
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:inactivity_timeout, state) do
    Logger.info("AgentServer terminating due to inactivity for session: #{state.session_id}")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("AgentServer terminating for session #{state.session_id}: #{inspect(reason)}")

    # Cancel any in-flight task on shutdown. Without this, an LLM stream
    # started under this server would keep consuming tokens (and HTTP
    # connections) until it hit max_iterations, even though the server is
    # going away. Setting the cancelled atomic also lets the runner's
    # cancellation checks short-circuit if it's still running.
    if state.current_task do
      :atomics.put(state.cancelled_ref, 1, 1)
      _ = Task.shutdown(state.current_task, 1_000)
    end

    # Draining tasks already got their graceful :shutdown at demotion time,
    # and the escalation timers die with this process — so the kill is
    # unconditional here. Fire-and-forget: there is nothing left to reap.
    for {_ref, %Task{pid: pid}} <- state.draining, do: Process.exit(pid, :kill)

    :ok
  end

  # Private Functions

  defp schedule_inactivity_timeout(:infinity), do: nil

  defp schedule_inactivity_timeout(timeout) when is_integer(timeout) and timeout > 0 do
    Process.send_after(self(), :inactivity_timeout, timeout)
  end

  defp reset_inactivity_timer(state) do
    # Cancel existing timer if any
    if state.inactivity_timer_ref do
      Process.cancel_timer(state.inactivity_timer_ref)
    end

    # Schedule a new timer
    new_ref = schedule_inactivity_timeout(state.inactivity_timeout)
    %{state | inactivity_timer_ref: new_ref}
  end

  # Fire-and-forget context save, off the GenServer mailbox, so a slow
  # persistence backend (S3/Postgres under load) never blocks the agent loop
  # or stalls concurrent get_context/cancel calls. Used on the hot response
  # path and clear_history. The explicit :save_context call is off-mailbox too
  # (P-2), but stays synchronous from the caller's side by replying from the
  # task. Errors are logged inside do_save_context/1.
  #
  # Ordering note: saves are NOT serialized, so two overlapping saves could in
  # principle land out of order. In practice saves are spaced by LLM latency
  # (seconds) and the context is append-only within a run, so the window is
  # small; if strict last-write-wins ordering is ever required, replace this
  # with a single-flight coalescing writer keyed on session_id.
  defp save_context_async(%{persistence: backend, session_id: session_id, context: context})
       when not is_nil(backend) do
    # Capture only the three fields do_save_context/1 needs — not the whole
    # state (which holds a live %Task{}/atomics we don't want copied into the
    # spawned process).
    snapshot = %{persistence: backend, session_id: session_id, context: context}
    Task.Supervisor.start_child(Nous.TaskSupervisor, fn -> do_save_context(snapshot) end)
    :ok
  end

  defp save_context_async(_state), do: :ok

  # No %{persistence: nil} clause: both callers screen it out first —
  # handle_call(:save_context) replies {:error, :no_persistence} without
  # spawning a task, and save_context_async/1 is a no-op without a backend.

  defp do_save_context(%{persistence: backend, session_id: session_id, context: context}) do
    data = Context.serialize(context)

    case backend.save(session_id, data) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error("Failed to save context for session #{session_id}: #{inspect(reason)}")
        err
    end
  end

  defp maybe_load_context(nil, _session_id), do: :skip

  defp maybe_load_context(backend, session_id) do
    case backend.load(session_id) do
      {:ok, data} ->
        Context.deserialize(data)

      {:error, :not_found} ->
        :skip

      {:error, reason} ->
        Logger.warning(
          "Failed to load persisted context for session #{session_id}: #{inspect(reason)}"
        )

        :skip
    end
  end

  # ── run lifecycle ──────────────────────────────────────────────────────────

  # The one place a run starts. `kind` is `{:prompt, message}` for the
  # interrupting send_message/2 path or `:inbox` for a run the inbox woke, where
  # the input is whatever the claim boundaries hand over.
  defp start_run(state, kind) do
    state = state |> bump_generation() |> reset_inactivity_timer()
    :atomics.put(state.cancelled_ref, 1, 0)

    broadcast(state, {:agent_status, :thinking})

    server_pid = self()
    cancelled_ref = state.cancelled_ref
    generation = state.task_generation

    # The task gets a snapshot of the fields do_agent_run/5 needs. The inbox is
    # deliberately blanked: the queue of record lives here in the server and the
    # task reaches it through the :claim_inbox closure, so a copy in the task
    # could only ever be a stale read of it.
    snapshot = %{state | inbox: Inbox.new(), current_task: nil, draining: %{}}

    task =
      Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
        run_agent_and_respond(server_pid, snapshot, kind, cancelled_ref, generation)
      end)

    %{state | current_task: task, run_state: :running}
  end

  # Non-blocking replacement for the old in-handler `Task.shutdown/2`: the
  # current task is demoted into `draining`, told to shut down with an async
  # exit signal, and given @drain_kill_after ms before a :drain_kill message
  # escalates to an untrappable kill. The {ref, result} and :DOWN clauses
  # above reap the entry, so nothing leaks.
  #
  # Invariant: every caller has ALREADY bumped the generation, so anything a
  # draining task still sends — {:agent_response_ready, ...},
  # {:agent_task_completed, ...} — carries a stale generation and is dropped
  # by the handle_info filters, and its claim_inbox calls return nothing.
  # Demoting without bumping would let a dying run clobber fresh state.
  defp demote_current_task(%{current_task: %Task{} = task} = state) do
    # async_nolink tasks are monitored, never linked, so this exit signal is
    # a plain kill request rather than a link teardown.
    Process.exit(task.pid, :shutdown)
    Process.send_after(self(), {:drain_kill, task.ref}, @drain_kill_after)

    idle(%{state | draining: Map.put(state.draining, task.ref, task)})
  end

  # The `:running -> :idle` transition, with its exit action. Every caller has
  # already established that the finishing task is the CURRENT one (by task ref
  # or by generation), so a stale reply from a superseded run cannot reach here
  # and cannot un-set a run that has since started.
  defp finish_run(state), do: state |> idle() |> maybe_wake()

  defp idle(state), do: %{state | current_task: nil, run_state: :idle}

  defp maybe_wake(%{run_state: :running} = state), do: state

  defp maybe_wake(%{run_state: :idle} = state) do
    if Inbox.wake?(state.inbox), do: start_run(state, :inbox), else: state
  end

  # The seam the runner claims through. Deliberately a plain closure over the
  # server pid rather than a module reference: the iteration loop knows only
  # that `ctx.deps[:claim_inbox]` is a 1-arity function, so nothing in the
  # runner depends on this server existing. A failed claim is treated as
  # "nothing claimed" there, so the timeout is a safety net rather than a
  # correctness boundary. The captured generation lets the server refuse
  # claims from a run it has since demoted (see {:claim_inbox, ...}).
  defp claim_inbox_fun(server_pid, generation) do
    fn target ->
      GenServer.call(server_pid, {:claim_inbox, target, generation}, @claim_timeout)
    end
  end

  # The claim closure is per-run runtime state, not conversation state. Dropping
  # it on the way back in keeps state.context.deps free of closures, so
  # get_context/1 returns something inspectable and load_context's merge_deps
  # cannot carry a dead seam into a restored session.
  defp strip_run_seam(%Context{} = ctx) do
    %{ctx | deps: Map.delete(ctx.deps, :claim_inbox)}
  end

  defp run_agent_and_respond(server_pid, state, kind, cancelled_ref, generation) do
    # Check if cancelled (or already superseded) before starting
    if :atomics.get(cancelled_ref, 1) == 1 or :atomics.get(cancelled_ref, 2) != generation do
      Logger.info("Execution cancelled before agent run for session: #{state.session_id}")
      broadcast(state, {:agent_cancelled, "Execution cancelled"})
      :cancelled
    else
      do_agent_run(server_pid, state, kind, cancelled_ref, generation)
    end
  end

  defp do_agent_run(server_pid, state, kind, cancelled_ref, generation) do
    ctx = %{
      state.context
      | deps: Map.put(state.context.deps, :claim_inbox, claim_inbox_fun(server_pid, generation))
    }

    result = run_agent(state.agent, ctx, kind, server_pid, cancelled_ref, generation)
    report_run(result, server_pid, state, generation)
  end

  defp run_agent(agent, ctx, {:prompt, message}, server_pid, cancelled_ref, generation) do
    Nous.AgentRunner.run(agent, message,
      context: ctx,
      notify_pid: server_pid,
      max_iterations: @max_run_iterations,
      cancellation_check: cancellation_check_fun(cancelled_ref, generation)
    )
  end

  defp run_agent(agent, ctx, :inbox, server_pid, cancelled_ref, generation) do
    # No prompt to append: this run's input arrives through the claim
    # boundaries, so run_with_context/3 — "continue this conversation" — is the
    # right entry.
    #
    # `max_iterations` and `cancellation_check` are set on the struct rather
    # than passed as options because neither reaches a context that already
    # exists: AgentRunner.build_context/3 only reads them when it builds a fresh
    # one, and run_with_context/3 does not read them at all.
    ctx = %{
      ctx
      | max_iterations: @max_run_iterations,
        cancellation_check: cancellation_check_fun(cancelled_ref, generation)
    }

    Nous.AgentRunner.run_with_context(agent, ctx, notify_pid: server_pid)
  end

  # Cancelled when the flag is set OR this task's generation is no longer
  # current. The generation term is what keeps a demoted/draining task
  # cancelled after cancel_execution/clear_history/start_run reset the flag
  # for the run that replaces it — without it, a trap_exit task could keep
  # issuing model requests and side-effecting tool calls for the whole
  # @drain_kill_after grace window.
  defp cancellation_check_fun(cancelled_ref, generation) do
    fn ->
      if :atomics.get(cancelled_ref, 1) == 1 or :atomics.get(cancelled_ref, 2) != generation do
        throw({:cancelled, "Execution cancelled"})
      end
    end
  end

  defp report_run({:ok, response}, server_pid, state, generation) do
    # Broadcast response
    broadcast(state, {:agent_response, response.output})
    broadcast(state, {:agent_complete, response})

    # Send context update to server, tagged with our generation so it
    # can be discarded if the user has already sent a newer message.
    send(server_pid, {:agent_response_ready, generation, response.context, response})
  end

  defp report_run({:error, %Nous.Errors.ExecutionCancelled{}}, server_pid, state, generation) do
    Logger.info("Agent execution was cancelled for session: #{state.session_id}")
    broadcast(state, {:agent_cancelled, "Execution cancelled"})
    send(server_pid, {:agent_task_completed, generation, :cancelled})
  end

  defp report_run({:error, error}, server_pid, state, generation) do
    error_msg = if is_exception(error), do: Exception.message(error), else: inspect(error)
    Logger.error("Agent error in session #{state.session_id}: #{error_msg}")

    # Broadcast error
    broadcast(state, {:agent_error, error_msg})
    send(server_pid, {:agent_task_completed, generation, :error})
  end

  defp broadcast(state, message) do
    Nous.PubSub.broadcast(state.pubsub, state.topic, message)
  end

  defp bump_generation(state) do
    generation = state.task_generation + 1
    # Mirror into the atomics slot so in-flight tasks observe the bump without
    # a server round trip (see cancellation_check_fun/2).
    :atomics.put(state.cancelled_ref, 2, generation)
    %{state | task_generation: generation}
  end
end
