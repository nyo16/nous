#!/usr/bin/env elixir

# Nous AI - Cancellation
# Stopping agent execution mid-run

IO.puts("=== Nous AI - Cancellation ===\n")

# ============================================================================
# Basic Task Cancellation
# ============================================================================

IO.puts("--- Basic Task Cancellation ---")

defmodule SlowTools do
  def slow_search(_ctx, %{"query" => query}) do
    IO.puts("  Starting search for: #{query}")
    IO.puts("  This takes 10 seconds...")

    Enum.each(1..10, fn i ->
      Process.sleep(1000)
      IO.puts("  ... #{i} seconds elapsed")
    end)

    %{query: query, results: ["Result 1", "Result 2"]}
  end
end

agent =
  Nous.new("lmstudio:qwen3",
    instructions: "You are a research assistant. Use tools to gather information.",
    tools: [&SlowTools.slow_search/2]
  )

IO.puts("Starting agent in background task...")

task =
  Task.async(fn ->
    Nous.run(agent, "Search for 'Elixir programming'")
  end)

# Let it run for 3 seconds
Process.sleep(3000)

IO.puts("\nCancelling after 3 seconds...")
Task.shutdown(task, :brutal_kill)

IO.puts("Task cancelled.\n")

# ============================================================================
# Graceful Cancellation with Timeout
# ============================================================================

IO.puts("--- Graceful Cancellation ---")

IO.puts("""
Use Task.shutdown with timeout for cleanup:

  task = Task.async(fn -> Nous.run(agent, message) end)

  # Allow 5 seconds for graceful shutdown
  case Task.shutdown(task, 5_000) do
    {:ok, result} ->
      # Task completed before shutdown
      handle_result(result)

    nil ->
      # Task was killed after timeout
      IO.puts("Task was forcefully terminated")
  end
""")

# ============================================================================
# Streaming Cancellation
# ============================================================================

IO.puts("--- Streaming Cancellation ---")

IO.puts("""
For streaming, you can stop early by breaking from the stream:

  {:ok, stream} = Nous.run_stream(agent, message)

  stream
  |> Stream.take_while(fn
    {:text_delta, text} ->
      IO.write(text)
      String.length(text) < 1000  # Stop after 1000 chars

    {:finish, _} ->
      false  # Always stop on finish

    _ ->
      true
  end)
  |> Stream.run()
""")

# ============================================================================
# AgentServer Cancellation
# ============================================================================

IO.puts("--- AgentServer Cancellation ---")

IO.puts("""
For production apps, use AgentServer with built-in cancellation:

  # Start server
  {:ok, pid} = Nous.AgentServer.start_link(
    session_id: "user-123",
    agent_config: %{
      model: "lmstudio:qwen3",
      instructions: "You are helpful."
    }
  )

  # Send message (starts execution)
  Nous.AgentServer.send_message(pid, "Do something complex...")

  # Cancel mid-execution
  :ok = Nous.AgentServer.cancel_execution(pid)

  # Handle cancellation event
  def handle_info({:agent_cancelled, reason}, state) do
    IO.puts("Cancelled: \#{reason}")
    {:noreply, state}
  end
""")

# ============================================================================
# LiveView Cancellation
# ============================================================================

IO.puts("--- LiveView Cancellation ---")

IO.puts("""
In Phoenix LiveView, track the task reference:

  def handle_event("send", %{"message" => msg}, socket) do
    task = Task.async(fn ->
      Nous.run(socket.assigns.agent, msg, notify_pid: socket.root_pid)
    end)

    {:noreply, assign(socket, current_task: task, streaming: true)}
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns[:current_task] do
      Task.shutdown(socket.assigns.current_task, :brutal_kill)
    end

    {:noreply, assign(socket,
      current_task: nil,
      streaming: false
    )}
  end

  # In template:
  <%= if @streaming do %>
    <button phx-click="cancel">Stop</button>
  <% end %>
""")

# ============================================================================
# The :cancellation_check Run Option (runnable)
# ============================================================================

IO.puts("--- The :cancellation_check Run Option ---")

# `:cancellation_check` is a 0-arity function passed to `Nous.run/3`. The
# runner calls it before every iteration and, under `stream: true`, between
# streamed chunks. Any return value means "keep going"; throwing
# `{:cancelled, reason}` aborts the run with `%Nous.Errors.ExecutionCancelled{}`.
#
# The first check happens *before* the first model request, so a check that is
# already tripped aborts without any network I/O - which is why this section is
# runnable with no API key and no local model server.

