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

  @type callback_fn :: (atom(), any() -> any())

  @type t :: %Context{
          # Conversation
          messages: [Message.t()],
          tool_calls: [map()],
          system_prompt: String.t() | nil,

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
            tool_calls: [],
            system_prompt: nil,
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
    %Context{
      messages: Keyword.get(opts, :messages, []),
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
  end

  @doc """
  Add a message to the context.

  Automatically updates `needs_response` based on message role and content.

  ## Examples

      iex> ctx = Context.new()
      iex> ctx = Context.add_message(ctx, Message.user("Hello"))
      iex> length(ctx.messages)
      1

  """
  @spec add_message(t(), Message.t()) :: t()
  # NOTE: `messages` is appended-to (`++ [message]`), which is O(n) per call —
  # acceptable for single appends, but use `add_messages/2` for bulk inserts;
  # it concatenates once instead of re-walking the list per message.
  def add_message(%Context{} = ctx, %Message{} = message) do
    updated_messages = ctx.messages ++ [message]

    %{ctx | messages: updated_messages}
    |> update_needs_response(message)
  end

  @doc """
  Add multiple messages to the context.

  ## Examples

      iex> ctx = Context.new()
      iex> messages = [Message.user("Hi"), Message.assistant("Hello")]
      iex> ctx = Context.add_messages(ctx, messages)
      iex> length(ctx.messages)
      2

  """
  @spec add_messages(t(), [Message.t()]) :: t()
  def add_messages(%Context{} = ctx, messages) when is_list(messages) do
    # Concatenate the whole batch ONCE (O(n+m)) instead of `++ [msg]` per
    # message (O(n*m)). `needs_response` is then folded over just the new
    # messages — identical result to the old per-item reduce, since
    # update_needs_response depends only on each message's role.
    ctx = %{ctx | messages: ctx.messages ++ messages}
    Enum.reduce(messages, ctx, fn msg, acc -> update_needs_response(acc, msg) end)
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
      total_tokens: Map.get(usage, :total_tokens, 0)
    }

    new_usage = Usage.add(ctx.usage, usage_struct)
    %{ctx | usage: new_usage}
  end

  @doc """
  Merge new dependencies into the context.

  This is the **trusted** merge: every key in `new_deps` wins. Operator-supplied
  deps go through here, including `Nous.AgentServer` re-applying its configured
  deps over a restored session. For deps a *tool* asked to change, use
  `merge_tool_deps/2`.

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

  # Deps keys a tool-supplied context update may not rewrite. Kept adjacent to
  # the reasoning in protected_deps_keys/0's @doc.
  @protected_deps_keys [
    :approval_handler,
    :hook_registry,
    :workspace_root,
    :sub_agent_shared_deps,
    :sub_agent_templates,
    :sub_agent_workspace_root,
    :file_read_max_bytes,
    :web_fetch_max_bytes
  ]

  @doc """
  Deps keys that a tool-supplied context update may not touch.

  These carry security meaning. `:workspace_root` is the sandbox
  `Nous.Tools.PathGuard` confines every file tool to — dropping it widens the
  sandbox to the whole cwd. `:sub_agent_shared_deps` decides which parent deps
  (API keys, connections) cross into a sub-agent, `:sub_agent_templates` which
  agent configurations — hence which tool sets — a tool may spawn, and
  `:sub_agent_workspace_root` requests a narrower root for a child agent.
  `:file_read_max_bytes` and `:web_fetch_max_bytes` are resource ceilings a tool
  must not be able to RAISE: both are read from `deps` ahead of application
  config, and `Nous.Tools.WebFetch`'s promise that a model-supplied `max_bytes`
  "may only lower the ceiling" is worthless if the ceiling itself is writable.
  `:approval_handler` and `:hook_registry` are listed for completeness: they
  live on the struct rather than in `deps`, so no deps update reaches them
  today, and the list is where a future move into `deps` gets caught.

  Adding a deps key that `Nous.Tools.PathGuard`, `Nous.Plugins.SubAgent`, or any
  other guard trusts means adding it here in the same change. The denylist does
  not cover a new key by default, and an unlisted one is silently rewritable by
  any tool.

  A denylist, not an allowlist: `deps` is an open namespace owned by the
  application (todos, counters, `:kb_config`, `:memory_config`, …) and skill
  activation writes `:skill_registry` through `Nous.Tool.ContextUpdate` by
  design, so an allowlist could only ever be incomplete.
  """
  @spec protected_deps_keys() :: [atom()]
  def protected_deps_keys, do: @protected_deps_keys

  @doc """
  Merge tool-supplied dependencies into the context, dropping protected keys.

  Deliberately a separate function from `merge_deps/2` — do not consolidate
  them. `merge_deps/2` must stay unfiltered because `Nous.AgentServer` uses it
  to re-apply the *operator's* deps over a deserialized context; filtering there
  would let a poisoned persisted `:workspace_root` outrank the operator's
  configuration, which is worse than the bug this guards. Here the direction is
  reversed — an LLM-driven tool result merging into an operator-configured
  context — so the incoming keys are the untrusted ones.

  See `protected_deps_keys/0`.

  ## Examples

      iex> ctx = Context.new(deps: %{workspace_root: "/srv/safe"})
      iex> ctx = Context.merge_tool_deps(ctx, %{workspace_root: "/", notes: []})
      iex> ctx.deps.workspace_root
      "/srv/safe"

  """
  @spec merge_tool_deps(t(), map()) :: t()
  def merge_tool_deps(%Context{} = ctx, new_deps) when is_map(new_deps) do
    merge_deps(ctx, drop_protected_deps(new_deps, ctx.agent_name))
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

    * `:approval_gated?` - Assert that an approval pipeline has ALREADY run for
      this call, so `Nous.ToolExecutor` does not prompt the operator a second
      time. Defaults to `false`, which leaves any `:approval_handler` on the
      context in charge of the gate. Only `Nous.AgentRunner` passes `true`.

  ## Examples

      iex> ctx = Context.new(deps: %{db: :postgres})
      iex> run_ctx = Context.to_run_context(ctx)
      iex> run_ctx.deps.db
      :postgres

      iex> Context.to_run_context(Context.new()).approval_gated?
      false

  """
  @spec to_run_context(t(), keyword()) :: Nous.RunContext.t()
  def to_run_context(%Context{} = ctx, opts \\ []) do
    # `approval_gated?` means "an approval pipeline has ALREADY run for this
    # call", so Nous.ToolExecutor must not prompt the operator a second time.
    # Only the caller that ran one can know that, so it is ASSERTED here, never
    # inferred. Two earlier shapes were both fail-open: stamping `true`
    # unconditionally made this public constructor a bypass primitive any caller
    # (sub-agent, workflow node, deserialized checkpoint) could use to mint a
    # pre-approved context, and deriving it from handler presence merely narrowed
    # that to callers who install a handler — whose handler ToolExecutor then
    # never consults, so even a `:reject` handler waved the call through. The
    # `false` default hands the gate back to that handler.
    # AgentRunner.ToolExecution passes `true` after check_tool_approval/3, which
    # is the one caller that has earned it.
    Nous.RunContext.new(ctx.deps,
      usage: ctx.usage,
      approval_handler: ctx.approval_handler,
      approval_gated?: Keyword.get(opts, :approval_gated?, false)
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

      %{ctx | messages: messages ++ synthetic_results}
    end
  end

  # Serialization

  @doc """
  Serialize context to a JSON-encodable map.

  Persists messages, usage, metadata. Never persists functions, PIDs, or modules.
  Includes a `version` field for future migrations.

  ## Examples

      iex> ctx = Context.new(system_prompt: "Be helpful", max_iterations: 5)
      iex> data = Context.serialize(ctx)
      iex> data.version
      1
      iex> data.system_prompt
      "Be helpful"

  """
  @spec serialize(t()) :: map()
  def serialize(%Context{} = ctx) do
    %{
      version: 1,
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

  Handles version migrations and restores messages, usage, and metadata.
  Functions, PIDs, and callbacks are not restored and will use defaults.

  Returns `{:ok, context}` or `{:error, reason}`.

  ## Examples

      iex> ctx = Context.new(system_prompt: "Be helpful")
      iex> data = Context.serialize(ctx)
      iex> {:ok, restored} = Context.deserialize(data)
      iex> restored.system_prompt
      "Be helpful"

  """
  @spec deserialize(map()) :: {:ok, t()} | {:error, term()}
  def deserialize(%{version: 1} = data) do
    do_deserialize(data)
  end

  def deserialize(%{"version" => 1} = data) do
    data
    |> atomize_keys()
    |> do_deserialize()
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

  defp drop_protected_deps(new_deps, agent_name) do
    case Enum.filter(@protected_deps_keys, &Map.has_key?(new_deps, &1)) do
      [] ->
        new_deps

      rejected ->
        Logger.warning(
          "Tool context update tried to rewrite protected deps key(s) " <>
            "#{inspect(rejected)} on agent #{inspect(agent_name)}; dropped. See " <>
            "Nous.Agent.Context.protected_deps_keys/0."
        )

        Map.drop(new_deps, rejected)
    end
  end

  defp do_deserialize(data) do
    messages =
      (data[:messages] || [])
      |> Enum.map(&deserialize_message/1)

    usage = deserialize_usage(data[:usage] || %{})

    started_at = deserialize_started_at(data[:started_at])

    ctx = %Context{
      messages: messages,
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

    {:ok, ctx}
  rescue
    # Deserializes attacker-controllable persisted blobs; a malformed blob
    # can raise from anywhere in the decode path, so the catch-all is a
    # deliberate boundary honoring the {:ok, _} | {:error, _} contract.
    e -> {:error, Exception.message(e)}
  end

  # No catch-all clause on purpose: a persisted `started_at` that is neither
  # nil nor a string is a malformed blob, and the raise is caught by
  # do_deserialize/1's boundary rescue as `{:error, message}` — the same
  # outcome the inline `case` produced.
  defp deserialize_started_at(nil), do: nil

  defp deserialize_started_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

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

  defp serialize_usage(%Usage{} = usage) do
    %{
      requests: usage.requests,
      tool_calls: usage.tool_calls,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens
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
      total_tokens: data[:total_tokens] || 0
    }
  end

  # Keys read from persisted state are attacker-controllable; Nous.Util only
  # resolves already-existing atoms, and unknown keys stay as binaries that
  # downstream Ecto.cast simply ignores.
  defp atomize_keys(map) when is_map(map), do: Nous.Util.atomize_keys(map)

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
