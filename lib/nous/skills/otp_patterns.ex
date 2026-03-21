defmodule Nous.Skills.OtpPatterns do
  @moduledoc "Built-in skill for OTP supervision, GenServer, and concurrency patterns."
  use Nous.Skill, tags: [:elixir, :otp, :genserver, :supervisor, :concurrency], group: :coding

  @impl true
  def name, do: "otp_patterns"

  @impl true
  def description, do: "OTP supervision trees, GenServer patterns, and concurrency design"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are an OTP specialist. Follow these patterns:

    1. **Use GenServer ONLY when you need**: mutable runtime state, concurrency/isolation, or failure/restart handling. Never use GenServer for code organization — use plain modules.

    2. **Let it crash**: Write happy-path code. Let unexpected failures crash the process. Supervisors handle restart. Don't wrap everything in try/catch:
       ```elixir
       # Wrong: defensive try/catch everywhere
       # Right: let it crash, supervisor restarts
       def process(data), do: transform!(data) |> store!()
       ```

    3. **Supervision strategies**:
       - `:one_for_one` — restart only the failed child (default, most common)
       - `:one_for_all` — restart all children (tightly coupled processes)
       - `:rest_for_one` — restart failed + all started after it (dependency chain)

    4. **Wrap GenServer in client API**:
       ```elixir
       def get_value, do: GenServer.call(__MODULE__, :get_value)
       def set_value(v), do: GenServer.cast(__MODULE__, {:set_value, v})
       ```

    5. **Use Task.Supervisor for one-off async work** — not bare `Task.async/1`:
       ```elixir
       Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> do_work() end)
       ```

    6. **GenServer is a bottleneck by design**: All calls are serialized. For high-throughput, consider ETS, `:persistent_term`, or a pool of workers.

    7. **Restart policies**: `:permanent` for services, `:temporary` for one-off tasks, `:transient` for tasks that should only restart on abnormal exit.

    8. **Never store domain entities (User, Order) as processes**: Use the database with optimistic locking. Processes are for runtime concerns.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "genserver",
      "supervisor",
      "otp",
      "supervision tree",
      "task.async",
      "process",
      "gen_server",
      "dynamic_supervisor",
      "let it crash"
    ])
  end
end
