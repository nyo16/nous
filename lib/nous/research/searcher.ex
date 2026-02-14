defmodule Nous.Research.Searcher do
  @moduledoc """
  Executes a single research sub-question using search tools.

  Each searcher gets its own isolated agent context to prevent
  cross-contamination between sub-questions.
  """

  alias Nous.Research.Finding

  require Logger

  @doc """
  Search for information about a specific sub-question.

  Returns a list of findings.
  """
  @spec search(String.t(), keyword()) :: {:ok, [Finding.t()]} | {:error, term()}
  def search(query, opts \\ []) do
    model = Keyword.get(opts, :model, "openai:gpt-4o-mini")
    search_tool = Keyword.get(opts, :search_tool)
    deps = Keyword.get(opts, :deps, %{})
    max_iterations = Keyword.get(opts, :max_iterations, 5)

    tools = build_tool_list(search_tool)

    if Enum.empty?(tools) do
      {:error, "No search tools available. Provide :search_tool option."}
    else
      run_search_agent(query, model, tools, deps, max_iterations)
    end
  end

  defp build_tool_list(nil), do: []

  defp build_tool_list(tool) when is_function(tool) do
    notes_tools = Nous.Tools.ResearchNotes.all_tools()
    [Nous.Tool.from_function(tool) | notes_tools]
  end

  defp build_tool_list(tools) when is_list(tools) do
    notes_tools = Nous.Tools.ResearchNotes.all_tools()

    parsed =
      Enum.map(tools, fn
        %Nous.Tool{} = t -> t
        f when is_function(f) -> Nous.Tool.from_function(f)
      end)

    parsed ++ notes_tools
  end

  defp run_search_agent(query, model, tools, deps, max_iterations) do
    agent =
      Nous.Agent.new(model,
        instructions: """
        You are a research searcher. Your goal is to find accurate information about a specific question.

        Instructions:
        1. Search for relevant information using the available search tools
        2. For each important fact you find, use add_finding to record it with source and confidence
        3. If you identify unanswered questions, use add_gap to record them
        4. If you find conflicting information, use add_contradiction to record it
        5. Be thorough but focused on the specific question

        Always cite your sources.
        """,
        tools: tools,
        model_settings: %{temperature: 0.3}
      )

    case Nous.Agent.run(agent, "Research this question: #{query}",
           deps: deps,
           max_iterations: max_iterations
         ) do
      {:ok, result} ->
        findings =
          (result.deps[:research_findings] || [])
          |> Enum.map(fn f ->
            Finding.new(%{
              claim: f.claim,
              source_url: f[:source_url],
              source_title: f[:source_title],
              confidence: f[:confidence] || 0.5,
              search_query: query
            })
          end)

        {:ok, findings}

      {:error, reason} ->
        Logger.warning("Search agent failed for '#{query}': #{inspect(reason)}")
        {:ok, []}
    end
  end
end
