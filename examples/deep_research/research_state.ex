defmodule DeepResearch.ResearchState do
  @moduledoc """
  Shared state for the deep research workflow.

  Maintains:
  - Research question and sub-questions
  - DAG graph of research tasks
  - Findings with source citations
  - Knowledge gaps identified by Critic
  - Verified facts in knowledge base
  """

  alias DeepResearch.ResearchGraph

  defstruct [
    :question,
    :sub_questions,
    :graph,
    completed: MapSet.new(),
    findings: [],
    sources: %{},
    knowledge_base: [],
    gaps: [],
    iterations: 0,
    max_iterations: 5,
    agent_outputs: %{},
    started_at: nil,
    metadata: %{}
  ]

  @type finding :: %{
          id: integer(),
          content: String.t(),
          source_url: String.t(),
          source_title: String.t(),
          confidence: :high | :medium | :low,
          verified: boolean(),
          sub_question: String.t() | nil,
          created_at: String.t()
        }

  @type source :: %{
          url: String.t(),
          title: String.t(),
          type: :web | :news | :wikipedia | :academic,
          accessed_at: String.t(),
          relevance: integer()
        }

  @type t :: %__MODULE__{
          question: String.t(),
          sub_questions: [String.t()],
          graph: Graph.t(),
          completed: MapSet.t(),
          findings: [finding()],
          sources: %{String.t() => source()},
          knowledge_base: [String.t()],
          gaps: [String.t()],
          iterations: non_neg_integer(),
          max_iterations: non_neg_integer(),
          agent_outputs: map(),
          started_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc """
  Create a new research state for a question.
  """
  def new(question, opts \\ []) do
    %__MODULE__{
      question: question,
      sub_questions: [],
      graph: ResearchGraph.new(),
      max_iterations: Keyword.get(opts, :max_iterations, 5),
      started_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Add a finding with automatic ID assignment.
  """
  def add_finding(state, finding_attrs) do
    id = length(state.findings) + 1

    finding = %{
      id: id,
      content: finding_attrs[:content] || "",
      source_url: finding_attrs[:source_url] || "",
      source_title: finding_attrs[:source_title] || "",
      confidence: finding_attrs[:confidence] || :medium,
      verified: finding_attrs[:verified] || false,
      sub_question: finding_attrs[:sub_question],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Also track the source
    state = maybe_add_source(state, finding)

    %{state | findings: [finding | state.findings]}
  end

  defp maybe_add_source(state, finding) do
    url = finding.source_url

    if url != "" and not Map.has_key?(state.sources, url) do
      source = %{
        url: url,
        title: finding.source_title,
        type: :web,
        accessed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        relevance: 3
      }

      %{state | sources: Map.put(state.sources, url, source)}
    else
      state
    end
  end

  @doc """
  Mark a finding as verified with confidence level.
  """
  def verify_finding(state, finding_id, confidence) do
    findings =
      Enum.map(state.findings, fn f ->
        if f.id == finding_id do
          %{f | verified: true, confidence: confidence}
        else
          f
        end
      end)

    %{state | findings: findings}
  end

  @doc """
  Add a knowledge gap identified by Critic.
  """
  def add_gap(state, gap_description) do
    %{state | gaps: [gap_description | state.gaps]}
  end

  @doc """
  Clear gaps (after they've been addressed).
  """
  def clear_gaps(state) do
    %{state | gaps: []}
  end

  @doc """
  Mark a graph node as completed.
  """
  def complete_node(state, node_id) do
    %{state | completed: MapSet.put(state.completed, node_id)}
  end

  @doc """
  Increment iteration counter.
  """
  def increment_iteration(state) do
    %{state | iterations: state.iterations + 1}
  end

  @doc """
  Check if max iterations reached.
  """
  def max_iterations_reached?(state) do
    state.iterations >= state.max_iterations
  end

  @doc """
  Store agent output for a node.
  """
  def store_agent_output(state, node_id, output) do
    outputs = Map.put(state.agent_outputs, node_id, output)
    %{state | agent_outputs: outputs}
  end

  @doc """
  Get statistics about current state.
  """
  def stats(state) do
    verified_count = Enum.count(state.findings, & &1.verified)
    high_confidence = Enum.count(state.findings, &(&1.confidence == :high))

    %{
      total_findings: length(state.findings),
      verified_findings: verified_count,
      high_confidence: high_confidence,
      total_sources: map_size(state.sources),
      gaps_remaining: length(state.gaps),
      nodes_completed: MapSet.size(state.completed),
      iterations: state.iterations,
      duration_ms: duration_ms(state)
    }
  end

  defp duration_ms(state) do
    if state.started_at do
      DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)
    else
      0
    end
  end

  @doc """
  Convert state to a context map for passing to agents via deps.
  """
  def to_context(state) do
    %{
      question: state.question,
      sub_questions: state.sub_questions,
      findings: Enum.reverse(state.findings),
      sources: Map.values(state.sources),
      knowledge_base: state.knowledge_base,
      gaps: state.gaps,
      stats: stats(state)
    }
  end
end
