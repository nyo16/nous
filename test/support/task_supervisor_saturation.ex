defmodule Nous.TaskSupervisorSaturation do
  @moduledoc false
  # Drives `Nous.TaskSupervisor` into its `:max_children` ceiling so the refusal
  # paths behind `Nous.Tasks` can be exercised. The ceiling is 1_000 in
  # production (see `Nous.Application`) — near-unreachable, which is exactly why
  # its consequences need a test rather than an argument.
  #
  # WHY THE APPLICATION'S SUPERVISOR AND NOT A PRIVATE ONE
  # `Nous.Tasks` names `Nous.TaskSupervisor` literally at all three of its spawn
  # sites (`tasks.ex:30`, `:40`, `:53`), so the code under test cannot be
  # pointed at a private supervisor without adding a runtime-configurable
  # supervisor name to the library for no reason but this harness. That trade
  # buys nothing: the redirect would be `Application.put_env/3`, every bit as
  # node-global as the ceiling drop below. The choice is not "global versus
  # isolated", it is "which global" — and only one of them keeps every
  # assertion on the real `Nous.Tasks` path. So the shared supervisor stays and
  # the two things that actually made it fragile get fixed: the race, and the
  # silence.
  #
  # DETERMINISM — the ceiling goes to 0, not to `active + 1`
  # A DynamicSupervisor admits a child only while
  # `map_size(children) < max_children` (elixir 1.20,
  # `lib/dynamic_supervisor.ex:742`), so a ceiling of 0 refuses every spawn no
  # matter how many children are live. The previous form read
  # `count_children().active` and then occupied the last slot with a blocker
  # task, so any unrelated child exiting in between freed a slot and the test
  # underneath failed for a reason that had nothing to do with it. Nothing is
  # read now, so nothing can go stale — and there is no blocker task to leak.
  #
  # THE ORDERING ASSUMPTION, NOW ENFORCED
  # While the ceiling is down, every spawn under `Nous.TaskSupervisor` anywhere
  # in the VM is refused, so a concurrently running test would fail for a
  # reason that has nothing to do with it. `async: false` is sufficient only
  # because ExUnit runs every async module to completion before the first sync
  # one. That is the whole assumption, and `use Nous.TaskSupervisorSaturation`
  # now refuses to compile into an `async: true` module rather than leaving it
  # to a comment nobody reads.
  #
  #     defmodule MyRefusalTest do
  #       use ExUnit.Case, async: false
  #       use Nous.TaskSupervisorSaturation
  #
  #       test "…" do
  #         saturate!()
  #       end
  #     end
  #
  # The ceiling is restored in `on_exit`.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @supervisor Nous.TaskSupervisor

  defmacro __using__(_opts) do
    quote do
      @before_compile Nous.TaskSupervisorSaturation
      import Nous.TaskSupervisorSaturation, only: [saturate!: 0]
    end
  end

  # The check has to be deferred to `@before_compile`, not run while
  # `__using__/1` expands: `use ExUnit.Case` sets its `:ex_unit_module`
  # attribute from `ExUnit.Case.__register__/2`, which is an ordinary call in
  # the module body, and Elixir expands the ENTIRE body before evaluating any
  # of it. Measured on 1.20.2 — at expansion time the attribute does not exist
  # yet, so reading it there rejects every caller. By `@before_compile` the
  # body has run and the attribute is there.
  defmacro __before_compile__(env) do
    __refuse_async__!(env.module)
    nil
  end

  @doc false
  @spec __refuse_async__!(module()) :: :ok
  def __refuse_async__!(module) do
    unless Module.has_attribute?(module, :ex_unit_module) do
      raise "#{inspect(module)} uses Nous.TaskSupervisorSaturation without use ExUnit.Case"
    end

    if module |> Module.get_attribute(:ex_unit_module) |> Keyword.get(:async, false) do
      raise """
      #{inspect(module)} is async: true and cannot saturate Nous.TaskSupervisor.

      Saturation drops the ceiling on the application-wide task supervisor, so
      every spawn under it anywhere in the VM is refused while a test holds it.
      That is only safe because ExUnit finishes every async module before it
      starts the first sync one. Declare the module async: false.
      """
    end

    :ok
  end

  @doc false
  @spec saturate!() :: :ok
  def saturate! do
    previous = :sys.get_state(@supervisor).max_children

    :sys.replace_state(@supervisor, &%{&1 | max_children: 0})
    on_exit(fn -> :sys.replace_state(@supervisor, &%{&1 | max_children: previous}) end)

    refuse_probe!()
  end

  # The precondition, asserted rather than assumed. If the supervisor is not
  # actually refusing, nothing downstream proves anything, and it should fail in
  # those words rather than as whatever the caller happened to assert.
  defp refuse_probe! do
    case Task.Supervisor.start_child(@supervisor, fn -> :ok end) do
      {:error, :max_children} ->
        :ok

      {:ok, pid} ->
        Process.exit(pid, :kill)
        raise saturation_failed("it accepted a child")

      other ->
        raise saturation_failed("a probe spawn answered #{inspect(other)}")
    end
  end

  defp saturation_failed(what) do
    "#{inspect(@supervisor)} is not saturated — #{what}. " <>
      "Every saturation assertion below this point proves nothing."
  end
end
