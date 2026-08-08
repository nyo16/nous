defmodule Nous.TaskSupervisorSaturation do
  @moduledoc false
  # Drives `Nous.TaskSupervisor` into its `:max_children` ceiling so the refusal
  # paths behind `Nous.Tasks` can be exercised. The ceiling is 1_000 in
  # production (see `Nous.Application`) — near-unreachable, which is exactly why
  # its consequences need a test rather than an argument.
  #
  # DynamicSupervisor exposes no runtime setter for `:max_children` and the
  # supervisor belongs to the application, so this reaches into its state: drop
  # the ceiling to one slot above whatever is live, then take that slot.
  #
  # ONLY safe from an `async: false` module. While the ceiling is down, every
  # spawn under `Nous.TaskSupervisor` anywhere in the VM is refused, so a test
  # running concurrently would fail for a reason that has nothing to do with it.
  # Both the ceiling and the blocker are undone in `on_exit`.

  import ExUnit.Callbacks, only: [on_exit: 1]

  def saturate! do
    previous = :sys.get_state(Nous.TaskSupervisor).max_children
    active = DynamicSupervisor.count_children(Nous.TaskSupervisor).active

    :sys.replace_state(Nous.TaskSupervisor, &%{&1 | max_children: active + 1})
    on_exit(fn -> :sys.replace_state(Nous.TaskSupervisor, &%{&1 | max_children: previous}) end)

    blocker =
      Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn -> Process.sleep(:infinity) end)

    on_exit(fn -> Process.exit(blocker.pid, :kill) end)
    :ok
  end
end
