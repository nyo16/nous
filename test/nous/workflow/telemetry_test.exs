defmodule Nous.Workflow.TelemetryTest do
  # async: false — the doctest attaches a global :telemetry handler.
  use ExUnit.Case, async: false

  alias Nous.Workflow.Telemetry

  doctest Nous.Workflow.Telemetry
end
