defmodule Nous.Workflow.Telemetry do
  @moduledoc """
  Telemetry events for workflow execution.

  ## Workflow Events

    * `[:nous, :workflow, :run, :start]` — workflow begins
      * Measurement: `%{system_time: integer}`
      * Metadata: `%{workflow_id: string, workflow_name: string, node_count: integer}`

    * `[:nous, :workflow, :run, :stop]` — workflow completes
      * Measurement: `%{duration: integer}`
      * Metadata: `%{workflow_id: string, status: atom, nodes_executed: integer}`

    * `[:nous, :workflow, :run, :exception]` — workflow fails
      * Measurement: `%{duration: integer}`
      * Metadata: `%{workflow_id: string, reason: term}`

  ## Node Events

    * `[:nous, :workflow, :node, :start]` — node begins
      * Measurement: `%{system_time: integer}`
      * Metadata: `%{workflow_id: string, node_id: string, node_type: atom}`

    * `[:nous, :workflow, :node, :stop]` — node completes
      * Measurement: `%{duration: integer}`
      * Metadata: `%{workflow_id: string, node_id: string, node_type: atom, success: boolean}`

    * `[:nous, :workflow, :node, :exception]` — node fails
      * Measurement: `%{duration: integer}`
      * Metadata: `%{workflow_id: string, node_id: string, node_type: atom, reason: term}`
  """

  @doc false
  def workflow_start(workflow_id, workflow_name, node_count) do
    :telemetry.execute(
      [:nous, :workflow, :run, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{workflow_id: workflow_id, workflow_name: workflow_name, node_count: node_count}
    )
  end

  @doc false
  def workflow_stop(workflow_id, start_time, status, nodes_executed) do
    :telemetry.execute(
      [:nous, :workflow, :run, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, status: status, nodes_executed: nodes_executed}
    )
  end

  @doc false
  def workflow_exception(workflow_id, start_time, reason) do
    :telemetry.execute(
      [:nous, :workflow, :run, :exception],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, reason: reason}
    )
  end

  @doc false
  def node_start(workflow_id, node_id, node_type) do
    :telemetry.execute(
      [:nous, :workflow, :node, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type}
    )
  end

  @doc false
  def node_stop(workflow_id, node_id, node_type, start_time, success) do
    :telemetry.execute(
      [:nous, :workflow, :node, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type, success: success}
    )
  end

  @doc false
  def node_exception(workflow_id, node_id, node_type, start_time, reason) do
    :telemetry.execute(
      [:nous, :workflow, :node, :exception],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type, reason: reason}
    )
  end
end
