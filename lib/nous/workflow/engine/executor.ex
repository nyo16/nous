defmodule Nous.Workflow.Engine.Executor do
  @moduledoc """
  Per-node execution dispatch.

  Routes node execution to the appropriate handler based on node type.
  Each handler receives the node and current workflow state, and returns
  `{:ok, result, updated_state}` or `{:error, reason}`.

  ## Phase 1 Node Types

  - `:agent_step` — runs a `Nous.Agent` via `AgentRunner.run/3`
  - `:tool_step` — executes a tool via `ToolExecutor.execute/3`
  - `:transform` — applies a pure function to the state

  ## Later Phases

  - `:branch` — conditional routing (Phase 2)
  - `:parallel` / `:parallel_map` — fan-out (Phase 3)
  - `:human_checkpoint` — HITL pause (Phase 2)
  - `:subworkflow` — nested workflow (Phase 5)
  """

  alias Nous.Workflow.{Node, State}

  @doc """
  Execute a single node with the current workflow state.

  Returns `{:ok, result, updated_state}` or `{:error, reason}`.
  """
  @spec execute(Node.t(), State.t()) :: {:ok, term(), State.t()} | {:error, term()}
  def execute(%Node{type: :agent_step} = node, %State{} = state) do
    agent = Map.fetch!(node.config, :agent)
    prompt = resolve_prompt(node.config.prompt, state)
    opts = build_agent_opts(node, state)

    case Nous.AgentRunner.run(agent, prompt, opts) do
      {:ok, result} ->
        updated_state =
          state
          |> State.put_result(node.id, result.output)
          |> maybe_merge_data(node, result.output)

        {:ok, result.output, updated_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%Node{type: :tool_step} = node, %State{} = state) do
    tool = Map.fetch!(node.config, :tool)
    args = resolve_args(node.config[:args] || %{}, state)
    deps = state.metadata[:deps] || %{}
    run_ctx = Nous.RunContext.new(deps)

    case Nous.ToolExecutor.execute(tool, args, run_ctx) do
      {:ok, result} ->
        updated_state = State.put_result(state, node.id, result)
        {:ok, result, updated_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%Node{type: :transform} = node, %State{} = state) do
    transform_fn = Map.fetch!(node.config, :transform_fn)

    try do
      new_state = State.update_data(state, transform_fn)
      updated_state = State.put_result(new_state, node.id, :ok)
      {:ok, :ok, updated_state}
    rescue
      e -> {:error, {e, __STACKTRACE__}}
    end
  end

  def execute(%Node{type: :branch} = node, %State{} = state) do
    # Branch nodes don't modify state — they return which path to take.
    # The engine uses outgoing edges to determine the next node.
    updated_state = State.put_result(state, node.id, :branch)
    {:ok, :branch, updated_state}
  end

  def execute(%Node{type: :human_checkpoint} = node, %State{} = state) do
    handler = node.config[:handler]

    if handler do
      prompt = node.config[:prompt] || "Human review required"

      case handler.(state, prompt) do
        :approve ->
          updated_state = State.put_result(state, node.id, :approved)
          {:ok, :approved, updated_state}

        {:edit, new_state} ->
          updated_state = State.put_result(new_state, node.id, :edited)
          {:ok, :edited, updated_state}

        :reject ->
          {:error, {:rejected, "human checkpoint #{node.id} was rejected"}}
      end
    else
      # No handler — signal the engine to suspend
      {:error, {:suspend, node.id}}
    end
  end

  def execute(%Node{type: :parallel} = _node, _state) do
    # Parallel nodes require graph context — dispatched via execute/3
    {:error,
     {:not_implemented, ":parallel nodes must be executed via execute/3 with graph_nodes"}}
  end

  def execute(%Node{type: :parallel_map} = node, %State{} = state) do
    Nous.Workflow.Engine.ParallelExecutor.execute_parallel_map(node, state)
  end

  def execute(%Node{type: type}, _state) do
    {:error, {:not_implemented, "node type #{inspect(type)} is not yet implemented"}}
  end

  @doc """
  Execute a node with additional graph context (needed for :parallel nodes).
  """
  @spec execute(Node.t(), State.t(), map()) :: {:ok, term(), State.t()} | {:error, term()}
  def execute(%Node{type: :parallel} = node, %State{} = state, graph_nodes) do
    Nous.Workflow.Engine.ParallelExecutor.execute_parallel(node, state, graph_nodes)
  end

  def execute(node, state, _graph_nodes), do: execute(node, state)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp resolve_prompt(prompt, state) when is_function(prompt, 1), do: prompt.(state)
  defp resolve_prompt(prompt, _state) when is_binary(prompt), do: prompt

  defp resolve_args(args, state) when is_function(args, 1), do: args.(state)
  defp resolve_args(args, _state) when is_map(args), do: args

  defp build_agent_opts(node, state) do
    opts = node.config[:opts] || []

    opts
    |> Keyword.put_new(:deps, state.metadata[:deps] || %{})
    |> Keyword.put_new(:callbacks, state.metadata[:callbacks] || %{})
    |> then(fn opts ->
      case state.metadata[:notify_pid] do
        nil -> opts
        pid -> Keyword.put_new(opts, :notify_pid, pid)
      end
    end)
  end

  defp maybe_merge_data(state, node, output) when is_map(output) do
    case node.config[:result_key] do
      nil -> state
      key -> State.update_data(state, &Map.put(&1, key, output))
    end
  end

  defp maybe_merge_data(state, node, output) do
    case node.config[:result_key] do
      nil -> state
      key -> State.update_data(state, &Map.put(&1, key, output))
    end
  end
end
