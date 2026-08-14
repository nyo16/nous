defmodule Nous.Agent.Context do
  # MapSet.difference/2 in update_needs_response triggers dialyzer's
  # opaque-tracking false positive (same pattern as Workflow.Engine).
  @dialyzer :no_opaque

  @moduledoc """
  Unified context for agent execution.

  Accumulates state across the agent loop:
  - Conversation messages
  - Tool call history
  - Usage tracking
  - User dependencies
  - Callbacks configuration

  ## Example

      # Create new context
      ctx = Context.new(
        system_prompt: "You are helpful",
        deps: %{database: MyDB},
        max_iterations: 15
      )

      # Add messages
      ctx = ctx
      |> Context.add_message(Message.user("Hello"))
      |> Context.add_message(Message.assistant("Hi there!"))

      # Check loop control
      if ctx.needs_response do
        # Continue execution
      end

  ## Callbacks

  Callbacks can be configured as a map of event handlers:

      ctx = Context.new(callbacks: %{
        on_llm_new_delta: fn _event, delta -> IO.write(delta) end,
        on_tool_call: fn _event, call -> IO.inspect(call) end
      })

  ## Process Notification

  For LiveView integration, set `notify_pid`:

      ctx = Context.new(notify_pid: self())
      # Will receive: {:agent_delta, text}, {:tool_call, call}, etc.

  """

  require Logger

  alias __MODULE__
  alias Nous.{Message, Usage}
  alias Nous.Session.{Event, Log}

  @type callback_fn :: (atom(), any() -> any())

  @type t :: %Context{
          # Conversation — `messages` is a view materialized from `log`
          messages: [Message.t()],
          log: Log.t(),
          tool_calls: [map()],
          system_prompt: String.t() | nil,

          # Assembly-time system-prompt fragment (runtime-only, never
          # serialized, never logged) — see put_system_prompt_overlay/2
          system_prompt_overlay: String.t() | nil,

          # State
          deps: map(),
          usage: Usage.t(),

          # Loop control
          needs_response: boolean(),
          iteration: non_neg_integer(),
          max_iterations: non_neg_integer(),

          # Events
          callbacks: %{optional(atom()) => callback_fn()},
          notify_pid: pid() | nil,

          # Metadata
          started_at: DateTime.t() | nil,
          agent_name: String.t() | nil,

          # Cancellation
          cancellation_check: (-> :ok | {:error, term()}) | nil,

          # Human-in-the-loop
          approval_handler: (map() -> :approve | {:edit, map()} | :reject) | nil,

          # PubSub (runtime-only, never serialized)
          pubsub: module() | nil,
          pubsub_topic: String.t() | nil,

          # Hooks (runtime-only, never serialized)
          hook_registry: Nous.Hook.Registry.t() | nil,

          # Skills (runtime-only, never serialized)
          active_skills: [Nous.Skill.t()],

          # Streaming flag — when true, the LLM call site streams chunks
          # through the new tool-aware path. Runtime-only.
          stream: boolean(),

          # Memoized provider tool-schema conversion (runtime-only, never
          # serialized). `{{provider, tool_name_set}, converted_schemas}` —
          # lets the loop skip re-converting a stable tool set every iteration.
          tool_schema_cache: {{atom(), MapSet.t()}, [map()]} | nil
        }

  defstruct messages: [],
            log: %Log{},
            tool_calls: [],
            system_prompt: nil,
            system_prompt_overlay: nil,
            deps: %{},
            usage: %Usage{},
            needs_response: true,
            iteration: 0,
            max_iterations: 10,
            callbacks: %{},
            notify_pid: nil,
            started_at: nil,
            agent_name: nil,
            cancellation_check: nil,
            approval_handler: nil,
            pubsub: nil,
            pubsub_topic: nil,
            hook_registry: nil,
            active_skills: [],
            stream: false,
            tool_schema_cache: nil

  @doc """
  Create a new context with options.

  ## Options

    * `:messages` - Initial message list (default: [])
    * `:system_prompt` - System prompt string
    * `:deps` - User dependencies map (default: %{})
    * `:max_iterations` - Maximum loop iterations (default: 10)
    * `:callbacks` - Map of callback functions
    * `:notify_pid` - PID to receive event messages
    * `:agent_name` - Name for telemetry/logging
    * `:cancellation_check` - Function to check for cancellation
    * `:approval_handler` - Function called for tools with `requires_approval: true`
    * `:stream` - When true, the runner uses streaming + tool execution (default: false)

  ## Examples

      iex> ctx = Context.new(system_prompt: "Be helpful", max_iterations: 5)
      iex> ctx.max_iterations
      5

      iex> ctx = Context.new(deps: %{user_id: 123})
      iex> ctx.deps.user_id
      123

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    ctx = %Context{
      system_prompt: Keyword.get(opts, :system_prompt),
      deps: Keyword.get(opts, :deps, %{}),
      usage: Keyword.get(opts, :usage, Usage.new()),
      needs_response: Keyword.get(opts, :needs_response, true),
      iteration: Keyword.get(opts, :iteration, 0),
      max_iterations: Keyword.get(opts, :max_iterations, 10),
      callbacks: Keyword.get(opts, :callbacks, %{}),
      notify_pid: Keyword.get(opts, :notify_pid),
      started_at: DateTime.utc_now(),
      agent_name: Keyword.get(opts, :agent_name),
      cancellation_check: Keyword.get(opts, :cancellation_check),
      approval_handler: Keyword.get(opts, :approval_handler),
      pubsub: Keyword.get(opts, :pubsub) || Nous.PubSub.configured_pubsub(),
      pubsub_topic: Keyword.get(opts, :pubsub_topic),
      stream: Keyword.get(opts, :stream, false)
    }

    # The log is the source of truth from the first message: seeding it and
    # materializing means a context built with `:messages` folds back to exactly
    # those messages, `Nous.run(agent, messages: [...])` included.
    put_log(ctx, Log.seed(Keyword.get(opts, :messages, [])))
  end

  @doc """
  Add a message to the context.

  Appends one surface event to the log and re-materializes `messages` from the
  fold, so the two stay in lockstep. Automatically updates `needs_response`
  based on message role and content.

  ## Options

    * `:source` — marks injected context (`:memory`, `:knowledge_base`) in the
      event's data, so a later reader can tell injected context from
      conversation. It does not appear in the projected message.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Context.add_message(ctx, Message.user("Hello"))
      iex> length(ctx.messages)
      1

  """
  @spec add_message(t(), Message.t(), keyword()) :: t()
  def add_message(%Context{} = ctx, %Message{} = message, opts \\ []) do
    ctx = sync(ctx)

    ctx
    |> put_log(log_message(ctx.log, message, opts))
    |> update_needs_response(message)
  end

  @doc """
  Add multiple messages to the context.

  One event per message, materialized once at the end rather than once per
  message.

  ## Examples

      iex> ctx = Context.new()
      iex> messages = [Message.user("Hi"), Message.assistant("Hello")]
      iex> ctx = Context.add_messages(ctx, messages)
      iex> length(ctx.messages)
      2

  """
  @spec add_messages(t(), [Message.t()]) :: t()
  def add_messages(%Context{} = ctx, messages) when is_list(messages) do
    ctx = sync(ctx)
    log = Enum.reduce(messages, ctx.log, &log_message(&2, &1, []))

    # `needs_response` is folded over just the new messages — identical to the
    # per-item reduce, since it depends only on each message's role.
    Enum.reduce(messages, put_log(ctx, log), fn msg, acc ->
      update_needs_response(acc, msg)
    end)
  end

  @doc """
  Replace the message at `index` with `message`, in place.

  Appends a `{:replace, seq, seq}` event instead of rewriting the list, so the
  original stays in the log. This is how compaction prunes an oversized tool
  result without destroying what it pruned.

  An `index` outside the transcript is a no-op with a warning: a caller working
  from a stale view must not silently rewrite the wrong message.
  """
  @spec replace_message(t(), non_neg_integer(), Message.t()) :: t()
  def replace_message(%Context{} = ctx, index, %Message{} = message)
      when is_integer(index) and index >= 0 do
    replace_message_range(ctx, index, index, message)
  end

  @doc """
  Replace the inclusive message range `first..last` with a single `message`.

  Non-destructive compaction: the replacement takes the *position* of the range
  it shadows, so a summary lands where the conversation it summarizes was, and
  `Nous.Session.Log.events/1` still returns every shadowed event.

  The replacement inherits the `created_at` of the first message it shadows — it
  stands in for that range, and the transcript's timestamps stay non-decreasing.

  Every message whose position falls inside the range is shadowed, including one
  the caller did not enumerate (an injected system message sitting between two
  conversation turns, say). That is deliberate: the range is a position range,
  and a hole in it would reorder the transcript.
  """
  @spec replace_message_range(t(), non_neg_integer(), non_neg_integer(), Message.t()) :: t()
  def replace_message_range(%Context{} = ctx, first, last, %Message{} = message)
      when is_integer(first) and is_integer(last) and first >= 0 and last >= first do
    ctx = sync(ctx)
    indexed = Log.derive_indexed(ctx.log)
    offset = view_offset(ctx, indexed)

    with {:ok, {first_seq, first_message}} <- fetch_pair(indexed, first - offset),
         {:ok, {last_seq, _}} <- fetch_pair(indexed, last - offset) do
      positions = surface_positions(ctx.log)

      op = {:replace, Map.fetch!(positions, first_seq), Map.fetch!(positions, last_seq)}
      opts = [surface_op: op, time: first_message.created_at]

      put_log(ctx, log_message(ctx.log, message, opts))
    else
      :error ->
        Logger.warning(
          "Nous.Agent.Context.replace_message_range/4: #{first}..#{last} is outside the " <>
            "#{length(indexed)}-message transcript; leaving it unchanged"
        )

        ctx
    end
  end

  @doc """
  Set the assembly-time system-prompt fragment, or clear it with `nil`.

  The fragment is appended to the transcript's leading system message (or
  becomes one, if there is none) every time `messages` is materialized. It is
  **not** an event, deliberately: it is derived from agent config, plugins and
  skills, and re-derived on every run, so logging it would append a copy of the
  same text to a durable log per run. See `Nous.AgentRunner.PromptAssembly`.

  Because it is applied *during* materialization rather than written over
  `messages`, the view still equals the fold plus this one pure, idempotent
  overlay — setting it twice replaces it instead of compounding.
  """
  @spec put_system_prompt_overlay(t(), String.t() | nil) :: t()
  def put_system_prompt_overlay(%Context{} = ctx, overlay)
      when is_binary(overlay) or is_nil(overlay) do
    ctx = sync(ctx)
    put_log(%{ctx | system_prompt_overlay: overlay}, ctx.log)
  end

  @doc """
  Record a tool call in the context.

  ## Examples

      iex> ctx = Context.new()
      iex> call = %{id: "call_123", name: "search", arguments: %{"q" => "test"}}
      iex> ctx = Context.add_tool_call(ctx, call)
      iex> length(ctx.tool_calls)
      1

  """
  @spec add_tool_call(t(), map()) :: t()
  def add_tool_call(%Context{} = ctx, call) when is_map(call) do
    %{ctx | tool_calls: ctx.tool_calls ++ [call]}
  end

  @doc """
  Merge usage statistics into the context.

  ## Examples

      iex> ctx = Context.new()
      iex> usage = %Usage{input_tokens: 100, output_tokens: 50}
      iex> ctx = Context.add_usage(ctx, usage)
      iex> ctx.usage.input_tokens
      100

  """
  @spec add_usage(t(), Usage.t() | map()) :: t()
  def add_usage(%Context{} = ctx, %Usage{} = usage) do
    new_usage = Usage.add(ctx.usage, usage)
    %{ctx | usage: new_usage}
  end

  def add_usage(%Context{} = ctx, usage) when is_map(usage) do
    # Convert map to Usage struct, handling partial updates
    usage_struct = %Usage{
      requests: Map.get(usage, :requests, 0),
      tool_calls: Map.get(usage, :tool_calls, 0),
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      total_tokens: Map.get(usage, :total_tokens, 0),
      cache_creation_input_tokens: Map.get(usage, :cache_creation_input_tokens, 0),
      cache_read_input_tokens: Map.get(usage, :cache_read_input_tokens, 0)
    }

    new_usage = Usage.add(ctx.usage, usage_struct)
    %{ctx | usage: new_usage}
  end

  @doc """
  Merge new dependencies into the context.

  Used by tools to update context state via `__update_context__` or `ContextUpdate`.

  ## Examples

      iex> ctx = Context.new(deps: %{count: 0})
      iex> ctx = Context.merge_deps(ctx, %{count: 1, new_key: "value"})
      iex> ctx.deps.count
      1
      iex> ctx.deps.new_key
      "value"

  """
  @spec merge_deps(t(), map()) :: t()
  def merge_deps(%Context{} = ctx, new_deps) when is_map(new_deps) do
    merged = Map.merge(ctx.deps || %{}, new_deps)
    %{ctx | deps: merged}
  end

  @doc """
  Increment the iteration counter.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Context.increment_iteration(ctx)
      iex> ctx.iteration
      1

  """
  @spec increment_iteration(t()) :: t()
  def increment_iteration(%Context{} = ctx) do
    %{ctx | iteration: ctx.iteration + 1}
  end

  @doc """
  Set needs_response flag explicitly.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Context.set_needs_response(ctx, false)
      iex> ctx.needs_response
      false

  """
  @spec set_needs_response(t(), boolean()) :: t()
  def set_needs_response(%Context{} = ctx, value) when is_boolean(value) do
    %{ctx | needs_response: value}
  end

  @doc """
  Check if maximum iterations has been reached.

  ## Examples

      iex> ctx = Context.new(max_iterations: 5, iteration: 5)
      iex> Context.max_iterations_reached?(ctx)
      true

      iex> ctx = Context.new(max_iterations: 5, iteration: 3)
      iex> Context.max_iterations_reached?(ctx)
      false

  """
  @spec max_iterations_reached?(t()) :: boolean()
  def max_iterations_reached?(%Context{iteration: i, max_iterations: max}) do
    i >= max
  end

  @doc """
  Get the last message from the context.

  ## Examples

      iex> ctx = Context.new() |> Context.add_message(Message.user("Hello"))
      iex> Context.last_message(ctx).content
      "Hello"

      iex> ctx = Context.new()
      iex> Context.last_message(ctx)
      nil

  """
  @spec last_message(t()) :: Message.t() | nil
  def last_message(%Context{messages: []}), do: nil
  def last_message(%Context{messages: messages}), do: List.last(messages)

  @doc """
  Get all assistant messages from the context.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = ctx |> Context.add_message(Message.user("Hi"))
      iex> ctx = ctx |> Context.add_message(Message.assistant("Hello"))
      iex> length(Context.assistant_messages(ctx))
      1

  """
  @spec assistant_messages(t()) :: [Message.t()]
  def assistant_messages(%Context{messages: messages}) do
    Enum.filter(messages, &(&1.role == :assistant))
  end

  @doc """
  Convert to RunContext for tool execution (backwards compatibility).

  This allows tools to continue using the existing RunContext interface.

  ## Options

    * `:sandbox` - `Nous.Sandbox.Policy` to carry onto the run context as the
      session-level sandbox override. The agent runner passes `agent.sandbox`
      here; `nil` leaves resolution to application config.

  ## Examples

      iex> ctx = Context.new(deps: %{db: :postgres})
      iex> run_ctx = Context.to_run_context(ctx)
      iex> run_ctx.deps.db
      :postgres

      iex> ctx = Context.new(deps: %{})
      iex> run_ctx = Context.to_run_context(ctx, sandbox: Nous.Sandbox.Policy.new(:read_only))
      iex> run_ctx.sandbox.mode
      :read_only

  """
  @spec to_run_context(t(), keyword()) :: Nous.RunContext.t()
  def to_run_context(%Context{} = ctx, opts \\ []) do
    # `approval_gated?: true`: the runner has already run the full approval +
    # permission-policy pipeline (AgentRunner.ToolExecution.check_tool_approval/3)
    # for this call, so ToolExecutor must not prompt the operator a second time.
    # The handler is still carried through so tools can see it.
    Nous.RunContext.new(ctx.deps,
      usage: ctx.usage,
      approval_handler: ctx.approval_handler,
      approval_gated?: true,
      sandbox: Keyword.get(opts, :sandbox)
    )
  end

  @doc """
  Create context from an existing RunContext (migration helper).

  ## Examples

      iex> run_ctx = Nous.RunContext.new(%{key: "value"})
      iex> ctx = Context.from_run_context(run_ctx)
      iex> ctx.deps.key
      "value"

  """
  @spec from_run_context(Nous.RunContext.t(), keyword()) :: t()
  def from_run_context(%Nous.RunContext{} = run_ctx, opts \\ []) do
    new(
      Keyword.merge(opts,
        deps: run_ctx.deps,
        usage: run_ctx.usage
      )
    )
  end

  @doc """
  Patch dangling tool calls in the conversation.

  Scans messages for assistant messages with tool_calls that have no
  corresponding tool result message. Injects synthetic tool results
  for unmatched calls with a message indicating the call was interrupted.

  This is critical when resuming from a persisted context where the
  session was interrupted mid-tool-execution.

  ## Examples

      iex> ctx = Context.new(messages: [
      ...>   Message.assistant("Let me search", tool_calls: [%{id: "call_1", name: "search"}])
      ...> ])
      iex> ctx = Context.patch_dangling_tool_calls(ctx)
      iex> length(ctx.messages)
      2

  """
  @spec patch_dangling_tool_calls(t()) :: t()
  def patch_dangling_tool_calls(%Context{messages: messages} = ctx) do
    # Build id -> name map from assistant tool_calls (name needed so providers
    # like Gemini can populate functionResponse.name correctly).
    tool_call_names =
      messages
      |> Enum.filter(&(&1.role == :assistant))
      |> Enum.flat_map(fn msg ->
        (msg.tool_calls || [])
        |> Enum.map(fn call ->
          {Map.get(call, :id) || Map.get(call, "id"),
           Map.get(call, :name) || Map.get(call, "name")}
        end)
        |> Enum.reject(fn {id, _} -> is_nil(id) end)
      end)
      |> Map.new()

    tool_result_ids =
      messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(& &1.tool_call_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    dangling_ids = MapSet.difference(MapSet.new(Map.keys(tool_call_names)), tool_result_ids)

    if MapSet.size(dangling_ids) == 0 do
      ctx
    else
      synthetic_results =
        Enum.map(dangling_ids, fn id ->
          Message.tool(
            id,
            "Tool call was interrupted and not executed. Please retry if needed.",
            name: Map.get(tool_call_names, id)
          )
        end)

      ctx = sync(ctx)

      # Synthetic results are appended as events like any other tool result.
      # `needs_response` is deliberately untouched, as it was before the log.
      put_log(ctx, Enum.reduce(synthetic_results, ctx.log, &log_message(&2, &1, [])))
    end
  end

  # Serialization

  @doc """
  Serialize context to a JSON-encodable map.

  Version 2 persists the **event log**. `messages` is still emitted, because it
  is what a v1 reader (or a human) consumes, but it is a projection of the
  events, not the source of truth.

  Persists messages, usage, metadata. Never persists functions, PIDs, or
  modules. The assembled system-prompt overlay is runtime state and is not
  persisted either; it is re-derived on the next run.

  ## Examples

      iex> ctx = Context.new(system_prompt: "Be helpful", max_iterations: 5)
      iex> data = Context.serialize(ctx)
      iex> data.version
      2
      iex> data.system_prompt
      "Be helpful"

  """
  @spec serialize(t()) :: map()
  def serialize(%Context{} = ctx) do
    %{
      version: 2,
      events: Enum.map(Log.events(ctx.log), &serialize_event/1),
      messages: Enum.map(ctx.messages, &serialize_message/1),
      tool_calls: ctx.tool_calls,
      system_prompt: ctx.system_prompt,
      deps: serialize_deps(ctx.deps),
      usage: serialize_usage(ctx.usage),
      needs_response: ctx.needs_response,
      iteration: ctx.iteration,
      max_iterations: ctx.max_iterations,
      started_at: ctx.started_at && DateTime.to_iso8601(ctx.started_at),
      agent_name: ctx.agent_name
    }
  end

  @doc """
  Deserialize a map back into a Context struct.

  Reads both versions, which is what makes v1 → v2 a migration rather than a
  break: a v2 blob rebuilds the log from its events, and a v1 blob seeds one
  from its flat message list. Functions, PIDs, and callbacks are not restored
  and will use defaults.

  A v1 blob folds back to its original messages, but every message is stamped
  with the restore time: v1 never persisted `created_at`, so the original
  timestamps are not in the blob to recover.

  Returns `{:ok, context}` or `{:error, reason}`.

  ## Examples

      iex> ctx = Context.new(system_prompt: "Be helpful")
      iex> data = Context.serialize(ctx)
      iex> {:ok, restored} = Context.deserialize(data)
      iex> restored.system_prompt
      "Be helpful"

  """
  @spec deserialize(map()) :: {:ok, t()} | {:error, term()}
  def deserialize(%{version: 2} = data) do
    do_deserialize(data, :v2)
  end

  def deserialize(%{"version" => 2} = data) do
    data
    |> atomize_keys()
    |> do_deserialize(:v2)
  end

  def deserialize(%{version: 1} = data) do
    do_deserialize(data, :v1)
  end

  def deserialize(%{"version" => 1} = data) do
    data
    |> atomize_keys()
    |> do_deserialize(:v1)
  end

  def deserialize(%{version: v}) when is_integer(v) do
    {:error, "unsupported version: #{v}"}
  end

  def deserialize(%{"version" => v}) when is_integer(v) do
    {:error, "unsupported version: #{v}"}
  end

  def deserialize(_data) do
    {:error, "missing or invalid version field"}
  end

  # Private functions

  defp do_deserialize(data, version) do
    usage = deserialize_usage(data[:usage] || %{})

    started_at =
      case data[:started_at] do
        nil ->
          nil

        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _offset} -> dt
            _ -> nil
          end
      end

    ctx = %Context{
      tool_calls: data[:tool_calls] || [],
      system_prompt: data[:system_prompt],
      deps: data[:deps] || %{},
      usage: usage,
      needs_response: data[:needs_response] || false,
      iteration: data[:iteration] || 0,
      max_iterations: data[:max_iterations] || 10,
      started_at: started_at,
      agent_name: data[:agent_name],
      callbacks: %{},
      notify_pid: nil,
      cancellation_check: nil,
      approval_handler: nil,
      pubsub: nil,
      pubsub_topic: nil
    }

    {:ok, put_log(ctx, restore_log(version, data))}
  rescue
    # Deserializes attacker-controllable persisted blobs; a malformed blob
    # can raise from anywhere in the decode path, so the catch-all is a
    # deliberate boundary honoring the {:ok, _} | {:error, _} contract.
    e -> {:error, Exception.message(e)}
  end

  # v1 has no events: seed the log from the flat message list, exactly as
  # `Nous.run(agent, messages: [...])` does.
  defp restore_log(:v1, data), do: data |> persisted_messages() |> Log.seed()

  defp restore_log(:v2, data) do
    case data[:events] do
      events when is_list(events) ->
        rebuild_log(events)

      other ->
        Logger.warning(
          "Nous.Agent.Context: v2 blob carries #{inspect(other)} for :events; " <>
            "falling back to seeding from :messages, which loses shadowed history"
        )

        data |> persisted_messages() |> Log.seed()
    end
  end

  defp persisted_messages(data) do
    (data[:messages] || []) |> Enum.map(&deserialize_message/1)
  end

  defp rebuild_log(events) do
    Enum.reduce(events, Log.new(), fn raw, log ->
      raw = atomize_keys(raw)

      case deserialize_event_type(raw[:type]) do
        {:ok, type} ->
          warn_seq_shift(log, raw[:seq])
          append_event(log, type, deserialize_event_data(raw[:data]), event_time(raw[:time]))

        :error ->
          Logger.warning(
            "Nous.Agent.Context: dropping an event of unknown type #{inspect(raw[:type])} " <>
              "from persisted data; any later {:replace, _, _} range may no longer line up"
          )

          log
      end
    end)
  end

  # `seq` is assigned by the log and equals the event's index, so a persisted seq
  # that does not match the next one is the signal that an earlier event was
  # dropped — which silently shifts every replace range after it.
  defp warn_seq_shift(log, seq) when is_integer(seq) do
    if seq != Log.count(log) do
      Logger.warning(
        "Nous.Agent.Context: persisted event seq #{seq} does not match the rebuilt " <>
          "seq #{Log.count(log)}; the log lost an event and replace ranges may be off"
      )
    end
  end

  defp warn_seq_shift(_log, _seq), do: :ok

  defp serialize_message(%Message{} = msg) do
    %{
      role: msg.role,
      content: msg.content,
      tool_calls: msg.tool_calls,
      tool_call_id: msg.tool_call_id,
      name: msg.name,
      metadata: msg.metadata
    }
  end

  # Known message fields - any other key in the persisted map is logged as
  # a warning so a forward-compatibility issue (a future Message field that
  # the current code doesn't know about, OR a typo in a persisted blob)
  # surfaces loudly rather than silently dropping data.
  @known_message_keys ~w(role content tool_calls tool_call_id name metadata)

  defp deserialize_message(data) when is_map(data) do
    warn_unknown_keys(data, @known_message_keys, "Nous.Message")
    data = atomize_keys(data)

    role =
      case data[:role] do
        r when r in [:system, :user, :assistant, :tool] ->
          r

        "system" ->
          :system

        "user" ->
          :user

        "assistant" ->
          :assistant

        "tool" ->
          :tool

        other ->
          Logger.warning(
            "Unknown message role during deserialization: #{inspect(other)}, defaulting to :user"
          )

          :user
      end

    attrs = %{
      role: role,
      content: data[:content],
      tool_calls: data[:tool_calls] || [],
      tool_call_id: data[:tool_call_id],
      name: data[:name],
      metadata: data[:metadata] || %{}
    }

    Message.new!(attrs)
  end

  # An event's `data` has to stay JSON-encodable, which rules out the
  # `{:replace, start, stop}` tuple — a list survives both a JSON round trip and
  # the ETS backend's raw terms. Nothing else in an event's data is a tuple.
  defp serialize_event(%Event{} = event) do
    %{
      seq: event.seq,
      type: Atom.to_string(event.type),
      time: DateTime.to_iso8601(event.time),
      data: serialize_event_data(event.data)
    }
  end

  defp serialize_event_data(data) when is_map(data) do
    case Map.get(data, :surface_op) do
      {:replace, start, stop} -> Map.put(data, :surface_op, ["replace", start, stop])
      _append_or_absent -> data
    end
  end

  # NEVER String.to_atom/1 on a persisted blob. The type has to be one the code
  # already knows or the event is unreadable, which is a much better outcome than
  # growing the atom table from an attacker-controllable string.
  defp deserialize_event_type(type) when is_atom(type) and not is_nil(type) do
    if type in Event.types(), do: {:ok, type}, else: :error
  end

  defp deserialize_event_type(type) when is_binary(type) do
    case Enum.find(Event.types(), &(Atom.to_string(&1) == type)) do
      nil -> :error
      known -> {:ok, known}
    end
  end

  defp deserialize_event_type(_type), do: :error

  @known_event_data_keys ~w(
    content name metadata tool_calls tool_call_id reasoning_content source surface_op
  )

  defp deserialize_event_data(data) when is_map(data) do
    warn_unknown_keys(data, @known_event_data_keys, "Nous.Session.Event")

    data
    |> atomize_keys()
    |> restore_surface_op()
    |> restore_source()
  end

  defp deserialize_event_data(_data), do: %{}

  defp restore_surface_op(%{surface_op: op} = data) do
    case op do
      ["replace", start, stop] when is_integer(start) and is_integer(stop) ->
        Map.put(data, :surface_op, {:replace, start, stop})

      {:replace, start, stop} when is_integer(start) and is_integer(stop) ->
        data

      append when append in [:append, "append"] ->
        Map.put(data, :surface_op, :append)

      other ->
        Logger.warning(
          "Nous.Agent.Context: unreadable surface_op #{inspect(other)} in persisted event " <>
            "data; treating the event as a plain append, so a compacted range reappears"
        )

        Map.delete(data, :surface_op)
    end
  end

  defp restore_surface_op(data), do: data

  # The injection markers the plugins write. `source` is provenance, never
  # something the code dispatches on, so an unrecognised one stays a binary
  # rather than becoming a new atom.
  @known_sources [:memory, :knowledge_base]

  defp restore_source(%{source: source} = data) when is_binary(source) do
    case Enum.find(@known_sources, &(Atom.to_string(&1) == source)) do
      nil -> data
      known -> Map.put(data, :source, known)
    end
  end

  defp restore_source(data), do: data

  defp event_time(%DateTime{} = time), do: time

  defp event_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        Logger.warning(
          "Nous.Agent.Context: unreadable event time #{inspect(iso)}; stamping the restore time"
        )

        DateTime.utc_now()
    end
  end

  defp event_time(_other), do: DateTime.utc_now()

  defp warn_unknown_keys(map, known_string_keys, module_label) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.each(fn key ->
      str = if is_atom(key), do: Atom.to_string(key), else: to_string(key)

      unless str in known_string_keys do
        Logger.debug(
          "#{module_label} deserialize: ignoring unknown key #{inspect(key)} from persisted data"
        )
      end
    end)
  end

  # Every %Usage{} counter is persisted. Dropping a field here silently zeroes it
  # across a save/restore, which is how the 0.16.2 prompt-cache counters would
  # quietly break the cost math documented in docs/guides/observability.md.
  defp serialize_usage(%Usage{} = usage) do
    %{
      requests: usage.requests,
      tool_calls: usage.tool_calls,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      cache_creation_input_tokens: usage.cache_creation_input_tokens,
      cache_read_input_tokens: usage.cache_read_input_tokens
    }
  end

  # Credential-shaped dep keys that must never be written to the persistence
  # backend. Persistence auto-saves the context after every response, and the
  # ETS backend table is :public, so a plain-string api_key in deps would leak.
  @sensitive_dep_key_substrings ~w(
    api_key apikey token secret password passwd authorization
    credential private_key access_key auth_token bearer
  )

  defp serialize_deps(deps) when is_map(deps) do
    deps
    |> Enum.reject(fn {k, v} ->
      is_function(v) or is_pid(v) or is_port(v) or sensitive_dep_key?(k)
    end)
    |> Map.new()
  end

  defp serialize_deps(_), do: %{}

  defp sensitive_dep_key?(key) do
    name = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_dep_key_substrings, &String.contains?(name, &1))
  end

  defp deserialize_usage(data) when is_map(data) do
    data = atomize_keys(data)

    %Usage{
      requests: data[:requests] || 0,
      tool_calls: data[:tool_calls] || 0,
      input_tokens: data[:input_tokens] || 0,
      output_tokens: data[:output_tokens] || 0,
      total_tokens: data[:total_tokens] || 0,
      cache_creation_input_tokens: data[:cache_creation_input_tokens] || 0,
      cache_read_input_tokens: data[:cache_read_input_tokens] || 0
    }
  end

  # Keys read from persisted state are attacker-controllable; Nous.Util only
  # resolves already-existing atoms, and unknown keys stay as binaries that
  # downstream Ecto.cast simply ignores.
  defp atomize_keys(map) when is_map(map), do: Nous.Util.atomize_keys(map)

  # --- the materialized view -------------------------------------------------
  #
  # `messages` is a view over the log: after every append it is re-derived from
  # the fold and the cache-warmed log is stored back, so the log is the source of
  # truth and `messages` is kept in lockstep. Every existing `ctx.messages`
  # reader keeps working untouched, which is plan constraint D2.

  defp put_log(%Context{} = ctx, %Log{} = log) do
    {messages, log} = Log.materialize(log)
    %{ctx | messages: apply_overlay(messages, ctx.system_prompt_overlay), log: log}
  end

  defp view(%Context{} = ctx) do
    apply_overlay(Log.derive_messages(ctx.log), ctx.system_prompt_overlay)
  end

  # The assembled system prompt is assembly-time state, not history: see
  # `put_system_prompt_overlay/2`. Applying it here, on every materialization, is
  # what keeps `messages` and the fold from disagreeing without writing derived
  # text to a durable log.
  defp apply_overlay(messages, nil), do: messages

  defp apply_overlay([%Message{role: :system} = sys | rest], overlay) do
    [%{sys | content: (sys.content || "") <> "\n\n" <> overlay} | rest]
  end

  defp apply_overlay(messages, overlay) do
    # No leading system message to extend, so the overlay becomes one. It is
    # stamped with the head message's time rather than the clock, so the
    # transcript's `created_at` stays non-decreasing and the view stays a pure
    # function of the log.
    created_at =
      case messages do
        [%Message{created_at: %DateTime{} = at} | _] -> at
        _ -> DateTime.utc_now()
      end

    [%{Message.system(overlay) | created_at: created_at} | messages]
  end

  # A caller that wrote `%{ctx | messages: ...}` directly — test fixtures, and
  # user code written before the log existed — left the view and the log out of
  # step. Re-seed from what the caller put there instead of silently resurrecting
  # the fold on the next append. `view/1` hands back the very terms the fold
  # cached, so the in-sync case is a pointer comparison per message.
  defp sync(%Context{} = ctx) do
    if view(ctx) == ctx.messages do
      ctx
    else
      # Whatever the caller assembled is the transcript now, overlay included;
      # keeping the overlay would apply it a second time.
      put_log(%{ctx | system_prompt_overlay: nil}, Log.seed(ctx.messages))
    end
  end

  # One place decides how a `%Message{}` becomes an event, so adding, bulk
  # adding, patching and compaction cannot drift apart.
  defp log_message(%Log{} = log, %Message{} = message, opts) do
    case event_data(message, opts) do
      {type, data} ->
        # The event's time IS the message's `created_at`: the fold stamps from
        # it, so re-stamping would make `add_message/3` lossy. A replacement
        # instead inherits the time of the range it stands in for.
        time = Keyword.get(opts, :time) || message.created_at
        append_event(log, type, data, time)

      :skip ->
        Logger.warning(
          "Nous.Agent.Context: dropping a message with unsupported role " <>
            "#{inspect(message.role)}"
        )

        log
    end
  end

  defp append_event(%Log{} = log, type, data, time) do
    case Log.append(log, type, data, time) do
      {:ok, log} ->
        log

      {:error, reason} ->
        # `metadata` is the only free-form field on a message; everything else is
        # a string or a provider-normalized map. Retry without it rather than
        # lose the message, and say so loudly — a pid, ref, port or function in
        # metadata cannot survive persistence, which is why the event layer
        # rejects it at append time instead of hours later at save time.
        Logger.error(
          "Nous.Agent.Context: #{inspect(type)} event rejected (#{inspect(reason)}); " <>
            "retrying without :metadata"
        )

        retry_without_metadata(log, type, data, time)
    end
  end

  defp retry_without_metadata(log, type, data, time) do
    case Log.append(log, type, Map.put(data, :metadata, %{}), time) do
      {:ok, log} ->
        log

      {:error, reason} ->
        Logger.error(
          "Nous.Agent.Context: #{inspect(type)} event still rejected with no metadata " <>
            "(#{inspect(reason)}); the message is dropped and this transcript is incomplete"
        )

        log
    end
  end

  defp event_data(%Message{role: :system} = msg, opts),
    do: {:system_message, base_data(msg, opts)}

  defp event_data(%Message{role: :user} = msg, opts),
    do: {:user_message, base_data(msg, opts)}

  defp event_data(%Message{role: :assistant} = msg, opts) do
    data =
      msg
      |> base_data(opts)
      |> Map.put(:tool_calls, msg.tool_calls || [])
      |> Map.put(:reasoning_content, msg.reasoning_content)

    {:assistant_message, data}
  end

  defp event_data(%Message{role: :tool} = msg, opts) do
    {:tool_result, msg |> base_data(opts) |> Map.put(:tool_call_id, msg.tool_call_id)}
  end

  defp event_data(%Message{}, _opts), do: :skip

  defp base_data(%Message{} = msg, opts) do
    %{content: msg.content, name: msg.name, metadata: msg.metadata || %{}}
    |> put_unless_nil(:source, Keyword.get(opts, :source))
    |> put_unless_nil(:surface_op, Keyword.get(opts, :surface_op))
  end

  defp put_unless_nil(data, _key, nil), do: data
  defp put_unless_nil(data, key, value), do: Map.put(data, key, value)

  # The coordinate a `{:replace, start, stop}` names is the surface *position*,
  # not the raw seq. A replace takes the position of what it replaced, so an
  # event that pruned a tool result in place carries a high seq and a low
  # position; naming seqs here would leave it unshadowed inside a later summary.
  defp surface_positions(%Log{} = log) do
    Map.new(Log.surface(log), fn event ->
      case Event.surface_op(event) do
        {:replace, start, _stop} -> {event.seq, start}
        :append -> {event.seq, event.seq}
      end
    end)
  end

  # The overlay can inject a system message with no event behind it, which makes
  # the view one longer than the fold.
  defp view_offset(%Context{} = ctx, indexed), do: length(ctx.messages) - length(indexed)

  defp fetch_pair(_indexed, index) when index < 0, do: :error

  defp fetch_pair(indexed, index) do
    case Enum.at(indexed, index) do
      nil -> :error
      pair -> {:ok, pair}
    end
  end

  defp update_needs_response(ctx, %Message{role: :assistant} = message) do
    # Assistant messages with tool calls need a response (tool results)
    # Assistant messages without tool calls don't need a response (final answer)
    has_tool_calls = Message.has_tool_calls?(message)
    %{ctx | needs_response: has_tool_calls}
  end

  defp update_needs_response(ctx, %Message{role: :tool}) do
    # Tool result messages always need a response from the model
    %{ctx | needs_response: true}
  end

  defp update_needs_response(ctx, %Message{role: :user}) do
    # User messages always need a response
    %{ctx | needs_response: true}
  end

  defp update_needs_response(ctx, _message) do
    # System messages don't change needs_response
    ctx
  end
end
