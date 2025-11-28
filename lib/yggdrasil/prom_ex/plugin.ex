if Code.ensure_loaded?(PromEx) do
  defmodule Yggdrasil.PromEx.Plugin do
    @moduledoc """
    PromEx plugin for Yggdrasil AI agent metrics.

    This plugin captures Prometheus metrics for agent execution, model requests,
    and tool execution based on Yggdrasil's telemetry events.

    ## Prerequisites

    This plugin requires PromEx to be available in your project. Add these
    dependencies to your `mix.exs`:

        {:prom_ex, "~> 1.11"},
        {:plug, "~> 1.18"}  # Required by PromEx

    ## Usage

    Add this plugin to your PromEx module:

        defmodule MyApp.PromEx do
          use PromEx, otp_app: :my_app

          @impl true
          def plugins do
            [
              # ... other plugins
              {Yggdrasil.PromEx.Plugin, []}
            ]
          end
        end

    ## Configuration Options

      * `:otp_app` - The OTP application name (optional, defaults to PromEx module setting)
      * `:metric_prefix` - Custom metric prefix (optional, defaults to `[:otp_app, :yggdrasil]`)
      * `:duration_unit` - Time unit for duration metrics: `:second`, `:millisecond`,
        `:microsecond`, or `:nanosecond` (default: `:millisecond`)

    ## Exposed Metric Groups

      * `:yggdrasil_agent_event_metrics` - Agent execution metrics
      * `:yggdrasil_model_event_metrics` - Model request metrics
      * `:yggdrasil_tool_event_metrics` - Tool execution metrics

    ## Metrics

    ### Agent Metrics

      * `yggdrasil_agent_run_duration` - Distribution of agent run durations
      * `yggdrasil_agent_run_tokens_total` - Distribution of total tokens used
      * `yggdrasil_agent_run_input_tokens` - Distribution of input tokens
      * `yggdrasil_agent_run_output_tokens` - Distribution of output tokens
      * `yggdrasil_agent_run_tool_calls` - Distribution of tool calls per run
      * `yggdrasil_agent_run_iterations` - Distribution of iterations per run
      * `yggdrasil_agent_run_exceptions_total` - Counter of agent exceptions

    ### Model Metrics

      * `yggdrasil_model_request_duration` - Distribution of model request durations
      * `yggdrasil_model_request_tokens_total` - Distribution of total tokens per request
      * `yggdrasil_model_request_input_tokens` - Distribution of input tokens per request
      * `yggdrasil_model_request_output_tokens` - Distribution of output tokens per request
      * `yggdrasil_model_request_exceptions_total` - Counter of model request exceptions
      * `yggdrasil_model_stream_connect_duration` - Distribution of stream connection times
      * `yggdrasil_model_stream_exceptions_total` - Counter of stream exceptions

    ### Tool Metrics

      * `yggdrasil_tool_execution_duration` - Distribution of tool execution durations
      * `yggdrasil_tool_execution_attempts` - Distribution of attempts per execution
      * `yggdrasil_tool_execution_exceptions_total` - Counter of tool exceptions

    """

    use PromEx.Plugin

    alias PromEx.MetricTypes.Event

    @impl true
    def event_metrics(opts) do
      otp_app = Keyword.get(opts, :otp_app)
      metric_prefix = Keyword.get(opts, :metric_prefix, [otp_app, :yggdrasil])
      duration_unit = Keyword.get(opts, :duration_unit, :millisecond)

      [
        agent_metrics(metric_prefix, duration_unit),
        model_metrics(metric_prefix, duration_unit),
        tool_metrics(metric_prefix, duration_unit)
      ]
    end

    defp agent_metrics(metric_prefix, duration_unit) do
      Event.build(
        :yggdrasil_agent_event_metrics,
        [
          distribution(
            metric_prefix ++ [:agent, :run, :duration, duration_unit],
            event_name: [:yggdrasil, :agent, :run, :stop],
            measurement: :duration,
            description: "Duration of agent runs",
            tags: [:agent_name, :model_provider, :model_name],
            tag_values: &agent_tag_values/1,
            unit: {:native, duration_unit},
            reporter_options: [
              buckets: duration_buckets(duration_unit)
            ]
          ),
          distribution(
            metric_prefix ++ [:agent, :run, :tokens, :total],
            event_name: [:yggdrasil, :agent, :run, :stop],
            measurement: :total_tokens,
            description: "Total tokens used per agent run",
            tags: [:agent_name, :model_provider, :model_name],
            tag_values: &agent_tag_values/1,
            reporter_options: [
              buckets: [100, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100_000]
            ]
          ),
          distribution(
            metric_prefix ++ [:agent, :run, :tokens, :input],
            event_name: [:yggdrasil, :agent, :run, :stop],
            measurement: :input_tokens,
            description: "Input tokens per agent run",
            tags: [:agent_name, :model_provider, :model_name],
            tag_values: &agent_tag_values/1,
            reporter_options: [
              buckets: [100, 500, 1000, 2500, 5000, 10000, 25000, 50000]
            ]
          ),
          distribution(
            metric_prefix ++ [:agent, :run, :tokens, :output],
            event_name: [:yggdrasil, :agent, :run, :stop],
            measurement: :output_tokens,
            description: "Output tokens per agent run",
            tags: [:agent_name, :model_provider, :model_name],
            tag_values: &agent_tag_values/1,
            reporter_options: [
              buckets: [50, 100, 250, 500, 1000, 2500, 5000, 10000]
            ]
          ),
          distribution(
            metric_prefix ++ [:agent, :run, :tool_calls],
            event_name: [:yggdrasil, :agent, :run, :stop],
            measurement: :tool_calls,
            description: "Number of tool calls per agent run",
            tags: [:agent_name, :model_provider, :model_name],
            tag_values: &agent_tag_values/1,
            reporter_options: [
              buckets: [0, 1, 2, 5, 10, 20, 50]
            ]
          ),
          distribution(
            metric_prefix ++ [:agent, :run, :iterations],
            event_name: [:yggdrasil, :agent, :run, :stop],
            measurement: :iterations,
            description: "Number of iterations per agent run",
            tags: [:agent_name, :model_provider, :model_name],
            tag_values: &agent_tag_values/1,
            reporter_options: [
              buckets: [1, 2, 3, 5, 10, 15, 20]
            ]
          ),
          counter(
            metric_prefix ++ [:agent, :run, :exceptions, :total],
            event_name: [:yggdrasil, :agent, :run, :exception],
            description: "Total number of agent run exceptions",
            tags: [:agent_name, :model_provider, :error_kind],
            tag_values: &agent_exception_tag_values/1
          )
        ]
      )
    end

    defp model_metrics(metric_prefix, duration_unit) do
      Event.build(
        :yggdrasil_model_event_metrics,
        [
          distribution(
            metric_prefix ++ [:model, :request, :duration, duration_unit],
            event_name: [:yggdrasil, :model, :request, :stop],
            measurement: :duration,
            description: "Duration of model API requests",
            tags: [:provider, :model_name, :has_tool_calls],
            tag_values: &model_tag_values/1,
            unit: {:native, duration_unit},
            reporter_options: [
              buckets: duration_buckets(duration_unit)
            ]
          ),
          distribution(
            metric_prefix ++ [:model, :request, :tokens, :total],
            event_name: [:yggdrasil, :model, :request, :stop],
            measurement: :total_tokens,
            description: "Total tokens per model request",
            tags: [:provider, :model_name],
            tag_values: &model_tag_values/1,
            reporter_options: [
              buckets: [100, 500, 1000, 2500, 5000, 10000, 25000]
            ]
          ),
          distribution(
            metric_prefix ++ [:model, :request, :tokens, :input],
            event_name: [:yggdrasil, :model, :request, :stop],
            measurement: :input_tokens,
            description: "Input tokens per model request",
            tags: [:provider, :model_name],
            tag_values: &model_tag_values/1,
            reporter_options: [
              buckets: [100, 500, 1000, 2500, 5000, 10000]
            ]
          ),
          distribution(
            metric_prefix ++ [:model, :request, :tokens, :output],
            event_name: [:yggdrasil, :model, :request, :stop],
            measurement: :output_tokens,
            description: "Output tokens per model request",
            tags: [:provider, :model_name],
            tag_values: &model_tag_values/1,
            reporter_options: [
              buckets: [50, 100, 250, 500, 1000, 2500, 5000]
            ]
          ),
          counter(
            metric_prefix ++ [:model, :request, :exceptions, :total],
            event_name: [:yggdrasil, :model, :request, :exception],
            description: "Total number of model request exceptions",
            tags: [:provider, :model_name, :error_kind],
            tag_values: &model_exception_tag_values/1
          ),
          distribution(
            metric_prefix ++ [:model, :stream, :connect, :duration, duration_unit],
            event_name: [:yggdrasil, :model, :stream, :connected],
            measurement: :duration,
            description: "Time to establish streaming connection",
            tags: [:provider, :model_name],
            tag_values: &model_tag_values/1,
            unit: {:native, duration_unit},
            reporter_options: [
              buckets: duration_buckets(duration_unit)
            ]
          ),
          counter(
            metric_prefix ++ [:model, :stream, :exceptions, :total],
            event_name: [:yggdrasil, :model, :stream, :exception],
            description: "Total number of stream exceptions",
            tags: [:provider, :model_name, :error_kind],
            tag_values: &model_exception_tag_values/1
          )
        ]
      )
    end

    defp tool_metrics(metric_prefix, duration_unit) do
      Event.build(
        :yggdrasil_tool_event_metrics,
        [
          distribution(
            metric_prefix ++ [:tool, :execution, :duration, duration_unit],
            event_name: [:yggdrasil, :tool, :execute, :stop],
            measurement: :duration,
            description: "Duration of tool executions",
            tags: [:tool_name, :success],
            tag_values: &tool_tag_values/1,
            unit: {:native, duration_unit},
            reporter_options: [
              buckets: duration_buckets(duration_unit)
            ]
          ),
          distribution(
            metric_prefix ++ [:tool, :execution, :attempts],
            event_name: [:yggdrasil, :tool, :execute, :stop],
            measurement: :attempt,
            description: "Number of attempts for tool execution",
            tags: [:tool_name, :success],
            tag_values: &tool_tag_values/1,
            reporter_options: [
              buckets: [1, 2, 3, 4, 5]
            ]
          ),
          counter(
            metric_prefix ++ [:tool, :execution, :exceptions, :total],
            event_name: [:yggdrasil, :tool, :execute, :exception],
            description: "Total number of tool execution exceptions",
            tags: [:tool_name, :will_retry, :error_kind],
            tag_values: &tool_exception_tag_values/1
          )
        ]
      )
    end

    # Tag value extractors

    defp agent_tag_values(metadata) do
      %{
        agent_name: metadata.agent_name,
        model_provider: to_string(metadata.model_provider),
        model_name: metadata.model_name
      }
    end

    defp agent_exception_tag_values(metadata) do
      %{
        agent_name: metadata.agent_name,
        model_provider: to_string(metadata.model_provider),
        error_kind: to_string(metadata.kind)
      }
    end

    defp model_tag_values(metadata) do
      base = %{
        provider: to_string(metadata.provider),
        model_name: metadata.model_name
      }

      if Map.has_key?(metadata, :has_tool_calls) do
        Map.put(base, :has_tool_calls, to_string(metadata.has_tool_calls))
      else
        base
      end
    end

    defp model_exception_tag_values(metadata) do
      %{
        provider: to_string(metadata.provider),
        model_name: metadata.model_name,
        error_kind: to_string(metadata.kind)
      }
    end

    defp tool_tag_values(metadata) do
      %{
        tool_name: metadata.tool_name,
        success: to_string(metadata.success)
      }
    end

    defp tool_exception_tag_values(metadata) do
      %{
        tool_name: metadata.tool_name,
        will_retry: to_string(metadata.will_retry),
        error_kind: normalize_error_kind(metadata.kind)
      }
    end

    defp normalize_error_kind(kind) when is_atom(kind), do: to_string(kind)
    defp normalize_error_kind(kind), do: inspect(kind)

    # Duration buckets based on time unit
    defp duration_buckets(:second) do
      [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60]
    end

    defp duration_buckets(:millisecond) do
      [10, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000]
    end

    defp duration_buckets(:microsecond) do
      [1000, 5000, 10000, 50000, 100_000, 500_000, 1_000_000, 5_000_000, 10_000_000]
    end

    defp duration_buckets(:nanosecond) do
      [
        1_000_000,
        5_000_000,
        10_000_000,
        50_000_000,
        100_000_000,
        500_000_000,
        1_000_000_000
      ]
    end
  end
else
  defmodule Yggdrasil.PromEx.Plugin do
    @moduledoc """
    PromEx plugin for Yggdrasil AI agent metrics.

    To use this plugin, add `{:prom_ex, "~> 1.11"}` and `{:plug, "~> 1.18"}` to your dependencies.
    """

    def event_metrics(_opts) do
      raise "PromEx is not available. Add {:prom_ex, \"~> 1.11\"} and {:plug, \"~> 1.18\"} to your dependencies."
    end
  end
end
