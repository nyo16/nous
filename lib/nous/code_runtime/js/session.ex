defmodule Nous.CodeRuntime.JS.Session do
  @moduledoc false

  # One run: one fresh tyrex runtime, one program, one `%Result{}`.
  #
  # ## Why the session and the eval are two processes
  #
  # `Tyrex.eval/2` is a `GenServer.call`, so whoever calls it is blocked until
  # the program finishes. The bridge has to reach a *responsive* process while
  # the program runs - that is the entire ticket protocol - so the session
  # cannot be the caller. The session therefore owns state and serves the
  # bridge; a task calls `eval` and reports back.
  #
  # ## Why the deadline lives here and not in tyrex
  #
  # tyrex's own `timeout:` covers JavaScript execution and terminates the
  # isolate when it expires, which is real: a sleeping program dies at 702ms
  # under a 700ms deadline (measured). What it does NOT cover is bridge time,
  # because an allowlisted MFA runs inline on the runtime's message loop and the
  # deadline message waits behind it. Tool calls are bridge time. So a program
  # that calls a slow tool in a loop would run past any eval deadline, and the
  # authoritative wall clock has to be a BEAM timer in a process the guest
  # cannot influence at all. tyrex's timeout stays armed as an inner guard with
  # slack over ours, so whichever fires first, the run dies and the message
  # names the right cause.
  #
  # ## Fresh runtime per run
  #
  # No pooling, so no cross-run state survives: not a mutated prototype, not a
  # cached module, not a `globalThis` the previous program wrote to. That costs
  # 172ms (measured, median 174ms over 12 runs, min 172ms), which is why it is
  # affordable here and was not on the wasm path the spike rejected at 1900ms
  # per run with no amortisation available.

  use GenServer, restart: :temporary

  require Logger

  alias Nous.CodeRuntime.{Failure, Request, Result}
  alias Nous.CodeRuntime.JS.{Bridge, Prelude}

  @enforce_keys [:request, :config, :ref]
  defstruct [
    :request,
    :config,
    :ref,
    :runtime,
    :eval_task,
    :deadline_timer,
    :functions,
    logs: [],
    log_bytes: 0,
    log_lines: 0,
    log_truncated: false,
    expected_logs: nil,
    pending_outcome: nil,
    tickets: %{},
    finished: false
  ]

  @doc false
  def start_link({%Request{} = request, config, ref}) do
    GenServer.start_link(__MODULE__, {request, config, ref})
  end

  @doc false
  @spec submit(pid(), String.t(), map(), timeout()) :: map()
  def submit(session, tool, args, timeout) do
    guarded(fn -> GenServer.call(session, {:submit, tool, args}, timeout) end)
  end

  @doc false
  @spec poll(pid(), [String.t()], timeout()) :: map()
  def poll(session, tickets, timeout) do
    guarded(fn -> GenServer.call(session, {:poll, tickets}, timeout) end)
  end

  @doc false
  @spec log(pid(), String.t(), String.t(), timeout()) :: map()
  def log(session, stream, line, timeout) do
    guarded(fn -> GenServer.call(session, {:log, stream, line}, timeout) end)
  end

  @doc false
  @spec cancel(pid(), term()) :: :ok
  def cancel(session, reason) do
    if Process.alive?(session), do: GenServer.cast(session, {:cancel, reason})
    :ok
  end

  # The bridge runs on tyrex's message loop; an exit propagating from here would
  # take the runtime down mid-reply and the program would see a hang rather than
  # an error. A dead session means the run is already over, so answering with a
  # substrate error is both true and the shape the guest can read.
  defp guarded(fun) do
    fun.()
  catch
    :exit, _reason ->
      %{"error" => %{"kind" => "substrate", "message" => "the run is no longer active"}}
  end

  @impl true
  def init({request, config, ref}) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{request: request, config: config, ref: ref}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    case start_runtime(state.config) do
      {:ok, runtime} ->
        # Registered under the RUNTIME's pid, because that is what the bridge
        # sees as `self()` when the guest calls in. Registering before the first
        # eval is what makes the lookup an authorization check rather than a
        # race: a runtime with no registration has no tools.
        {:ok, _} = Registry.register(Bridge.registry(), runtime, nil)

        {:noreply,
         %{state | runtime: runtime, functions: functions(state.request)}
         |> arm_deadline()
         |> start_eval()}

      {:error, message} ->
        {:stop, {:shutdown, {:substrate, message}}, state}
    end
  end

  @impl true
  def handle_call({:submit, tool, args}, _from, state) do
    case Map.fetch(state.functions, tool) do
      {:ok, fun} ->
        ticket = Integer.to_string(System.unique_integer([:positive, :monotonic]))
        task = run_tool(ticket, fun, args)
        {:reply, %{"ticket" => ticket}, put_in(state.tickets[task.ref], {ticket, :pending})}

      :error ->
        # A program can only reach a name the prelude declared, so an unknown
        # one means the tool set changed under us or the program built a call
        # some other way. Denied tools are present as stubs, so this is not the
        # permission path.
        {:reply, tool_error(tool, "unknown tool"), state}
    end
  end

  def handle_call({:poll, tickets}, _from, state) do
    wanted = MapSet.new(tickets)

    {done, remaining} =
      Enum.reduce(state.tickets, {%{}, %{}}, fn
        {ref, {ticket, {:done, outcome}}}, {done, keep} ->
          if MapSet.member?(wanted, ticket) do
            {Map.put(done, ticket, outcome), keep}
          else
            {done, Map.put(keep, ref, {ticket, {:done, outcome}})}
          end

        {ref, entry}, {done, keep} ->
          {done, Map.put(keep, ref, entry)}
      end)

    {:reply, %{"done" => done}, %{state | tickets: remaining}}
  end

  def handle_call({:log, stream, line}, _from, state) do
    state = append_log(state, stream, line)

    # If this was the line the drain was waiting for, finish now rather than
    # sitting out the rest of the window: a run that has said everything it is
    # going to say should not add latency to the model's turn.
    if state.pending_outcome && pending_logs(state.pending_outcome, state) == 0 do
      send(self(), :drain_expired)
    end

    {:reply, %{"ok" => true}, state}
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    {:stop, {:shutdown, {:cancelled, reason}}, finish(state, cancelled(reason, state.logs))}
  end

  # A tool task finished. The outcome is parked against its ticket rather than
  # pushed to the guest, because there is no way to push into a running isolate:
  # the guest asks. Parking is bounded by the ticket count, which the program
  # controls but the deadline bounds.
  @impl true
  def handle_info({ref, outcome}, state) when is_map_key(state.tickets, ref) do
    Process.demonitor(ref, [:flush])
    {ticket, _} = Map.fetch!(state.tickets, ref)
    {:noreply, put_in(state.tickets[ref], {ticket, {:done, outcome}})}
  end

  # A tool crashed rather than returning. The program still gets an error it can
  # catch, carrying the tool name and nothing else - a stacktrace or an internal
  # struct reaching model-authored code is an information leak, and the detail
  # belongs in the operator's log.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tickets, ref) do
    {ticket, _} = Map.fetch!(state.tickets, ref)
    Logger.error("Code run sub-call crashed: #{inspect(reason)}")

    outcome = %{"ok" => false, "error" => %{"tool" => nil, "message" => "tool call failed"}}
    {:noreply, put_in(state.tickets[ref], {ticket, {:done, outcome}})}
  end

  # `console.log` is fire-and-forget by design, so when a program returns there
  # can still be log ops queued in the runtime's mailbox that have not reached
  # this process yet. Finishing immediately would silently drop them - measured:
  # a program emitting 500 lines and returning at once arrived here with a
  # fraction of them, and killing the runtime then produced one
  # "execution terminated" error per undelivered reply.
  #
  # That is what the envelope's log count is for: the guest reports how many
  # lines it emitted, so this side knows whether it has seen them all and can
  # wait for the remainder. The wait is bounded and only ever delays a run that
  # genuinely has output in flight.
  def handle_info({:eval, outcome}, state) do
    if pending_logs(outcome, state) == 0 do
      {:stop, :normal, finish(state, result_from(outcome, state))}
    else
      Process.send_after(self(), :drain_expired, drain_ms(state.config))
      {:noreply, %{state | expected_logs: expected_count(outcome), pending_outcome: outcome}}
    end
  end

  # The drain window closed with lines still missing. Report what arrived and
  # say so, rather than pretending the transcript is complete: an operator
  # reading a truncated transcript needs to know it is truncated.
  def handle_info(:drain_expired, %{pending_outcome: outcome} = state) when outcome != nil do
    missing = pending_logs(outcome, state)

    state =
      if missing > 0,
        do: append_notice(state, "[#{missing} log line(s) were still in flight and are missing]"),
        else: state

    {:stop, :normal, finish(state, result_from(outcome, state))}
  end

  def handle_info(:deadline, state) do
    # Kill before reporting, so the deadline is a stop and not just a caller
    # giving up. See `kill_runtime/1` for why this is a real one.
    kill_runtime(state)

    {:stop, :normal,
     finish(
       state,
       Result.failed(
         :timeout,
         "the program exceeded its #{timeout_ms(state.config)}ms deadline and was terminated",
         collected_logs(state)
       )
     )}
  end

  # The eval task exiting is expected on every path where we killed the runtime
  # underneath it; the outcome has already been decided by whoever did the
  # killing.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # A session that ends without having answered is a caller left waiting
    # forever, so the owner is told even on an abnormal exit. `finish/2` is
    # idempotent via the `finished` flag.
    finish(state, Result.failed(:substrate_exit, "the run ended without a result", state.logs))
    release_runtime(state)
    :ok
  end

  # ---------------------------------------------------------------------------

  defp start_runtime(config) do
    opts = [
      permissions: Keyword.get(config, :permissions, :none),
      apply: Bridge.allowlist(),
      max_heap_mb: Keyword.fetch!(config, :max_heap_mb)
    ]

    case Tyrex.start(opts) do
      {:ok, runtime} ->
        {:ok, runtime}

      {:error, reason} ->
        {:error, "could not start a JS runtime: #{inspect(reason)}"}
    end
  end

  defp start_eval(state) do
    program =
      Prelude.render(state.request.bindings, state.request.program,
        bridge_module: inspect(Bridge),
        poll_backoff_ms: Keyword.fetch!(state.config, :poll_backoff_ms)
      )

    session = self()
    runtime = state.runtime

    # Slack over our own deadline so ours fires first and reports the cause in
    # our words. tyrex's timeout is the inner guard for the case where the
    # session itself is wedged.
    eval_timeout = timeout_ms(state.config) + 5_000

    task =
      Task.async(fn ->
        send(session, {:eval, Tyrex.eval(program, pid: runtime, timeout: eval_timeout)})
      end)

    %{state | eval_task: task}
  end

  defp run_tool(_ticket, fun, args) do
    Task.async(fn ->
      case fun.(args) do
        {:ok, value} -> %{"ok" => true, "value" => value}
        {:error, payload} -> %{"ok" => false, "error" => normalize_error(payload)}
      end
    end)
  end

  # The binding closure already returns the two-string payload Code Mode
  # promises a program. This only guarantees the shape, because a closure that
  # returned something else would otherwise reach the guest as arbitrary
  # internal data.
  defp normalize_error(%{"tool" => tool, "message" => message} = payload)
       when is_binary(message) do
    %{"tool" => tool, "message" => message, "kind" => Map.get(payload, "kind")}
  end

  defp normalize_error(other) do
    Logger.error("Code run sub-call returned an unreadable error: #{inspect(other)}")
    %{"tool" => nil, "message" => "tool call failed"}
  end

  defp tool_error(tool, message) do
    %{"ok" => false, "error" => %{"tool" => tool, "message" => message}}
  end

  defp functions(%Request{bindings: bindings}) do
    Enum.reduce(bindings, %{}, fn binding, acc -> Map.merge(acc, binding.functions) end)
  end

  defp arm_deadline(state) do
    %{state | deadline_timer: Process.send_after(self(), :deadline, timeout_ms(state.config))}
  end

  # How many lines the guest says it emitted but this process has not seen.
  #
  # Both envelopes carry a count - a program that threw still reported what it
  # had logged - so a failing run drains its output too. What has no count is a
  # run the *substrate* ended (deadline, heap limit, dead runtime): there is no
  # envelope at all, nothing to wait for, and the logs are whatever arrived
  # before the kill.
  defp pending_logs(outcome, state) do
    case expected_count(outcome) do
      nil -> 0
      count -> max(count - state.log_lines, 0)
    end
  end

  defp expected_count({:ok, %{"logs" => count}}) when is_integer(count) and count >= 0, do: count
  defp expected_count(_outcome), do: nil

  # Deliberately short. This is teardown latency on the happy path, paid only
  # when lines are genuinely in flight, and the alternative to a bound is a run
  # that hangs because the guest miscounted.
  defp drain_ms(config), do: Keyword.get(config, :log_drain_ms, 250)

  # A notice is accounted like any other line but never suppressed by the
  # ledger: if output was truncated or lost, that fact is the one thing the
  # operator must not have truncated away.
  defp append_notice(state, notice) do
    %{state | logs: [notice | state.logs], log_lines: state.log_lines + 1}
  end

  # Byte-accurate, and accounted before the line is kept rather than after, so
  # the limit is a limit and not a suggestion. The fitting prefix is retained:
  # the first lines of output are the ones that explain what the program was
  # doing, and dropping everything on overflow would punish the operator for the
  # program's last mistake.
  #
  # `log_lines` counts every line the guest EMITTED, including ones dropped by
  # the limit. It is what the drain compares against the guest's own count, and
  # counting only retained lines would make a truncated run wait out the whole
  # drain window for lines it is deliberately discarding.
  defp append_log(%{log_truncated: true} = state, _stream, _line) do
    %{state | log_lines: state.log_lines + 1}
  end

  defp append_log(state, stream, line) do
    text = decorate(stream, line)
    size = byte_size(text)
    limit = Keyword.fetch!(state.config, :max_output_bytes)
    state = %{state | log_lines: state.log_lines + 1}

    if state.log_bytes + size > limit do
      %{state | logs: ["[output truncated at #{limit} bytes]" | state.logs], log_truncated: true}
    else
      %{state | logs: [text | state.logs], log_bytes: state.log_bytes + size}
    end
  end

  defp decorate("stderr", line), do: "[stderr] " <> line
  defp decorate(_stdout, line), do: line

  defp collected_logs(state), do: Enum.reverse(state.logs)

  defp result_from({:ok, %{"ok" => true, "value" => value}}, state) do
    Result.ok(value, collected_logs(state))
  end

  # The program threw and the guest unpacked it for us. This is the *normal*
  # failure path for model-authored code, so the model gets its own words back:
  # `TypeError: x is not a function` is what lets it write a better program,
  # where "the program failed" would not.
  defp result_from({:ok, %{"ok" => false, "error" => %{"message" => message} = error}}, state)
       when is_binary(message) do
    name = Map.get(error, "name") || "Error"
    Result.failed(:exception, "#{name}: #{message}", collected_logs(state))
  end

  # A program that returns the wrong envelope did not come from our prelude, so
  # the value cannot be trusted to mean what a caller would read it as.
  defp result_from({:ok, other}, state) do
    Result.failed(
      :invalid_output,
      "the program returned an unexpected shape: #{inspect(other, limit: 5)}",
      collected_logs(state)
    )
  end

  defp result_from({:error, %{name: name} = error}, state) do
    {kind, message} = classify(name, error)
    Result.failed(kind, message, collected_logs(state))
  end

  defp result_from(other, state) do
    Result.failed(:substrate_exit, "the runtime failed: #{inspect(other)}", collected_logs(state))
  end

  # Every tyrex error name maps to a `Failure.kind()` deliberately, so a new
  # upstream name shows up as `:substrate_exit` with its own wording rather than
  # being silently folded into an existing kind.
  defp classify(:timeout, _error),
    do: {:timeout, "the program exceeded its deadline and was terminated"}

  defp classify(:heap_limit_error, _error),
    do: {:abort, "the program exceeded its memory limit and was terminated"}

  defp classify(:execution_error, error), do: {:exception, message_of(error)}
  defp classify(:promise_rejection, error), do: {:exception, message_of(error)}
  defp classify(:dead_runtime_error, _error), do: {:substrate_exit, "the runtime was terminated"}
  defp classify(name, error), do: {:substrate_exit, "#{name}: #{message_of(error)}"}

  defp message_of(%{message: message}) when is_binary(message), do: message
  defp message_of(%{value: value}) when not is_nil(value), do: inspect(value, limit: 10)
  defp message_of(_error), do: "the program failed without a message"

  defp cancelled(reason, logs) do
    Result.failed(:abort, "the run was cancelled: #{inspect(reason)}", Enum.reverse(logs))
  end

  defp finish(%{finished: true} = state, _result), do: state

  # The ref in the message is the exact term `start_run/2` handed back - the
  # `{session, ref}` pair, not the bare ref. `Nous.CodeRuntime.await/2` pins it
  # in a selective receive, so a session that sent anything else would leave
  # every caller waiting out its timeout while the run had in fact succeeded.
  defp finish(state, %Result{} = result) do
    send(state.request.owner, {:code_run, {self(), state.ref}, result})
    %{state | finished: true}
  end

  # Two teardowns, and which one runs is a correctness question, not a style
  # one.
  #
  # `kill_runtime/1` is for a program that is STILL RUNNING: it is an untrappable
  # exit, and the worker's OS thread is reclaimed by the resource's `down`
  # callback. Verified by wedging 20 runtimes - twice this host's dirty
  # scheduler count - and terminating them all, after which a fresh runtime
  # still evaluated in 182ms and 10 concurrent runs completed. A leak would have
  # hung there.
  #
  # `release_runtime/1` is for a program that already returned. The isolate is
  # idle but tyrex may still owe it replies for fire-and-forget log calls, and
  # those replies are executed IN the isolate. Killing there logs one
  # "execution terminated" error per undelivered reply - measured at 116 of them
  # for a 500-line program - so a graceful stop drains the mailbox first. A
  # `GenServer.stop` is ordered behind messages already queued, which is exactly
  # the property being relied on.
  defp release_runtime(%{runtime: nil}), do: :ok

  defp release_runtime(%{runtime: runtime}) do
    if Process.alive?(runtime), do: Tyrex.stop(pid: runtime)
    :ok
  end

  defp kill_runtime(%{runtime: nil}), do: :ok

  defp kill_runtime(%{runtime: runtime}) do
    if Process.alive?(runtime), do: Tyrex.kill(pid: runtime)
    :ok
  end

  defp timeout_ms(config), do: Keyword.fetch!(config, :timeout_ms)

  @doc false
  @spec kinds() :: [Failure.kind()]
  def kinds, do: Failure.kinds()
end