defmodule StopFlag do
  # :atomics is what Nous.AgentServer uses for its own cancel flag: a shared,
  # lock-free cell any process (LiveView, PubSub handler, signal handler) can
  # flip. Slot 1 is the flag, slot 2 counts how often the check ran.
  def new, do: :atomics.new(2, [])

  def stop(ref), do: :atomics.put(ref, 1, 1)

  def stopped?(ref), do: :atomics.get(ref, 1) == 1

  def checks(ref), do: :atomics.get(ref, 2)

  # Build the function handed to Nous.run/3. `allow` lets the first N checks
  # pass, so you can watch the run abort at an iteration boundary instead of
  # before it starts.
  def check(ref, reason, allow \\ 0) do
    fn ->
      :atomics.add(ref, 2, 1)

      if stopped?(ref) and checks(ref) > allow do
        throw({:cancelled, reason})
      end
    end
  end
end

essay_agent = Nous.new("lmstudio:qwen3", instructions: "You are helpful.")

flag = StopFlag.new()

# The user hit "Stop" before the request left the machine.
StopFlag.stop(flag)

IO.puts("Stop flag tripped, then starting the run...")

case Nous.run(essay_agent, "Write a very long essay about Elixir.",
       cancellation_check: StopFlag.check(flag, "user pressed Stop")
     ) do
  {:error, %Nous.Errors.ExecutionCancelled{} = error} ->
    IO.puts("Aborted: #{Exception.message(error)}")
    IO.puts("  reason:            #{inspect(error.reason)}")
    IO.puts("  checks performed:  #{StopFlag.checks(flag)}")
    IO.puts("  model requests:    0 (cancelled before the first one)")

  {:ok, result} ->
    IO.puts("Unexpected completion: #{inspect(result.output)}")

  {:error, other} ->
    IO.puts("Unexpected error: #{inspect(other)}")
end

IO.puts("")

# Same mechanism, flipped mid-flight: the check passes once, so the run
# performs iteration 1 and aborts at the boundary before iteration 2. That
# needs a reachable model, so it is opt-in:
#
#   NOUS_LIVE_CANCEL=1 mix run examples/advanced/cancellation.exs
#
# (set NOUS_MODEL to pick the model; defaults to lmstudio:qwen3)

defmodule ClockTool do
  @doc "Return the current UTC time"
  def now(_ctx, _args), do: %{utc: DateTime.utc_now() |> DateTime.to_iso8601()}
end

if System.get_env("NOUS_LIVE_CANCEL") == "1" do
  live_agent =
    Nous.new(System.get_env("NOUS_MODEL", "lmstudio:qwen3"),
      instructions: "Use the clock tool, then summarise what it returned.",
      tools: [
        Nous.Tool.from_function(&ClockTool.now/2,
          name: "clock",
          description: "Return the current UTC time",
          parameters: %{"type" => "object", "properties" => %{}}
        )
      ]
    )

  live_flag = StopFlag.new()
  StopFlag.stop(live_flag)

  IO.puts("Live run: first check passes, second one cancels...")

  case Nous.run(live_agent, "What time is it?",
         cancellation_check: StopFlag.check(live_flag, "cancelled after one iteration", 1)
       ) do
    {:error, %Nous.Errors.ExecutionCancelled{} = error} ->
      IO.puts("Aborted mid-run: #{Exception.message(error)}")
      IO.puts("  checks performed: #{StopFlag.checks(live_flag)}")

    {:ok, result} ->
      IO.puts("Run finished in one iteration before the second check: #{result.output}")

    {:error, other} ->
      IO.puts("Model unreachable: #{inspect(other)}")
  end
else
  IO.puts("(set NOUS_LIVE_CANCEL=1 to also run the mid-flight cancellation)")
end

IO.puts("")

# ============================================================================
# Cancellation Check in Tools
# ============================================================================

IO.puts("--- Cancellation Check in Tools ---")

