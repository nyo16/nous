defmodule Nous.AgentRunner.Instrumentation do
  @moduledoc false
  # The runner's telemetry: the run span every entry point opens
  # (`[:nous, :agent, :run, *]`), the model span around each model request
  # (`[:nous, :agent, :model, *]`), the per-call tool span
  # (`[:nous, :agent, :tool_call, *]`) and the structured-output retry event.
  # Event names and keys are the public contract documented in
  # `Nous.Telemetry`; change them there first.
  #
  # Every event carries `Nous.Telemetry.RunScope.metadata/0`. `scoped/2` is
  # where a run's scope is minted and installed, so everything the run emits,
  # in this process and in the tasks it fans out, carries the run's ids.

  alias Nous.{Message, ToolCall}
  alias Nous.Agent.Context
  alias Nous.Telemetry.RunScope

  require Logger

  # Marks a run whose terminal event (`:stop` or `:exception`) was emitted, so
  # a raise after it (a user callback crashing in `on_agent_complete`) does not
  # add a second terminal event. Keyed by run id in the emitting process.
  @terminal_key :"$nous_run_terminal"

  # ── run span ───────────────────────────────────────────────────────────────

  @doc false
  # Mint the run's scope from the enclosing one, emit
  # `[:nous, :agent, :run, :start]` and run `fun.(run_scope, start_time)`
  # inside the scope. A raise, throw or exit out of `fun` emits
  # `[:nous, :agent, :run, :exception]` with its real stacktrace (unless the
  # run already emitted its terminal event) and is re-raised unchanged.
  @spec scoped(Nous.Agent.t(), (map(), integer() -> result)) :: result when result: var
  def scoped(agent, fun) when is_function(fun, 2) do
    run_scope = RunScope.start_run()

    RunScope.with_scope(RunScope.install_scope(run_scope), fn ->
      start_time = run_start(agent, run_scope)

      try do
        fun.(run_scope, start_time)
      catch
        kind, reason ->
          run_exception(agent, run_scope, start_time, kind, reason, __STACKTRACE__)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        Process.delete({@terminal_key, run_scope.agent_run_id})
      end
    end)
  end

  @doc false
  @spec run_start(Nous.Agent.t(), map()) :: integer()
  def run_start(agent, run_scope) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:nous, :agent, :run, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      run_scope
      |> RunScope.run_start_metadata()
      |> Map.merge(%{
        agent_name: agent.name,
        model_provider: agent.model.provider,
        model_name: agent.model.model,
        tool_count: length(agent.tools),
        has_tools: agent.tools != []
      })
    )

    start_time
  end

  @doc false
  # `served_model` is the model the run's last request went to (routing or a
  # fallback may have moved it off `agent.model`).
  @spec run_stop(Nous.Agent.t(), map(), integer(), map(), map()) :: :ok
  def run_stop(agent, run_scope, start_time, usage_info, served) do
    terminal_once(run_scope, fn ->
      :telemetry.execute(
        [:nous, :agent, :run, :stop],
        Map.put(usage_info, :duration, System.monotonic_time() - start_time),
        RunScope.merge(%{
          agent_name: agent.name,
          model_provider: agent.model.provider,
          model_name: agent.model.model,
          active_model_provider: served.model.provider,
          active_model_name: served.model.model,
          fallback_used: served.fallback_used
        })
      )
    end)
  end

  @doc false
  # The run-stop measurements of a finished context.
  @spec context_measurements(Context.t()) :: map()
  def context_measurements(%Context{usage: usage, iteration: iteration}) do
    %{
      total_tokens: usage.total_tokens,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      tool_calls: usage.tool_calls,
      requests: usage.requests,
      iterations: iteration
    }
  end

  @doc false
  # `[:nous, :agent, :run, :exception]`. `stacktrace` is the real one when the
  # run raised, and `[]` when it returned `{:error, reason}` (no stack exists).
  @spec run_exception(Nous.Agent.t(), map(), integer(), atom(), term(), list()) :: :ok
  def run_exception(agent, run_scope, start_time, kind, reason, stacktrace) do
    terminal_once(run_scope, fn ->
      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      Logger.error("""
      Agent run failed: #{agent.name}
        Duration: #{duration_ms}ms
        Error: #{inspect(reason)}
      """)

      :telemetry.execute(
        [:nous, :agent, :run, :exception],
        %{duration: duration},
        RunScope.merge(%{
          agent_name: agent.name,
          model_provider: agent.model.provider,
          model_name: agent.model.model,
          kind: kind,
          reason: reason,
          stacktrace: stacktrace
        })
      )
    end)
  end

  defp terminal_once(%{agent_run_id: run_id}, fun) do
    key = {@terminal_key, run_id}

    unless Process.get(key) do
      Process.put(key, true)
      fun.()
    end

    :ok
  end

  @doc false
  # Forget the terminal marker of `run_scope` in this process. For a stream
  # run, whose events fire in the enumerating process after `scoped/2` has
  # returned.
  @spec clear_terminal(map()) :: :ok
  def clear_terminal(%{agent_run_id: run_id}) do
    Process.delete({@terminal_key, run_id})
    :ok
  end

  @doc false
  @spec terminal?(map()) :: boolean()
  def terminal?(%{agent_run_id: run_id}), do: Process.get({@terminal_key, run_id}) == true

  # ── structured output ──────────────────────────────────────────────────────

  @doc false
  @spec structured_output_retry(Nous.Agent.t(), pos_integer(), non_neg_integer(), String.t()) ::
          :ok
  def structured_output_retry(agent, attempt, retries_left, errors) do
    :telemetry.execute(
      [:nous, :agent, :structured_output, :retry],
      %{retries_left: retries_left},
      RunScope.merge(%{agent_name: agent.name, attempt: attempt, errors: errors})
    )
  end

  # ── model span ─────────────────────────────────────────────────────────────

  @doc false
  # `[:nous, :agent, :model, :start]`. Returns the span state `model_stop/4`
  # and `model_exception/3` take.
  @spec model_start(map()) :: map()
  def model_start(%{agent_name: _, iteration: _, model: model} = request) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:nous, :agent, :model, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      RunScope.merge(%{
        agent_name: request.agent_name,
        iteration: request.iteration,
        model_provider: model.provider,
        model_name: model.model,
        stream: request.stream,
        tool_names: Enum.map(request.tools, & &1.name),
        blocked_tool_names: request.blocked_tool_names,
        messages: request.messages
      })
    )

    Map.put(request, :start_time, start_time)
  end

  @doc false
  # `[:nous, :agent, :model, :stop]` for `response`, answered by
  # `active_model`. `first_token_at` is the monotonic time the first streamed
  # chunk arrived (nil for a non-streamed request).
  @spec model_stop(map(), Message.t(), Nous.Model.t(), integer() | nil) :: :ok
  def model_stop(span, %Message{} = response, active_model, first_token_at) do
    usage = (response.metadata || %{}) |> Map.get(:usage) |> usage_map()
    tool_calls = response.tool_calls || []

    measurements =
      usage
      |> Map.merge(%{
        duration: System.monotonic_time() - span.start_time,
        tool_calls: length(tool_calls)
      })
      |> maybe_put_ttft(span.start_time, first_token_at)

    :telemetry.execute(
      [:nous, :agent, :model, :stop],
      measurements,
      RunScope.merge(%{
        agent_name: span.agent_name,
        iteration: span.iteration,
        model_provider: span.model.provider,
        model_name: span.model.model,
        active_model_provider: active_model.provider,
        active_model_name: active_model.model,
        fallback_used: active_model != span.model,
        finish_reason: Map.get(response.metadata || %{}, :finish_reason),
        requested_tool_calls:
          Enum.map(tool_calls, fn call ->
            %{
              tool_call_id: ToolCall.field(call, :id),
              tool_name: ToolCall.clean_name(ToolCall.field(call, :name))
            }
          end),
        response: response
      })
    )
  end

  @doc false
  @spec model_exception(map(), atom(), term()) :: :ok
  def model_exception(span, kind, reason) do
    :telemetry.execute(
      [:nous, :agent, :model, :exception],
      %{duration: System.monotonic_time() - span.start_time},
      RunScope.merge(%{
        agent_name: span.agent_name,
        iteration: span.iteration,
        model_provider: span.model.provider,
        model_name: span.model.model,
        kind: kind,
        reason: reason
      })
    )
  end

  @usage_keys [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens
  ]

  # Measurements named after the `%Nous.Usage{}` fields; a provider that
  # reported none (or a non-integer) contributes 0.
  defp usage_map(usage) when is_map(usage) do
    Map.new(@usage_keys, fn key ->
      case Map.get(usage, key) do
        n when is_integer(n) -> {key, n}
        _ -> {key, 0}
      end
    end)
  end

  defp usage_map(_none), do: Map.new(@usage_keys, &{&1, 0})

  defp maybe_put_ttft(measurements, start_time, first_token_at) when is_integer(first_token_at),
    do: Map.put(measurements, :time_to_first_token, max(first_token_at - start_time, 0))

  defp maybe_put_ttft(measurements, _start_time, _none), do: measurements

  # ── tool-call span ─────────────────────────────────────────────────────────

  @doc false
  # `[:nous, :agent, :tool_call, :start]` for one call the model requested.
  # `iteration` is the model request that asked for it (the same number as
  # that request's model span). Returns the span state for `tool_call_stop/2`.
  @spec tool_call_start(map(), String.t() | nil, non_neg_integer()) :: map()
  def tool_call_start(call, agent_name, iteration) do
    start_time = System.monotonic_time()
    call_id = ToolCall.field(call, :id)
    tool_name = ToolCall.clean_name(ToolCall.field(call, :name))

    :telemetry.execute(
      [:nous, :agent, :tool_call, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      RunScope.merge(%{
        agent_name: agent_name,
        tool_call_id: call_id,
        tool_name: tool_name,
        arguments: ToolCall.field(call, :arguments),
        iteration: iteration
      })
    )

    %{start_time: start_time, agent_name: agent_name, tool_call_id: call_id, tool_name: tool_name}
  end

  @doc false
  # `[:nous, :agent, :tool_call, :stop]`. `info` carries `:outcome`,
  # `:approval`, `:result` and optionally `:result_modified`, `:error` and,
  # when `approval: :edited`, the post-edit `:arguments`.
  @spec tool_call_stop(map(), map()) :: :ok
  def tool_call_stop(span, %{outcome: outcome, approval: approval} = info) do
    metadata =
      RunScope.merge(%{
        agent_name: span.agent_name,
        tool_call_id: span.tool_call_id,
        tool_name: span.tool_name,
        outcome: outcome,
        approval: approval,
        result: Map.get(info, :result),
        result_modified: Map.get(info, :result_modified, false),
        error: Map.get(info, :error)
      })

    metadata =
      if approval == :edited, do: Map.put(metadata, :arguments, info.arguments), else: metadata

    :telemetry.execute(
      [:nous, :agent, :tool_call, :stop],
      %{duration: System.monotonic_time() - span.start_time},
      metadata
    )
  end
end
