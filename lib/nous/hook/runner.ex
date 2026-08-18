defmodule Nous.Hook.Runner do
  @moduledoc """
  Executes hooks for lifecycle events with support for blocking, modification,
  and external command execution.

  ## Execution Semantics

  - **Blocking events** (`:pre_tool_use`, `:pre_request`): short-circuits on first `:deny`
  - **Non-blocking events**: all hooks run, results collected
  - Hooks with the same priority run sequentially (ordered by registration)
  - Each hook has a configurable timeout (default 10s)

  ## Handler Types

  - `:function` — Calls the function directly with `(event, payload)`
  - `:module` — Calls `module.handle(event, payload)`
  - `:command` — Executes shell command via `NetRunner.run/2` with JSON on stdin

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
  otherwise the run continues to the next hook.

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
  alias Nous.Hook.Registry
  alias Nous.Sandbox
  alias Nous.Sandbox.{Confined, Policy}

  require Logger

  @doc """
  Run all matching hooks for an event.

  Returns the aggregate result:
  - `:allow` — all hooks passed (or no hooks registered)
  - `:deny` or `{:deny, reason}` — a hook blocked the action
  - `{:modify, changes}` — a hook wants to modify the payload (last modify wins)
  """
  @spec run(Registry.t() | nil, Hook.event(), map()) :: Hook.result()
  def run(nil, _event, _payload), do: :allow

  def run(%Registry{} = registry, event, payload) do
    hooks = Registry.hooks_for(registry, event, payload)
    run_hooks(hooks, event, payload)
  end

  @doc """
  Run a list of hooks directly (without registry lookup).
  """
  @spec run_hooks([Hook.t()], Hook.event(), map()) :: Hook.result()
  def run_hooks([], _event, _payload), do: :allow

  def run_hooks(hooks, event, payload) do
    if Hook.blocking_event?(event) do
      run_blocking(hooks, event, payload)
    else
      run_non_blocking(hooks, event, payload)
    end
  end

  # For blocking events, short-circuit on first :deny
  defp run_blocking([], _event, _payload), do: :allow

  defp run_blocking([hook | rest], event, payload) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:nous, :hook, :execute, :start],
      %{system_time: System.system_time()},
      %{event: event, hook_name: hook.name, hook_type: hook.type}
    )

    result = execute_hook(hook, event, payload)
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:nous, :hook, :execute, :stop],
      %{duration: duration},
      %{event: event, hook_name: hook.name, hook_type: hook.type, result: result_type(result)}
    )

    case result do
      :allow ->
        run_blocking(rest, event, payload)

      :deny ->
        Logger.info("Hook #{inspect(hook.name || hook.type)} denied #{event}")

        :telemetry.execute(
          [:nous, :hook, :denied],
          %{},
          %{event: event, hook_name: hook.name, hook_type: hook.type}
        )

        :deny

      {:deny, reason} = denied ->
        Logger.info("Hook #{inspect(hook.name || hook.type)} denied #{event}: #{reason}")

        :telemetry.execute(
          [:nous, :hook, :denied],
          %{},
          %{event: event, hook_name: hook.name, hook_type: hook.type, reason: reason}
        )

        denied

      {:modify, changes} ->
        # Apply modification to payload, continue with remaining hooks
        updated_payload = Map.merge(payload, changes)
        run_blocking(rest, event, updated_payload)

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

          {:deny, "hook errored (fail_closed): #{inspect(reason)}"}
        else
          run_blocking(rest, event, payload)
        end
    end
  end

  # For non-blocking events, run all hooks and collect modifications
  defp run_non_blocking(hooks, event, payload) do
    Enum.reduce(hooks, :allow, fn hook, acc ->
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:nous, :hook, :execute, :start],
        %{system_time: System.system_time()},
        %{event: event, hook_name: hook.name, hook_type: hook.type}
      )

      result = execute_hook(hook, event, payload)
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:nous, :hook, :execute, :stop],
        %{duration: duration},
        %{event: event, hook_name: hook.name, hook_type: hook.type, result: result_type(result)}
      )

      case result do
        :allow ->
          acc

        {:modify, changes} ->
          # Merge modifications (last writer wins for conflicts)
          case acc do
            {:modify, existing} -> {:modify, Map.merge(existing, changes)}
            _ -> {:modify, changes}
          end

        {:error, reason} ->
          Logger.warning(
            "Hook #{inspect(hook.name || hook.type)} errored on #{event}: #{inspect(reason)}"
          )

          acc

        _ ->
          acc
      end
    end)
  end

  # Execute a single hook based on its type
  defp execute_hook(%Hook{type: :function, handler: fun}, event, payload)
       when is_function(fun, 2) do
    contained("Function hook", fn -> fun.(event, payload) end)
  end

  defp execute_hook(%Hook{type: :module, handler: module}, event, payload) when is_atom(module) do
    contained("Module hook #{inspect(module)}", fn ->
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
         payload
       )
       when is_binary(program) do
    execute_command_hook(argv, event, payload, hook.timeout, hook.fail_closed)
  end

  defp execute_hook(%Hook{type: :command, handler: handler}, _event, _payload) do
    Logger.warning(
      "Command hook handler must be a [program | args] list of binaries, got: #{inspect(handler)}. " <>
        "Raw shell strings are no longer accepted - they're an RCE risk if the value " <>
        "is ever set from user input or config. Convert to e.g. [\"python3\", \"scripts/check.py\"]."
    )

    {:error, :invalid_command_handler}
  end

  defp execute_hook(hook, _event, _payload) do
    Logger.warning("Invalid hook configuration: #{inspect(hook)}")
    {:error, :invalid_hook}
  end

  # Execute a command hook via NetRunner. The argv list is passed
  # directly - no shell, no expansion.
  defp execute_command_hook(argv, event, payload, timeout, fail_closed) do
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
  defp run_command_hook(%Confined{} = confined, json_input, timeout, fail_closed) do
    case NetRunner.run(confined.argv, input: json_input, timeout: timeout) do
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
        {:modify, changes}

      {:ok, _} ->
        :allow

      {:error, _} ->
        # Non-JSON output treated as allow
        :allow
    end
  end

  # Remove non-serializable values from payload before JSON encoding
  defp sanitize_payload(payload) when is_map(payload) do
    payload
    |> Enum.reject(fn {_k, v} -> is_function(v) or is_pid(v) or is_reference(v) end)
    |> Enum.map(fn {k, v} -> {to_string(k), sanitize_value(v)} end)
    |> Map.new()
  end

  defp sanitize_value(v) when is_map(v), do: sanitize_payload(v)
  defp sanitize_value(v) when is_list(v), do: Enum.map(v, &sanitize_value/1)
  defp sanitize_value(v) when is_atom(v), do: to_string(v)
  defp sanitize_value(v) when is_tuple(v), do: Tuple.to_list(v) |> Enum.map(&sanitize_value/1)
  defp sanitize_value(v), do: v

  defp result_type(:allow), do: :allow
  defp result_type(:deny), do: :deny
  defp result_type({:deny, _}), do: :deny
  defp result_type({:modify, _}), do: :modify
  defp result_type({:error, _}), do: :error
  defp result_type(_), do: :unknown
end
