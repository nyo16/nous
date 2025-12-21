defmodule DeepResearch.Agents.PlannerAgent do
  @moduledoc """
  The Strategist - Decomposes complex questions into research plans.

  Persona: Methodical, strategic thinker. Breaks problems into manageable
  sub-questions and defines the research DAG structure.

  Responsibilities:
  - Analyze the research question
  - Decompose into 3-5 specific sub-questions
  - Define dependencies between research tasks
  - Create initial research plan
  """

  alias Nous.Agent

  @persona """
  You are The Strategist, a methodical research planner. Your role is to:

  1. ANALYZE the research question to understand its scope and complexity
  2. DECOMPOSE it into 3-5 specific, answerable sub-questions
  3. PRIORITIZE sub-questions by importance and dependency
  4. PLAN the research approach for each sub-question

  Guidelines:
  - Each sub-question should be specific enough to research independently
  - Sub-questions should collectively cover the full scope of the main question
  - Consider what types of sources would best answer each sub-question
  - Identify any dependencies between sub-questions

  Output your plan as a structured analysis.
  """

  @doc """
  Create a new Planner agent.
  """
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, default_model())

    Agent.new(model,
      instructions: @persona,
      model_settings: %{
        temperature: 0.3,
        max_tokens: 2000
      }
    )
  end

  @doc """
  Plan the research by decomposing the question into sub-questions.

  Returns {:ok, plan} where plan contains:
  - sub_questions: List of specific sub-questions
  - approach: Research approach for each
  - dependencies: Any dependencies between questions
  """
  def plan(question, opts \\ []) do
    agent = new(opts)

    prompt = """
    Analyze this research question and create a research plan:

    QUESTION: #{question}

    Provide your response in this exact format:

    ## Analysis
    [Brief analysis of the question's scope and complexity]

    ## Sub-Questions
    1. [First specific sub-question]
    2. [Second specific sub-question]
    3. [Third specific sub-question]
    [Add more if needed, max 5]

    ## Research Approach
    For each sub-question, briefly describe:
    - What type of sources to search (web, academic, news)
    - Key terms to search for
    - What evidence would answer this question

    ## Dependencies
    [Note any sub-questions that depend on answers from others, or "None" if all can be researched in parallel]
    """

    case Nous.run(agent, prompt) do
      {:ok, result} ->
        plan = parse_plan(result.output, question)
        {:ok, plan}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse the planner's output into a structured plan.
  """
  def parse_plan(output, original_question) do
    sub_questions = extract_sub_questions(output)

    %{
      original_question: original_question,
      sub_questions: sub_questions,
      raw_plan: output,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp extract_sub_questions(output) do
    # Look for numbered list items after "## Sub-Questions"
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      # Match lines starting with number and period
      String.match?(line, ~r/^\d+\.\s+/)
    end)
    |> Enum.map(fn line ->
      # Remove the number prefix
      String.replace(line, ~r/^\d+\.\s+/, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(5)
    |> case do
      [] ->
        # Fallback: generate default sub-questions
        generate_default_sub_questions(output)

      questions ->
        questions
    end
  end

  defp generate_default_sub_questions(output) do
    # If parsing failed, extract any question-like sentences
    output
    |> String.split(~r/[.?!]\s+/)
    |> Enum.filter(&String.contains?(&1, "?"))
    |> Enum.take(3)
    |> case do
      [] -> ["What is the current state of this topic?", "What are the key challenges?", "What are the future directions?"]
      questions -> questions
    end
  end

  defp default_model do
    System.get_env("DEEP_RESEARCH_MODEL") ||
      System.get_env("ANTHROPIC_API_KEY") && "anthropic:claude-sonnet-4-5-20250929" ||
      System.get_env("OPENAI_API_KEY") && "openai:gpt-4" ||
      "lmstudio:qwen/qwen3-30b"
  end
end
