defmodule DeepResearch.Agents.ResearcherAgent do
  @moduledoc """
  The Scout - Executes iterative search and gathers raw information.

  Persona: Curious, persistent. Digs deep into sources, refines searches
  when results are insufficient, and extracts key findings.

  Responsibilities:
  - Execute web, news, Wikipedia, and academic searches
  - Fetch and extract content from promising URLs
  - Record findings with proper source citations
  - Refine search queries when needed
  """

  alias Nous.Agent
  alias DeepResearch.Tools.{SearchTools, ContentTools, MemoryTools}

  @persona """
  You are The Scout, a persistent and thorough research agent. Your role is to:

  1. SEARCH multiple sources (web, news, Wikipedia, academic) for information
  2. EVALUATE search results and identify the most relevant sources
  3. FETCH content from promising URLs to get detailed information
  4. EXTRACT key findings and record them with proper citations
  5. REFINE your search queries if initial results are insufficient

  Guidelines:
  - Start with broad searches, then narrow down based on results
  - Always cite the source URL for every finding you record
  - Look for authoritative sources (academic papers, official docs, reputable news)
  - If a search returns poor results, try different keywords or phrasings
  - Record both facts AND the confidence level (high/medium/low)
  - Aim to find at least 3-5 quality findings per sub-question

  Be thorough but efficient. Quality over quantity.
  """

  @doc """
  Create a new Researcher agent with all search and content tools.
  """
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, default_model())

    Agent.new(model,
      instructions: @persona,
      tools: build_tools(),
      model_settings: %{
        temperature: 0.4,
        max_tokens: 4000
      }
    )
  end

  @doc """
  Research a specific sub-question.

  Returns findings and sources discovered.
  """
  def research(sub_question, opts \\ []) do
    agent = new(opts)
    context = Keyword.get(opts, :context, %{})

    prompt = """
    Research the following question thoroughly:

    QUESTION: #{sub_question}

    Your task:
    1. Search multiple sources (web, Wikipedia, academic) for relevant information
    2. Evaluate the search results and identify the best sources
    3. Fetch content from the most promising URLs
    4. Extract key findings and record them with add_finding
    5. If initial searches are insufficient, refine your queries

    For each finding, use the add_finding tool with:
    - content: The key fact or insight
    - source_url: Where you found it
    - source_title: Title of the source
    - confidence: "high", "medium", or "low"
    - sub_question: "#{sub_question}"

    Aim for at least 3-5 quality findings with diverse sources.
    """

    deps =
      Map.merge(
        %{
          findings: [],
          sources: %{},
          sub_question: sub_question
        },
        context
      )

    case Nous.run(agent, prompt, deps: deps) do
      {:ok, result} ->
        # Extract findings from the updated context
        findings = get_in(result, [:all_messages]) |> extract_findings_from_messages()

        {:ok,
         %{
           sub_question: sub_question,
           findings: findings,
           output: result.output,
           usage: result.usage
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Research with an existing state context.
  """
  def research_with_state(sub_question, state, opts \\ []) do
    agent = new(opts)

    prompt = """
    Research the following question:

    QUESTION: #{sub_question}

    Context:
    - Main research question: #{state.question}
    - Existing findings: #{length(state.findings)}
    - Sources already used: #{map_size(state.sources)}

    Your task:
    1. Search for NEW information not already in our findings
    2. Focus on authoritative and recent sources
    3. Record each finding with proper citation using add_finding
    4. Aim for 3-5 new quality findings

    Use add_finding for each discovery with:
    - content: The fact/insight
    - source_url: The URL
    - source_title: Source name
    - confidence: high/medium/low
    - sub_question: "#{sub_question}"
    """

    deps = %{
      findings: state.findings,
      sources: state.sources,
      sub_question: sub_question,
      question: state.question
    }

    case Nous.run(agent, prompt, deps: deps) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_tools do
    [
      # Search tools
      &SearchTools.web_search/2,
      &SearchTools.news_search/2,
      &SearchTools.wikipedia_search/2,
      &SearchTools.academic_search/2,
      # Content tools
      &ContentTools.fetch_url/2,
      &ContentTools.fetch_and_extract/2,
      # Memory tools
      &MemoryTools.add_finding/2,
      &MemoryTools.add_source/2,
      &MemoryTools.list_findings/2
    ]
  end

  defp extract_findings_from_messages(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      case msg do
        %{role: "tool", content: content} when is_binary(content) ->
          case Jason.decode(content) do
            {:ok, %{"finding" => finding}} -> [finding]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp extract_findings_from_messages(_), do: []

  defp default_model do
    System.get_env("DEEP_RESEARCH_MODEL") ||
      System.get_env("ANTHROPIC_API_KEY") && "anthropic:claude-sonnet-4-5-20250929" ||
      System.get_env("OPENAI_API_KEY") && "openai:gpt-4" ||
      "lmstudio:qwen/qwen3-30b"
  end
end
