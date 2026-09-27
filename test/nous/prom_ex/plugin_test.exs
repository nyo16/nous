if Code.ensure_loaded?(PromEx) do
  defmodule Nous.PromEx.PluginTest do
    use ExUnit.Case, async: true

    # Ran nowhere before prom_ex became a declared optional dep (audit D-M2).
    @moduletag :prom_ex

    alias Nous.PromEx.Plugin
    alias PromEx.MetricTypes.Event

    test "event_metrics/1 declares the three documented metric groups" do
      groups = Plugin.event_metrics(otp_app: :my_app)

      assert Enum.map(groups, & &1.group_name) ==
               [:nous_agent_event_metrics, :nous_model_event_metrics, :nous_tool_event_metrics]

      assert Enum.all?(groups, &match?(%Event{}, &1))
    end

    test "metric names are prefixed with the otp_app, or bare :nous without one" do
      [agent | _] = Plugin.event_metrics(otp_app: :my_app)
      assert Enum.all?(agent.metrics, &List.starts_with?(&1.name, [:my_app, :nous, :agent]))

      [agent | _] = Plugin.event_metrics([])
      assert Enum.all?(agent.metrics, &List.starts_with?(&1.name, [:nous, :agent]))

      [agent | _] = Plugin.event_metrics(metric_prefix: [:custom])
      assert Enum.all?(agent.metrics, &List.starts_with?(&1.name, [:custom, :agent]))
    end

    test "every metric listens on a [:nous | _] telemetry event" do
      for group <- Plugin.event_metrics([]), metric <- group.metrics do
        assert [:nous | _] = metric.event_name,
               "#{inspect(metric.name)} listens on #{inspect(metric.event_name)}"
      end
    end

    test "duration histograms take their buckets from the configured unit" do
      [agent_ms | _] = Plugin.event_metrics(duration_unit: :millisecond)
      [agent_s | _] = Plugin.event_metrics(duration_unit: :second)

      ms_buckets =
        agent_ms.metrics
        |> Enum.find(&(&1.__struct__ == Telemetry.Metrics.Distribution))
        |> then(& &1.reporter_options[:buckets])

      s_buckets =
        agent_s.metrics
        |> Enum.find(&(&1.__struct__ == Telemetry.Metrics.Distribution))
        |> then(& &1.reporter_options[:buckets])

      assert List.last(ms_buckets) == 60000
      assert List.last(s_buckets) == 60
    end
  end
end
