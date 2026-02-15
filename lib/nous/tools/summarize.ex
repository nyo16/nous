defmodule Nous.Tools.Summarize do
  @moduledoc """
  Tool for summarizing long text using an LLM call.

  Uses nous's own `Nous.Agent.run/3` with a lightweight model to
  summarize content focused on a specific research question.

  ## Usage

      agent = Agent.new("openai:gpt-4",
        tools: [&Summarize.summarize/2],
        deps: %{summary_model: "openai:gpt-4o-mini"}
      )
  """

  @doc """
  Summarize a long text into key points.

  ## Arguments

  - text: The text to summarize (required)
  - focus: Optional focus query to guide summarization
  - max_points: Maximum number of key points (default: 5)

  ## Returns

  A map with summary, key_points list, and relevance_score.
  """
  def summarize(ctx, args) do
    text = Map.get(args, "text", "")
    focus = Map.get(args, "focus", "")
    max_points = Map.get(args, "max_points", 5)

    if String.length(text) < 50 do
      %{summary: text, key_points: [text], relevance_score: 1.0}
    else
      model = ctx.deps[:summary_model] || "openai:gpt-4o-mini"
      do_summarize(text, focus, max_points, model)
    end
  end

  defp do_summarize(text, focus, max_points, model) do
    # Truncate very long texts to avoid exceeding context limits
    truncated =
      if String.length(text) > 15_000 do
        String.slice(text, 0, 15_000) <> "\n\n[...truncated]"
      else
        text
      end

    focus_instruction =
      if focus != "" do
        "Focus the summary on information relevant to: #{focus}"
      else
        "Provide a general summary."
      end

    prompt = """
    Summarize the following text into a concise summary and up to #{max_points} key points.

    #{focus_instruction}

    TEXT:
    #{truncated}

    Respond with:
    SUMMARY: (2-3 sentence summary)
    KEY POINTS:
    - (point 1)
    - (point 2)
    ...
    RELEVANCE: (score 0.0-1.0 for how relevant this is to the focus query)
    """

    try do
      agent =
        Nous.Agent.new(model,
          instructions: "Extract key information concisely.",
          model_settings: %{temperature: 0.2, max_tokens: 800}
        )

      case Nous.Agent.run(agent, prompt) do
        {:ok, result} ->
          parse_summary_response(result.output)

        {:error, _reason} ->
          # Fallback: simple truncation
          %{
            summary: String.slice(truncated, 0, 500),
            key_points: [String.slice(truncated, 0, 200)],
            relevance_score: 0.5
          }
      end
    rescue
      _e ->
        %{
          summary: String.slice(truncated, 0, 500),
          key_points: [String.slice(truncated, 0, 200)],
          relevance_score: 0.5
        }
    end
  end

  defp parse_summary_response(response) do
    # Parse the structured response
    summary =
      case Regex.run(~r/SUMMARY:\s*(.+?)(?=KEY POINTS:|$)/s, response) do
        [_, s] -> String.trim(s)
        _ -> String.slice(response, 0, 500)
      end

    key_points =
      case Regex.run(~r/KEY POINTS:\s*(.+?)(?=RELEVANCE:|$)/s, response) do
        [_, points_text] ->
          points_text
          |> String.split(~r/\n-\s*/)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        _ ->
          [summary]
      end

    relevance =
      case Regex.run(~r/RELEVANCE:\s*([\d.]+)/, response) do
        [_, score] ->
          case Float.parse(score) do
            {f, _} -> min(max(f, 0.0), 1.0)
            :error -> 0.5
          end

        _ ->
          0.5
      end

    %{
      summary: summary,
      key_points: key_points,
      relevance_score: relevance
    }
  end
end
