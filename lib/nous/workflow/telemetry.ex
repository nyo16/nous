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
  @spec workflow_start(String.t(), String.t(), non_neg_integer()) :: :ok
  def workflow_start(workflow_id, workflow_name, node_count) do
    :telemetry.execute(
      [:nous, :workflow, :run, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{workflow_id: workflow_id, workflow_name: workflow_name, node_count: node_count}
    )
  end

  @doc false
  @spec workflow_stop(String.t(), integer(), atom(), non_neg_integer()) :: :ok
  def workflow_stop(workflow_id, start_time, status, nodes_executed) do
    :telemetry.execute(
      [:nous, :workflow, :run, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, status: status, nodes_executed: nodes_executed}
    )
  end

  @doc false
  @spec workflow_exception(String.t(), integer(), term()) :: :ok
  def workflow_exception(workflow_id, start_time, reason) do
    :telemetry.execute(
      [:nous, :workflow, :run, :exception],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, reason: reason}
    )
  end

  @doc false
  @spec node_start(String.t(), String.t(), Nous.Workflow.Node.node_type()) :: :ok
  def node_start(workflow_id, node_id, node_type) do
    :telemetry.execute(
      [:nous, :workflow, :node, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type}
    )
  end

  @doc false
  @spec node_stop(String.t(), String.t(), Nous.Workflow.Node.node_type(), integer(), boolean()) ::
          :ok
  def node_stop(workflow_id, node_id, node_type, start_time, success) do
    :telemetry.execute(
      [:nous, :workflow, :node, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type, success: success}
    )
  end

  @doc false
  @spec node_exception(
          String.t(),
          String.t(),
          Nous.Workflow.Node.node_type(),
          integer(),
          term()
        ) :: :ok
  def node_exception(workflow_id, node_id, node_type, start_time, reason) do
    :telemetry.execute(
      [:nous, :workflow, :node, :exception],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type, reason: reason}
    )
  end
end
