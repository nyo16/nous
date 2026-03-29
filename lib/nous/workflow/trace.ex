defmodule Nous.Workflow.Trace do
  @moduledoc """
  Records execution traces for workflow debugging and observability.

  A trace is an ordered list of node executions with timing, status,
  and output summaries. Traces are accumulated in-memory during execution
  and returned as part of the workflow state metadata.

  ## Example

      {:ok, state} = Nous.Workflow.run(graph, %{}, trace: true)
      trace = state.metadata.trace

      for entry <- trace.entries do
        IO.puts "\#{entry.node_id} (\#{entry.node_type}): \#{entry.status} in \#{entry.duration_ms}ms"
      end
  """

  @type entry :: %{
          node_id: String.t(),
          node_type: atom(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          status: :completed | :failed | :skipped | :suspended,
          duration_ms: non_neg_integer(),
          error: term() | nil
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          entries: [entry()],
          started_at: DateTime.t()
        }

  defstruct run_id: nil,
            entries: [],
            started_at: nil

  @doc """
  Create a new empty trace.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      run_id: generate_id(),
      entries: [],
      started_at: DateTime.utc_now()
    }
  end

  @doc """
  Record a completed node execution.
  """
  @spec record(
          t(),
          String.t(),
          atom(),
          non_neg_integer(),
          :completed | :failed | :skipped | :suspended,
          term()
        ) :: t()
  def record(%__MODULE__{} = trace, node_id, node_type, duration_ns, status, error \\ nil) do
    now = DateTime.utc_now()
    duration_ms = System.convert_time_unit(duration_ns, :native, :millisecond)

    entry = %{
      node_id: node_id,
      node_type: node_type,
      started_at: DateTime.add(now, -duration_ms, :millisecond),
      completed_at: now,
      status: status,
      duration_ms: duration_ms,
      error: error
    }

    %{trace | entries: trace.entries ++ [entry]}
  end

  @doc """
  Returns the total execution time in milliseconds.
  """
  @spec total_duration_ms(t()) :: non_neg_integer()
  def total_duration_ms(%__MODULE__{entries: entries}) do
    Enum.reduce(entries, 0, fn entry, acc -> acc + entry.duration_ms end)
  end

  @doc """
  Returns the number of nodes executed.
  """
  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{entries: entries}), do: length(entries)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
