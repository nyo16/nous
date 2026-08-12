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

  ## Consuming the events

  Attach a `:telemetry` handler once at boot; nothing in this module needs to
  be called from application code — `Nous.Workflow.Engine` emits every event
  above as it runs a graph.

      :telemetry.attach_many(
        "my-app-workflow-metrics",
        [
          [:nous, :workflow, :run, :stop],
          [:nous, :workflow, :node, :stop]
        ],
        &MyApp.Metrics.handle_workflow_event/4,
        nil
      )

  ## Emitting the events

  The functions below are the emitters `Nous.Workflow.Engine` calls. They are
  public so that a custom engine can produce the same event stream (and so the
  payloads above have a single source of truth), but a workflow built with
  `Nous.Workflow` never needs to call them directly.

  Every `start_time` argument is a `System.monotonic_time/0` reading taken when
  the corresponding `:start` event was emitted — the `:stop` and `:exception`
  events turn it into the `:duration` measurement.
  """

  @typedoc "Monotonic timestamp captured when the matching `:start` event fired."
  @type start_time :: integer()

  @doc """
  Emit `[:nous, :workflow, :run, :start]`.

  Measurements carry both `:system_time` (wall clock, for correlating with
  logs) and `:monotonic_time` — pass the latter back as `start_time` to
  `workflow_stop/4` or `workflow_exception/3`.

  ## Examples

      iex> :telemetry.attach(
      ...>   "doctest-workflow-start",
      ...>   [:nous, :workflow, :run, :start],
      ...>   fn _event, _measurements, metadata, pid -> send(pid, {:telemetry, metadata}) end,
      ...>   self()
      ...> )
      iex> Telemetry.workflow_start("wf_1", "research", 3)
      iex> :telemetry.detach("doctest-workflow-start")
      iex> receive do: ({:telemetry, metadata} -> metadata)
      %{workflow_id: "wf_1", workflow_name: "research", node_count: 3}

  """
  @spec workflow_start(String.t(), String.t() | nil, non_neg_integer()) :: :ok
  def workflow_start(workflow_id, workflow_name, node_count) do
    :telemetry.execute(
      [:nous, :workflow, :run, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{workflow_id: workflow_id, workflow_name: workflow_name, node_count: node_count}
    )
  end

  @doc """
  Emit `[:nous, :workflow, :run, :stop]`.

  `status` is the engine's terminal status for the run (`:completed`,
  `:failed`, `:cancelled`, …) and `nodes_executed` counts the nodes that
  actually ran, not the nodes in the graph.
  """
  @spec workflow_stop(String.t(), start_time(), atom(), non_neg_integer()) :: :ok
  def workflow_stop(workflow_id, start_time, status, nodes_executed) do
    :telemetry.execute(
      [:nous, :workflow, :run, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, status: status, nodes_executed: nodes_executed}
    )
  end

  @doc """
  Emit `[:nous, :workflow, :run, :exception]`.

  Emitted instead of `workflow_stop/4` when the run aborts, so a handler that
  only watches `:stop` will not double-count a failed run.
  """
  @spec workflow_exception(String.t(), start_time(), term()) :: :ok
  def workflow_exception(workflow_id, start_time, reason) do
    :telemetry.execute(
      [:nous, :workflow, :run, :exception],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, reason: reason}
    )
  end

  @doc """
  Emit `[:nous, :workflow, :node, :start]`.

  `node_type` is the `t:Nous.Workflow.Node.node_type/0` of the node about to
  run, which is what makes per-node-kind latency breakdowns possible.
  """
  @spec node_start(String.t(), String.t(), atom()) :: :ok
  def node_start(workflow_id, node_id, node_type) do
    :telemetry.execute(
      [:nous, :workflow, :node, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type}
    )
  end

  @doc """
  Emit `[:nous, :workflow, :node, :stop]`.

  A node that returned an error still stops normally — `success` is `false`
  and no `:exception` event is emitted. Reserve `node_exception/5` for nodes
  that raised or crashed.
  """
  @spec node_stop(String.t(), String.t(), atom(), start_time(), boolean()) :: :ok
  def node_stop(workflow_id, node_id, node_type, start_time, success) do
    :telemetry.execute(
      [:nous, :workflow, :node, :stop],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type, success: success}
    )
  end

  @doc """
  Emit `[:nous, :workflow, :node, :exception]`.

  `reason` is the raised error or exit reason, unwrapped — attach a handler to
  this event to report node crashes without instrumenting each node.
  """
  @spec node_exception(String.t(), String.t(), atom(), start_time(), term()) :: :ok
  def node_exception(workflow_id, node_id, node_type, start_time, reason) do
    :telemetry.execute(
      [:nous, :workflow, :node, :exception],
      %{duration: System.monotonic_time() - start_time},
      %{workflow_id: workflow_id, node_id: node_id, node_type: node_type, reason: reason}
    )
  end
end
