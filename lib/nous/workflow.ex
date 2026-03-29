defmodule Nous.Workflow do
  @moduledoc """
  DAG/graph-based workflow engine for orchestrating agents, tools, and control flow.

  Workflows define execution graphs where nodes are steps (agent calls, tool
  executions, transformations, branches, parallel fan-outs) and edges define
  the flow between them.

  ## Architecture

  - **Complementary to Decisions**: Decisions track *why* an agent made choices.
    Workflows define *what* executes and *when*.
  - **Complementary to Teams**: Teams manage persistent agent groups.
    Workflows define transient execution plans.
  - **Standalone system**: Not a Behaviour or Plugin — operates above the agent level.

  ## Quick Start

      alias Nous.{Agent, Workflow}

      planner = Agent.new("openai:gpt-4o-mini", instructions: "You are a research planner.")
      searcher = Agent.new("openai:gpt-4o-mini", instructions: "You search for information.")
      reporter = Agent.new("openai:gpt-4o-mini", instructions: "You write reports.")

      workflow =
        Workflow.new("research")
        |> Workflow.add_node(:plan, :agent_step, %{agent: planner, prompt: "Plan research on: ..."})
        |> Workflow.add_node(:search, :agent_step, %{agent: searcher, prompt: fn s -> "Search: \#{s.data.plan}" end})
        |> Workflow.add_node(:report, :agent_step, %{agent: reporter, prompt: "Write report from findings."})
        |> Workflow.chain([:plan, :search, :report])

      {:ok, result} = Workflow.run(workflow, %{topic: "AI agents in 2026"})

  ## Graph Definition

  Build graphs using an `Ecto.Multi`-style pipe API:

  - `new/1,2` — create an empty graph
  - `add_node/4,5` — add a typed node
  - `connect/3,4` — add an edge between nodes
  - `chain/2` — connect nodes in sequence

  ## Execution

  - `compile/1` — validate and compile the graph
  - `run/2,3` — compile and execute in one step
  """

  alias Nous.Workflow.{Graph, Compiler, Engine, Mermaid}

  # ---------------------------------------------------------------------------
  # Graph builder (delegated to Graph)
  # ---------------------------------------------------------------------------

  defdelegate new(id, opts \\ []), to: Graph
  defdelegate add_node(graph, node_id, type, config \\ %{}, opts \\ []), to: Graph
  defdelegate connect(graph, from, to, opts \\ []), to: Graph
  defdelegate chain(graph, node_ids), to: Graph
  defdelegate set_entry(graph, node_id), to: Graph

  # ---------------------------------------------------------------------------
  # Compilation
  # ---------------------------------------------------------------------------

  @doc """
  Compile and validate a workflow graph.

  Returns `{:ok, compiled}` or `{:error, errors}`.
  """
  @spec compile(Graph.t()) :: {:ok, Compiler.compiled()} | {:error, [term()]}
  defdelegate compile(graph), to: Compiler

  @doc """
  Validate a workflow graph without compiling.
  """
  @spec validate(Graph.t()) :: :ok | {:error, [term()]}
  defdelegate validate(graph), to: Compiler

  # ---------------------------------------------------------------------------
  # Visualization
  # ---------------------------------------------------------------------------

  @doc """
  Generate a Mermaid flowchart diagram string from the graph.
  """
  @spec to_mermaid(Graph.t(), keyword()) :: String.t()
  defdelegate to_mermaid(graph, opts \\ []), to: Mermaid

  # ---------------------------------------------------------------------------
  # Graph mutation
  # ---------------------------------------------------------------------------

  defdelegate insert_after(graph, after_id, new_id, type, config \\ %{}, opts \\ []), to: Graph
  defdelegate remove_node(graph, node_id), to: Graph

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  @doc """
  Compile and execute a workflow in one step.

  ## Options

  - `:deps` — dependencies passed to agents/tools
  - `:callbacks` — callback functions for agent steps
  - `:notify_pid` — PID to receive progress notifications
  - `:max_iterations` — max cycle iterations (default: 10)

  ## Returns

  - `{:ok, final_state}` — workflow completed successfully
  - `{:error, reason}` — compilation or execution failed
  """
  @spec run(Graph.t(), map(), keyword()) :: {:ok, Nous.Workflow.State.t()} | {:error, term()}
  def run(%Graph{} = graph, initial_data \\ %{}, opts \\ []) do
    case compile(graph) do
      {:ok, compiled} -> Engine.execute(compiled, initial_data, opts)
      {:error, _} = error -> error
    end
  end
end
