defmodule Nous.Research.Planner do
  @moduledoc """
  Decomposes a complex research query into a structured plan with sub-questions.

  Supports three strategies:
  - `:parallel` - Independent sub-queries executed simultaneously
  - `:sequential` - Each step depends on prior results
  - `:tree` - Branching exploration with pruning
  """

  require Logger

  @type step :: %{
          query: String.t(),
          strategy: :parallel | :sequential,
          depends_on: [non_neg_integer()]
        }

  @type plan :: %{
          query: String.t(),
          steps: [step()],
          strategy: :parallel | :sequential | :tree,
          estimated_searches: non_neg_integer()
        }

  @doc """
  Generate a research plan from a user query.

  Uses an LLM to decompose the query into searchable sub-questions.
  """
  @spec plan(String.t(), keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(query, opts \\ []) do
    model = Keyword.get(opts, :model, "openai:gpt-4o-mini")
    strategy = Keyword.get(opts, :strategy, :parallel)

    prompt = """
    You are a research planner. Break down this research query into 3-7 specific, \
    searchable sub-questions. Each sub-question should be independently answerable \
    via web search.

    Research query: #{query}

    Strategy: #{strategy}

    Respond with a numbered list of sub-questions, one per line:
    1. [sub-question]
    2. [sub-question]
    ...

    Keep questions specific and searchable. Avoid overly broad questions.
    """

    agent =
      Nous.Agent.new(model,
        instructions: "You are a research planning specialist.",
        model_settings: %{temperature: 0.3, max_tokens: 1000}
      )

    case Nous.Agent.run(agent, prompt) do
      {:ok, result} ->
        steps = parse_plan_steps(result.output, strategy)

        {:ok,
         %{
           query: query,
           steps: steps,
           strategy: strategy,
           estimated_searches: length(steps)
         }}

      {:error, reason} ->
        # Fallback: use the original query as a single step
        Logger.warning("Planning failed, using single-step fallback: #{inspect(reason)}")

        {:ok,
         %{
           query: query,
           steps: [%{query: query, strategy: :parallel, depends_on: []}],
           strategy: :parallel,
           estimated_searches: 1
         }}
    end
  end

  defp parse_plan_steps(output, strategy) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/^\d+[\.\)]\s+/, &1))
    |> Enum.map(fn line ->
      # Strip the numbering
      query = Regex.replace(~r/^\d+[\.\)]\s+/, line, "") |> String.trim()
      %{query: query, strategy: strategy, depends_on: []}
    end)
    |> case do
      [] ->
        # Parsing failed, use original query
        [%{query: output, strategy: strategy, depends_on: []}]

      steps ->
        if strategy == :sequential do
          # Add sequential dependencies
          steps
          |> Enum.with_index()
          |> Enum.map(fn {step, i} ->
            deps = if i > 0, do: [i - 1], else: []
            %{step | depends_on: deps}
          end)
        else
          steps
        end
    end
  end
end
