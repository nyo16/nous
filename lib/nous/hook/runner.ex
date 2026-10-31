defmodule Nous.Hook.Runner do
  @moduledoc """
  Executes hooks for lifecycle events with support for blocking, modification,
  and external command execution.

  ## Execution Semantics

  - **Blocking events** (`:pre_tool_use`, `:pre_request`, `:post_response`): short-circuits on first `:deny`
  - **Non-blocking events**: all hooks run, results collected
  - Hooks with the same priority run sequentially (ordered by registration)
  - Each hook has a configurable timeout (default 10s). `:function` and
    `:module` handlers run in a task under `Nous.TaskSupervisor` (with
    `$callers` propagated, so process-scoped test seams still resolve) and are
    killed when the timeout elapses; the timeout becomes `{:error, :timeout}`
    and follows the hook's `fail_closed` rules. The task also dies with the
    process that runs the hook, so a cancelled run leaves no hook running.
    `timeout: :infinity` runs the handler in the process that runs the hooks,
    for hooks that rely on `self()` or the process dictionary; with
    `parallel_tool_calls: true` a `:pre_tool_use` hook stage that contains one
    runs in the agent run process, one call at a time. A timeout that is
    neither a non-negative integer nor `:infinity` is a hook error.
  - A hook that returns something other than a `t:Nous.Hook.result/0` is
    logged and treated as `:allow`.

  ## `fail_closed`

  On blocking events an erroring `fail_closed: true` hook denies the event.
  On `:post_tool_use` it replaces the tool result with
  `"[tool result withheld: hook error]"` and stops running later hooks,
  so a broken redaction hook cannot leak the unredacted result. Both emit
  `[:nous, :hook, :failed_closed]`. Other non-blocking events fail open.

  ## Handler Types

  - `:function` — Calls the function directly with `(event, payload)`
  - `:module` — Calls `module.handle(event, payload)`
  - `:command` — Executes shell command via `NetRunner.run/2` with JSON on stdin.
    Requires the optional `:net_runner` dependency; without it every `:command`
    hook fails closed (denies the event) rather than silently passing.
  - `:decision` — Classifies the payload with a `Nous.DecisionModel`; see
    `Nous.Hook.Decision`. The only handler type that receives `env`.

  ## `env`

  `run/4` takes an `env` beside the payload:
  `%{approval_handler:, agent_name:, task:, tool:}` (`t:Nous.Hook.Decision.env/0`).
  It is handed **only** to `:decision` handlers, so payloads stay
  JSON-encodable and function/module/command hooks see exactly what they
  always did. `env` may be a zero-arity function returning the map; it is
  called once, and only when a decision hook runs.

  ## Sandbox

  Command hooks are **not** confined by `Nous.Sandbox` by default. Hooks are
  user-authored operator code, not model-authored, and a hook that cannot write
  anywhere defeats the point of having a hook. Confining them by default would
  also fail closed on every host with no sandbox provider, silently breaking
  working deployments.

  Operators who run hooks whose contents they do not fully control can opt in:

      config :nous, :sandbox_confine_command_hooks, true

  With the flag on, the hook argv is wrapped using
  `Nous.Sandbox.Policy.resolve(nil)` (no `Nous.RunContext` exists at this
  layer, so the policy comes from application config). If no provider can
  enforce the requested mode, the hook does **not** run unconfined: a warning
  is logged and an `{:error, _}` result is returned, which follows the hook's
  existing `fail_closed` semantics — `:deny` when `fail_closed: true`,
  otherwise the run continues to the next hook. Security-gating hooks should
  therefore pair the flag with `fail_closed: true`: under the default
  `fail_closed: false`, a confine error skips the hook rather than denying
  the event (the command itself never runs unconfined either way).

  The flag alone is not enough. `:sandbox_mode` must also be set: an unset
  mode resolves to `:danger_full_access`, which means the flag is on and hooks
  still run unconfined. That combination logs an explicit warning naming both
  settings, once per VM.

  Unlike `Nous.Tools.Bash`, hook stderr stays on `:consume`: the hook protocol
  parses stdout as JSON, so merging stderr in would corrupt it. Consequently
  `Nous.Sandbox.classify/3` is **not** used on this path — every signature it
  matches is written to stderr, which this path never sees. Instead, once the
  argv is actually confined (`enforcement != :none`), any nonzero exit other
  than the protocol's own `2` (deny) is treated as `:deny` regardless of
  `fail_closed`: from stdout alone, "the sandbox denied the hook", "the runner
  could not start" and "the hook failed" are indistinguishable, and a hook
  that may never have run must not be able to permit the event.

  Unconfined hooks (`enforcement == :none`, the default) keep their historical
  behaviour exactly: a nonzero exit other than `2` fails open unless the hook
  sets `fail_closed: true`.
  """

  alias Nous.Hook
  alias Nous.Hook.{Decision, Registry}
  alias Nous.Sandbox
  alias Nous.Sandbox.{Confined, Policy}

  require Hook
  require Logger

  @withheld_tool_result "[tool result withheld: hook error]"

  @doc """
  Run all matching hooks for an event, with an empty `env`. See `run/4`.
  """
  @spec run(Registry.t() | nil, Hook.event(), map()) :: Hook.result()
  def run(registry, event, payload), do: run(registry, event, payload, %{})

  @doc """
  Run all matching hooks for an event.

  `env` (a map, or a zero-arity function returning one) is passed only to
  `:decision` handlers; see the moduledoc.

  Returns the aggregate result:
  - `:allow` — all hooks passed (or no hooks registered)
  - `:deny` or `{:deny, reason}` — a hook blocked the action
  - `{:modify, changes}` — a hook wants to modify the payload (last modify wins)
  """
  @spec run(Registry.t() | nil, Hook.event(), map(), map() | (-> map())) :: Hook.result()
  def run(nil, _event, _payload, _env), do: :allow

  def run(%Registry{} = registry, event, payload, env) do
    hooks = Registry.hooks_for(registry, event, payload)
    run_hooks(hooks, event, payload, env)
  end

  @doc """
  Run a list of hooks directly (without registry lookup).
  """
  @spec run_hooks([Hook.t()], Hook.event(), map(), map() | (-> map())) :: Hook.result()
  def run_hooks(hooks, event, payload, env \\ %{})

  def run_hooks([], _event, _payload, _env), do: :allow

  def run_hooks(hooks, event, payload, env) do
    env = resolve_env(hooks, env)

    if Hook.blocking_event?(event) do
      run_blocking(hooks, event, payload, env, %{})
    else
      run_non_blocking(hooks, event, payload, env)
    end
  end

  @env_keys [:approval_handler, :agent_name, :task, :tool]

  # Built at most once per event, and only when a decision hook will see it.
  defp resolve_env(hooks, env) do
    if Enum.any?(hooks, &(&1.type == :decision)) do
      env = if is_function(env, 0), do: env.(), else: env
      Map.merge(Map.new(@env_keys, &{&1, nil}), env)
    else
      %{}
    end
  end

  # For blocking events, short-circuit on first :deny. Modifications are
  # applied to the payload the NEXT hook sees AND accumulated, so the caller
  # gets `{:modify, changes}` back when every hook allowed — without that the
  # documented `{:modify, %{arguments: ...}}` rewrite reached later hooks and
  # nobody else.
  defp run_blocking([], _event, _payload, _env, changes) when map_size(changes) == 0, do: :allow
  defp run_blocking([], _event, _payload, _env, changes), do: {:modify, changes}

  defp run_blocking([hook | rest], event, payload, env, changes) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:nous, :hook, :execute, :start],
      %{system_time: System.system_time()},
      %{event: event, hook_name: hook.name, hook_type: hook.type}
    )

    result = execute_hook(hook, event, payload, env)
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:nous, :hook, :execute, :stop],
      %{duration: duration},
      %{event: event, hook_name: hook.name, hook_type: hook.type, result: result_type(result)}
    )

    case result do
      :allow ->
        run_blocking(rest, event, payload, env, changes)

      :deny ->
        Logger.info("Hook #{inspect(hook.name || hook.type)} denied #{event}")

        :telemetry.execute(
          [:nous, :hook, :denied],
          %{},
          %{event: event, hook_name: hook.name, hook_type: hook.type}
        )

        :deny

      {:deny, reason} ->
        # The reason reaches log lines, tool messages and
        # `Nous.Errors.ResponseDenied` (a `String.t()`), so a non-string one
        # (a function hook may return `{:deny, %{code: :pii}}`) is inspected
        # there. Telemetry keeps the hook's own term.
        text = if is_binary(reason), do: reason, else: inspect(reason)
        Logger.info("Hook #{inspect(hook.name || hook.type)} denied #{event}: #{text}")

        :telemetry.execute(
          [:nous, :hook, :denied],
          %{},
          %{event: event, hook_name: hook.name, hook_type: hook.type, reason: reason}
        )

        {:deny, text}

      {:modify, new_changes} when is_map(new_changes) ->
        # Apply modification to payload, continue with remaining hooks
        updated_payload = Map.merge(payload, new_changes)
        run_blocking(rest, event, updated_payload, env, Map.merge(changes, new_changes))

      {:error, reason} ->
        Logger.warning(
          "Hook #{inspect(hook.name || hook.type)} errored on #{event}: #{inspect(reason)}"
        )

        # By default errors fail OPEN (continue to the next hook). When the
        # hook opts in with `fail_closed: true` we treat the error as :deny
        # — so a broken security-gating hook can't be silently bypassed.
        if hook.fail_closed do
          :telemetry.execute(
            [:nous, :hook, :denied],
            %{},
            %{
              event: event,
              hook_name: hook.name,
              hook_type: hook.type,
              reason: {:fail_closed, reason}
            }
          )

          emit_failed_closed(hook, event, reason)

          {:deny, "hook errored (fail_closed): #{inspect(reason)}"}
        else
          run_blocking(rest, event, payload, env, changes)
        end

      other ->
        # Not a hook result (an observer hook returning `:ok` or `nil`, or a
        # `{:modify, _}` without a map). Treated as `:allow`, the same as on
        # non-blocking events.
        Logger.warning(
          "Hook #{inspect(hook.name || hook.type)} returned #{inspect(other)} on #{event}; " <>
            "treating it as :allow"
        )

        run_blocking(rest, event, payload, env, changes)
    end
  end

  # For non-blocking events, run all hooks and collect modifications. Each
  # hook sees the payload with every earlier hook's modifications applied, so a
  # later (e.g. decision) hook judges what the caller will actually receive.
  # The exceptions are a `fail_closed` hook erroring on `:post_tool_use` and a
  # decision hook withholding a result: the result is withheld and no later
  # hook runs (a later `{:modify, %{result: _}}` must not put the unredacted
  # value back).
  defp run_non_blocking(hooks, event, payload, env) do
    Enum.reduce_while(hooks, :allow, fn hook, acc ->
      current =
        case acc do
          {:modify, changes} -> Map.merge(payload, changes)
          _ -> payload
        end

      start_time = System.monotonic_time()

      :telemetry.execute(
        [:nous, :hook, :execute, :start],
        %{system_time: System.system_time()},
        %{event: event, hook_name: hook.name, hook_type: hook.type}
      )

      result = execute_hook(hook, event, current, env)
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:nous, :hook, :execute, :stop],
        %{duration: duration},
        %{event: event, hook_name: hook.name, hook_type: hook.type, result: result_type(result)}
      )

      case result do
        :allow ->
          {:cont, acc}

        {:modify, changes} when is_map(changes) ->
          # Merge modifications (last writer wins for conflicts)
          case acc do
            {:modify, existing} -> {:cont, {:modify, Map.merge(existing, changes)}}
            _ -> {:cont, {:modify, changes}}
          end

        {:withhold, text} ->
          {:halt, {:modify, %{result: text}}}

        {:error, reason} ->
          Logger.warning(
            "Hook #{inspect(hook.name || hook.type)} errored on #{event}: #{inspect(reason)}"
          )

          if hook.fail_closed and event == :post_tool_use do
            emit_failed_closed(hook, event, reason)
            {:halt, {:modify, %{result: @withheld_tool_result}}}
          else
            {:cont, acc}
          end

        # Not a hook result, including a `{:modify, _}` without a map: ignored.
        _ ->
          {:cont, acc}
      end
    end)
  end

  defp emit_failed_closed(hook, event, reason) do
    :telemetry.execute(
      [:nous, :hook, :failed_closed],
      %{system_time: System.system_time()},
      %{event: event, hook_name: hook.name, hook_type: hook.type, reason: reason}
    )
  end

  # Execute a single hook based on its type. Only :decision handlers see env.
  # A timeout nothing can enforce (e.g. `nil` on a struct-literal hook) is a
  # hook error, returned before any task is spawned.
  defp execute_hook(%Hook{timeout: timeout} = hook, event, _payload, _env)
       when not Hook.valid_timeout?(timeout) do
    Logger.warning(
      "Hook #{inspect(hook.name || hook.type)} has an invalid timeout #{inspect(timeout)} " <>
        "on #{event}; expected a non-negative integer or :infinity"
    )

    {:error, {:invalid_timeout, timeout}}
  end

  defp execute_hook(
         %Hook{type: :decision, handler: %Decision{} = decision} = hook,
         event,
         payload,
         env
       ) do
    Decision.evaluate(decision, hook, event, payload, env)
  end

  defp execute_hook(%Hook{type: :function, handler: fun} = hook, event, payload, _env)
       when is_function(fun, 2) do
    bounded(hook, "Function hook", fn -> fun.(event, payload) end)
  end

  defp execute_hook(%Hook{type: :module, handler: module} = hook, event, payload, _env)
       when is_atom(module) do
    bounded(hook, "Module hook #{inspect(module)}", fn ->
      Code.ensure_loaded!(module)
      module.handle(event, payload)
    end)
  end

  # Command hook handler MUST be a [program | args] list. The previous
  # API accepted a raw string and ran it via `sh -c`, which means any
  # caller-controllable handler value became RCE through shell expansion.
  # Lists bypass the shell entirely.
  defp execute_hook(
         %Hook{type: :command, handler: [program | _] = argv} = hook,
         event,
         payload,
         _env
       )
       when is_binary(program) do
    execute_command_hook(argv, event, payload, hook.timeout, hook.fail_closed)
  end

  defp execute_hook(%Hook{type: :command, handler: handler}, _event, _payload, _env) do
    Logger.warning(
      "Command hook handler must be a [program | args] list of binaries, got: #{inspect(handler)}. " <>
        "Raw shell strings are no longer accepted - they're an RCE risk if the value " <>
        "is ever set from user input or config. Convert to e.g. [\"python3\", \"scripts/check.py\"]."
    )

    {:error, :invalid_command_handler}
  end

  defp execute_hook(hook, _event, _payload, _env) do
    Logger.warning("Invalid hook configuration: #{inspect(hook)}")
    {:error, :invalid_hook}
  end

  # Execute a command hook via NetRunner. The argv list is passed
  # directly - no shell, no expansion.
  #
  # net_runner is `optional: true` in mix.exs, so a downstream app may compile
  # nous without it (NetRunner sits in `no_warn_undefined`). Runtime guard —
  # not the compile-time Tyrex conditional — so the real clause stays
  # compiled downstream and its helpers don't turn into "unused function"
  # warnings. The guard MUST sit before `confine_hook_argv/1`: with
  # `:sandbox_confine_command_hooks` on, the confine backends probe the sandbox
  # via `NetRunner.run/2` themselves, and the resulting UndefinedFunctionError
  # would be rescued by `contained/2` into a generic `{:error, _}` that fails
  # OPEN unless `fail_closed` is set. Without NetRunner a :command hook cannot
  # run at all, and a hook that never ran must not be able to permit the event
  # — the same reasoning as the confined nonzero-exit branch below — so it
  # fails closed regardless of `fail_closed`.
  defp execute_command_hook(argv, event, payload, timeout, fail_closed) do
    if Code.ensure_loaded?(NetRunner) do
      json_input =
        JSON.encode!(%{
          event: event,
          payload: sanitize_payload(payload)
        })

      contained("Command hook", fn ->
        case confine_hook_argv(argv) do
          {:ok, confined} -> run_command_hook(confined, json_input, timeout, fail_closed)
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      Logger.warning(
        "Command hook NOT run: the optional :net_runner dependency is not available: " <>
          "#{inspect(argv)}. Add {:net_runner, \"~> 1.4.1\"} to your deps to " <>
          "enable :command hooks. Denying the event (fail closed)."
      )

      {:deny, "command hook not run: the optional :net_runner dependency is not available"}
    end
  end

  # Off by default: hooks are operator-authored, and one that cannot write
  # anywhere is not a hook. With the flag on we resolve from application config
  # — there is no `Nous.RunContext` at this layer to carry a session policy.
  #
  # The unconfined branch still goes through `Nous.Sandbox.confine/2` rather
  # than skipping it, because `:danger_full_access` is that module's documented
  # way to ask for no confinement: it short-circuits before any backend probe
  # and yields a passthrough argv carrying `enforcement: :none`. One code path,
  # no special case.
  defp confine_hook_argv(argv) do
    policy =
      if Application.get_env(:nous, :sandbox_confine_command_hooks, false) do
        policy = Policy.resolve(nil)
        warn_confine_flag_without_mode_once(policy)
        policy
      else
        Policy.new(:danger_full_access)
      end

    case Sandbox.confine(argv, policy) do
      {:ok, confined} ->
        {:ok, confined}

      {:error, reason} ->
        Logger.warning(
          "Command hook NOT run: no sandbox can confine it (#{inspect(reason)}): " <>
            "#{inspect(argv)}. Running it unconfined is not an option; " <>
            "`fail_closed` decides whether this denies the event."
        )

        {:error, reason}
    end
  end

  @confine_flag_warned_key {__MODULE__, :confine_flag_without_mode_warned}

  # `sandbox_confine_command_hooks: true` with `:sandbox_mode` unset resolves to
  # `:danger_full_access`: the flag is on and hooks still run unconfined. The
  # only other signal is `Nous.Sandbox.Policy`'s once-per-VM permissive-default
  # warning, which an unrelated caller may already have consumed. Refusing to
  # run would be a surprising hard failure on an opt-in flag, so be loud
  # instead. Once per VM, same `:persistent_term` latch as `Policy`.
  defp warn_confine_flag_without_mode_once(%Policy{mode: :danger_full_access}) do
    if :persistent_term.get(@confine_flag_warned_key, nil) do
      :ok
    else
      :persistent_term.put(@confine_flag_warned_key, true)

      Logger.warning(
        "`config :nous, :sandbox_confine_command_hooks, true` is set, but the resolved " <>
          "sandbox mode is :danger_full_access, so command hooks run UNCONFINED. Both " <>
          "settings are required: also set `config :nous, :sandbox_mode, :workspace_write` " <>
          "(or :read_only) to actually confine them."
      )
    end
  end

  defp warn_confine_flag_without_mode_once(%Policy{}), do: :ok

  # Deliberately no `Nous.Sandbox.merge_stderr/1` and no `:stderr` opt: the hook
  # protocol parses stdout as JSON (`parse_command_output/1`), so merging the
  # child's stderr into that stream would corrupt it.
  #
  # This is also why `Nous.Sandbox.classify/3` is not called here. With
  # `stderr: :consume`, `NetRunner.run/2` returns stdout only, while every
  # signature `classify/3` matches (`bwrap: `, `operation not permitted`, …) is
  # written to stderr — so a classification of this stream could only ever
  # answer `:ok`, and calling it would imply a check that cannot fire. Real
  # classification would need the hook's *stderr alone* captured, e.g. wrapping
  # the argv as `sh -c 'exec "$@" 2>"$0"' <tmpfile> …` and classifying that file
  # after the run. Until then, confinement is handled by failing closed below.
  #
  # NetRunner availability is guaranteed here: `execute_command_hook/5` gates
  # on `Code.ensure_loaded?(NetRunner)` before any confine call and denies the
  # event when the optional dep is missing.
  #
  # `Nous.Sandbox.run/2`, not `NetRunner.run/2`: on timeout NetRunner waits a
  # fixed 5 s for a SIGTERM-ignoring child, so a hook that traps TERM overran
  # its `timeout` by 5 s. This returns within `timeout` +
  # `Nous.Sandbox.kill_timeout_ms/0`.
  defp run_command_hook(%Confined{} = confined, json_input, timeout, fail_closed) do
    case Nous.Sandbox.run(confined.argv, input: json_input, timeout: timeout) do
      {:error, :timeout} ->
        Logger.warning("Command hook timed out after #{timeout}ms: #{inspect(confined.argv)}")
        {:error, :timeout}

      {output, exit_code} when is_integer(exit_code) ->
        command_hook_result(output, exit_code, fail_closed, confined.enforcement)

      {:error, reason} ->
        Logger.warning("Command hook failed to run: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp command_hook_result(output, 0, _fail_closed, _enforcement),
    do: parse_command_output(output)

  defp command_hook_result(_output, 2, _fail_closed, _enforcement), do: :deny

  # Confined: from stdout alone, "the sandbox denied the hook", "the runner
  # could not start" and "the hook itself failed" are indistinguishable — all
  # three report on stderr, which this path never sees. A hook that may never
  # have run must not be able to permit the event, so fail closed regardless of
  # `fail_closed`. This is the opt-in path only.
  defp command_hook_result(output, exit_code, _fail_closed, enforcement)
       when enforcement != :none do
    Logger.warning(
      "Confined command hook (#{enforcement}) exited with code #{exit_code}; it may have " <>
        "been denied by the sandbox or never run at all. Denying: #{String.trim(output)}"
    )

    {:deny,
     "confined command hook exited with code #{exit_code}; " <>
       "it may have been denied by the sandbox or never run"}
  end

  # Unconfined (the default): unchanged historical behaviour.
  defp command_hook_result(output, exit_code, fail_closed, :none) do
    Logger.warning("Command hook exited with code #{exit_code}: #{String.trim(output)}")

    # Non-0/2 exit codes default to fail OPEN for backward compat;
    # set fail_closed: true on the hook to treat them as :deny so a
    # crashing security-gating hook can't be silently bypassed.
    if fail_closed do
      {:deny, "command hook exited with code #{exit_code} (fail_closed)"}
    else
      :allow
    end
  end

  # Enforce `hook.timeout` on an in-VM handler. `Task.Supervisor.async_nolink/2`
  # sets `$callers` to this process's caller chain, so `Nous.ModelDispatcher`
  # and other process-scoped seams resolve inside the handler as they would
  # in-process. Unlinked so a handler crash cannot take the run down; killed
  # outright on timeout, or when the caller dies, so a hung handler cannot
  # outlive it (`async_task/1`).
  defp bounded(%Hook{timeout: :infinity}, label, fun), do: contained(label, fun)

  defp bounded(%Hook{timeout: timeout}, label, fun) do
    task = async_task(fn -> contained(label, fun) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.warning("#{label} exited: #{inspect(reason)}")
        {:error, {:exit, reason}}

      nil ->
        Logger.warning("#{label} timed out after #{timeout}ms")
        {:error, :timeout}
    end
  end

  @doc false
  # `Task.Supervisor.async_nolink/2` under `Nous.TaskSupervisor`, plus a
  # watcher that kills the task when the calling process dies. An unlinked task
  # keeps a handler crash away from the caller, but would otherwise keep
  # running after the caller is gone: a cancelled run (`Nous.AgentServer`
  # exits the run with `:shutdown`) could still be calling a decision model or
  # prompting a human. The watcher monitors both processes and exits with
  # whichever goes first, so it never outlives the task.
  @spec async_task((-> term())) :: Task.t()
  def async_task(fun) when is_function(fun, 0) do
    caller = self()

    Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
      task = self()

      spawn(fn ->
        caller_ref = Process.monitor(caller)
        task_ref = Process.monitor(task)

        receive do
          {:DOWN, ^caller_ref, _, _, _} -> Process.exit(task, :kill)
          {:DOWN, ^task_ref, _, _, _} -> :ok
        end
      end)

      fun.()
    end)
  end

  # Run a hook body with full containment: hooks execute arbitrary user code,
  # so any raise or throw becomes a logged {:error, _} instead of crashing
  # the agent run. (A catch-all rescue is deliberate at this boundary.)
  defp contained(label, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("#{label} raised: #{Exception.message(e)}")
      {:error, e}
  catch
    kind, reason ->
      Logger.warning("#{label} threw #{kind}: #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  # Parse stdout from command hook as JSON
  defp parse_command_output(""), do: :allow

  defp parse_command_output(output) do
    output = String.trim(output)

    case JSON.decode(output) do
      {:ok, %{"result" => "deny", "reason" => reason}} ->
        {:deny, reason}

      {:ok, %{"result" => "deny"}} ->
        :deny

      {:ok, %{"result" => "allow"}} ->
        :allow

      {:ok, %{"result" => "modify", "changes" => changes}} when is_map(changes) ->
        {:modify, normalize_changes(changes)}

      {:ok, _} ->
        :allow

      {:error, _} ->
        # Non-JSON output treated as allow
        :allow
    end
  end

  # A command hook's `changes` arrive from JSON with string keys, while every
  # consumer (`Nous.AgentRunner.ToolExecution`, `Nous.CodeMode.direct_dispatch/3`,
  # the workflow engine) matches the atom keys a function hook returns —
  # `%{arguments: …}`, `%{result: …}`. Left as-is, `Map.merge(payload, changes)`
  # added a string-keyed sibling and the documented path-sanitising command
  # hook never took effect. Only the payload keys the runner defines are
  # translated (a literal allow-list — never `String.to_atom/1` on hook
  # output); anything else stays a string and is ignored downstream.
  @change_keys %{
    "arguments" => :arguments,
    "result" => :result,
    "tool_name" => :tool_name,
    "state" => :state,
    "messages" => :messages,
    "settings" => :settings,
    "response" => :response
  }

  defp normalize_changes(changes) do
    Map.new(changes, fn {key, value} -> {Map.get(@change_keys, key, key), value} end)
  end

  # Remove non-serializable values from payload before JSON encoding. One pass:
  # the filter, the key/value rewrite and the rebuild used to be three, each
  # materialising an intermediate list of the whole payload.
  defp sanitize_payload(payload) when is_map(payload) do
    for {k, v} <- payload, not (is_function(v) or is_pid(v) or is_reference(v)), into: %{} do
      {to_string(k), sanitize_value(v)}
    end
  end

  defp sanitize_value(v) when is_map(v), do: sanitize_payload(v)
  defp sanitize_value(v) when is_list(v), do: Enum.map(v, &sanitize_value/1)
  defp sanitize_value(v) when is_atom(v), do: to_string(v)
  defp sanitize_value(v) when is_tuple(v), do: Tuple.to_list(v) |> Enum.map(&sanitize_value/1)
  defp sanitize_value(v), do: v

  defp result_type(:allow), do: :allow
  defp result_type(:deny), do: :deny
  defp result_type({:deny, _}), do: :deny
  defp result_type({:modify, changes}) when is_map(changes), do: :modify
  defp result_type({:withhold, _}), do: :modify
  defp result_type({:error, _}), do: :error
  defp result_type(_), do: :unknown
end
