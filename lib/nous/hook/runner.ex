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
  """

  alias Nous.Hook
  alias Nous.Hook.Registry

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

        # Errors in hooks don't block — fail open
        run_blocking(rest, event, payload)
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
    try do
      fun.(event, payload)
    rescue
      e ->
        Logger.warning("Function hook raised: #{Exception.message(e)}")
        {:error, e}
    catch
      kind, reason ->
        Logger.warning("Function hook threw #{kind}: #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  defp execute_hook(%Hook{type: :module, handler: module}, event, payload) when is_atom(module) do
    try do
      Code.ensure_loaded!(module)
      module.handle(event, payload)
    rescue
      e ->
        Logger.warning("Module hook #{inspect(module)} raised: #{Exception.message(e)}")
        {:error, e}
    end
  end

  defp execute_hook(%Hook{type: :command, handler: command, timeout: timeout}, event, payload)
       when is_binary(command) do
    execute_command_hook(command, event, payload, timeout)
  end

  defp execute_hook(hook, _event, _payload) do
    Logger.warning("Invalid hook configuration: #{inspect(hook)}")
    {:error, :invalid_hook}
  end

  # Execute a shell command hook via NetRunner
  defp execute_command_hook(command, event, payload, timeout) do
    json_input =
      Jason.encode!(%{
        event: event,
        payload: sanitize_payload(payload)
      })

    try do
      case NetRunner.run(["sh", "-c", command], input: json_input, timeout: timeout) do
        {output, 0} ->
          parse_command_output(output)

        {_output, 2} ->
          :deny

        {:error, :timeout} ->
          Logger.warning("Command hook timed out after #{timeout}ms: #{command}")
          {:error, :timeout}

        {output, exit_code} ->
          Logger.warning("Command hook exited with code #{exit_code}: #{String.trim(output)}")

          # Non-0/2 exit codes fail open
          :allow
      end
    rescue
      e ->
        Logger.warning("Command hook failed: #{Exception.message(e)}")
        {:error, e}
    end
  end

  # Parse stdout from command hook as JSON
  defp parse_command_output(""), do: :allow

  defp parse_command_output(output) do
    output = String.trim(output)

    case Jason.decode(output) do
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
