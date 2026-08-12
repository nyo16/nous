defmodule Nous.TelemetryTest do
  # Not async: the default handler is attached globally in :telemetry's table.
  use ExUnit.Case, async: false

  doctest Nous.Telemetry

  describe "attach_default_handler/0" do
    test "attaches once and reports a second attach as already existing" do
      on_exit(fn -> Nous.Telemetry.detach_default_handler() end)

      assert :ok = Nous.Telemetry.attach_default_handler()
      assert {:error, :already_exists} = Nous.Telemetry.attach_default_handler()
    end

    test "the attached handler receives Nous events without crashing" do
      on_exit(fn -> Nous.Telemetry.detach_default_handler() end)
      assert :ok = Nous.Telemetry.attach_default_handler()

      :telemetry.execute([:nous, :tool, :timeout], %{timeout: 1000}, %{tool_name: "bash"})

      # A crashing handler is detached by :telemetry, so still being attached
      # is the assertion that it handled the event.
      assert Enum.any?(
               :telemetry.list_handlers([:nous, :tool, :timeout]),
               &(&1.id == "nous-default-handler")
             )
    end
  end

  describe "detach_default_handler/0" do
    test "reports not_found when nothing is attached" do
      Nous.Telemetry.detach_default_handler()
      assert {:error, :not_found} = Nous.Telemetry.detach_default_handler()
    end
  end
end