IO.puts("""
:cancellation_check only runs between iterations, so a tool that loops for a
long time has to check for itself. Tools are executed in a separate spawned
process (see Nous.ToolExecutor), so the flag must be shared memory - the
caller's process dictionary and mailbox are NOT visible from inside a tool.
Pass the :atomics ref through :deps and read it from ctx.deps:

  # Caller
  cancel_ref = :atomics.new(1, [])

  Nous.run(agent, message,
    deps: %{cancel_ref: cancel_ref},
    cancellation_check: fn ->
      if :atomics.get(cancel_ref, 1) == 1 do
        throw({:cancelled, "user pressed Stop"})
      end
    end
  )

  # Tool: same ref, checked every chunk of work
  def long_running_tool(ctx, _args) do
    cancel_ref = ctx.deps[:cancel_ref]

    Enum.reduce_while(1..100, %{}, fn i, acc ->
      if :atomics.get(cancel_ref, 1) == 1 do
        # Return partial work rather than dying: the model sees the tool
        # result, and the next iteration's :cancellation_check ends the run.
        {:halt, %{cancelled: true, partial: acc}}
      else
        {:cont, Map.put(acc, i, process_item(i))}
      end
    end)
  end

A tool can also bound itself without any flag by setting :timeout on the
Nous.Tool struct - ToolExecutor kills the tool process and raises
%Nous.Errors.ToolTimeout{}.
""")

# ============================================================================
# Timeout vs Cancellation
# ============================================================================

IO.puts("--- Timeout vs Cancellation ---")

IO.puts("""
There is no agent-level timeout: %Nous.Agent{} has no :timeout and no
:tool_timeout field, so those two options are silently dropped by Nous.new/2.
Timeouts and cancellation are three separate knobs:

1. :receive_timeout (automatic, per model request) - lives on the model;
   Nous.new/2 forwards its options to Nous.Model.parse/2:

     agent = Nous.new("openai:gpt-4", receive_timeout: 60_000)

   Defaults: 180_000 for cloud providers and custom:, 120_000 for
   lmstudio/ollama/vllm/sglang, 300_000 for llamacpp. On expiry Nous.run/3
   returns {:error, %Nous.Errors.ProviderError{details:
   %Req.TransportError{reason: :timeout}}}.

2. :timeout (automatic, per tool call) - lives on the Nous.Tool struct,
   default 30_000:

     Nous.Tool.from_function(&SlowTools.slow_search/2, timeout: 5_000)

   On expiry the tool process is killed and the call fails with
   %Nous.Errors.ToolTimeout{tool_name: "slow_search", timeout: 5_000}.

3. :cancellation_check (manual, per iteration) - a 0-arity function given
   to Nous.run/3, throwing {:cancelled, reason} to abort:

     Nous.run(agent, message, cancellation_check: fn ->
       if stopped?(), do: throw({:cancelled, "user pressed Stop"})
     end)

   Returns {:error, %Nous.Errors.ExecutionCancelled{reason: reason}}. It is
   checked before each iteration (and between chunks when stream: true), so
   it bounds the loop by wall clock but cannot interrupt an HTTP request
   already in flight - that is what :receive_timeout is for.

Killing the caller (Task.shutdown/2) is a fourth, blunter option: it stops
the process but the in-flight provider request is not unwound cleanly and no
partial result comes back.

Use the automatic timeouts for:
  - Preventing runaway requests
  - SLA compliance
  - Resource management

Use :cancellation_check for:
  - User-initiated stop
  - Conditional abort
  - Interactive UIs
""")

# ============================================================================
# Best Practices
# ============================================================================

IO.puts("""
--- Best Practices ---

1. Prefer :cancellation_check over killing the caller:
   - The run unwinds cleanly and returns %Nous.Errors.ExecutionCancelled{}
   - Works with a shared :atomics flag from any process

2. Use Task.async when you must abandon the caller:
   - Provides a clean shutdown API
   - Handles cleanup automatically

3. Choose appropriate shutdown mode:
   - :brutal_kill - Immediate termination
   - timeout_ms - Allow graceful cleanup
   - :infinity - Wait forever (not recommended)

4. Save partial results when appropriate:
   - Store streaming output before cancel
   - Mark response as incomplete

5. For production, use AgentServer:
   - Built-in cancellation support
   - PubSub event broadcasting
   - Proper state management

6. In LiveView:
   - Track task reference in assigns
   - Provide cancel button during streaming
   - Handle both completion and cancellation

7. For long-running tools:
   - Periodically check cancellation flag
   - Return early with partial results
   - Clean up resources
""")
