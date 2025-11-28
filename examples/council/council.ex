defmodule Council do
  @moduledoc """
  LLM Council - Multi-model deliberation system.

  Implements a 3-stage process where multiple LLMs collaborate:
  1. **Stage 1**: All council members respond to the question in parallel
  2. **Stage 2**: Each member ranks all responses (anonymized to prevent bias)
  3. **Stage 3**: A Chairman model synthesizes the final answer

  ## Example

      # Create council with 3 members
      council = Council.new(
        council_models: [
          {"lmstudio:qwen/qwen3-4b-2507", "Analyst"},
          {"lmstudio:qwen/qwen3-4b-2507", "Skeptic"},
          {"lmstudio:qwen/qwen3-4b-2507", "Advocate"}
        ],
        chairman_model: "lmstudio:qwen/qwen3-4b-2507",
        base_url: "http://localhost:1234/v1"
      )

      # Run deliberation
      {:ok, result} = Council.deliberate(council, "What is the meaning of life?")

  """

  alias Yggdrasil.Agent

  defstruct [
    :council_members,   # List of {agent, role_name}
    :chairman_agent,    # Agent for final synthesis
    :chairman_name,     # Chairman model name
    :base_url           # Base URL for local models
  ]

  @type model_response :: %{
    model: String.t(),
    role: String.t(),
    response: String.t()
  }

  @type ranking :: %{
    model: String.t(),
    role: String.t(),
    ranking: String.t(),
    parsed_ranking: [String.t()]
  }

  @type aggregate_ranking :: %{
    label: String.t(),
    model: String.t(),
    role: String.t(),
    average_rank: float(),
    rankings_count: non_neg_integer()
  }

  @type council_result :: %{
    stage1: [model_response()],
    stage2: [ranking()],
    stage3: model_response(),
    metadata: %{
      label_to_member: map(),
      aggregate_rankings: [aggregate_ranking()]
    }
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a new council.

  ## Options

    * `:council_models` - List of `{model_string, role_name}` tuples.
      Each council member gets a unique role/personality.

    * `:chairman_model` - Model string for the chairman who synthesizes
      the final answer.

    * `:base_url` - Base URL for OpenAI-compatible API (default: "http://localhost:1234/v1")

    * `:api_key` - API key (default: "not-needed" for local models)

    * `:model_settings` - Settings passed to all models (temperature, etc.)

  ## Example

      council = Council.new(
        council_models: [
          {"lmstudio:qwen/qwen3-4b-2507", "The Analyst - focuses on facts and data"},
          {"lmstudio:qwen/qwen3-4b-2507", "The Skeptic - questions assumptions"},
          {"lmstudio:qwen/qwen3-4b-2507", "The Creative - thinks outside the box"}
        ],
        chairman_model: "lmstudio:qwen/qwen3-4b-2507"
      )

  """
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts) do
    base_url = Keyword.get(opts, :base_url, "http://localhost:1234/v1")
    api_key = Keyword.get(opts, :api_key, "not-needed")
    model_settings = Keyword.get(opts, :model_settings, %{temperature: 0.7})

    council_models = Keyword.fetch!(opts, :council_models)
    chairman_model = Keyword.fetch!(opts, :chairman_model)

    # Create agents for each council member with their role
    council_members =
      Enum.map(council_models, fn {model_string, role_name} ->
        agent = create_member_agent(model_string, role_name, base_url, api_key, model_settings)
        {agent, role_name, model_string}
      end)

    # Create chairman agent
    chairman_agent = create_chairman_agent(chairman_model, base_url, api_key, model_settings)

    %__MODULE__{
      council_members: council_members,
      chairman_agent: chairman_agent,
      chairman_name: chairman_model,
      base_url: base_url
    }
  end

  @doc """
  Run the full 3-stage council deliberation.

  Returns `{:ok, result}` with all stages and metadata, or `{:error, reason}`.

  ## Result Structure

      %{
        stage1: [%{model: "...", role: "...", response: "..."}],
        stage2: [%{model: "...", role: "...", ranking: "...", parsed_ranking: [...]}],
        stage3: %{model: "...", role: "Chairman", response: "..."},
        metadata: %{
          label_to_member: %{"Response A" => %{model: "...", role: "..."}},
          aggregate_rankings: [%{label: "A", model: "...", average_rank: 1.5, ...}]
        }
      }

  """
  @spec deliberate(%__MODULE__{}, String.t()) :: {:ok, council_result()} | {:error, term()}
  def deliberate(%__MODULE__{} = council, query) do
    IO.puts("\n=== STAGE 1: Collecting Individual Responses ===\n")

    stage1_results = stage1_collect_responses(council, query)

    if Enum.empty?(stage1_results) do
      {:error, "All council members failed to respond"}
    else
      IO.puts("\n=== STAGE 2: Peer Rankings (Anonymized) ===\n")

      {stage2_results, label_to_member} = stage2_collect_rankings(council, query, stage1_results)

      aggregate_rankings = calculate_aggregate_rankings(stage2_results, label_to_member)

      IO.puts("\n=== STAGE 3: Chairman Synthesis ===\n")

      stage3_result = stage3_synthesize(council, query, stage1_results, stage2_results, aggregate_rankings)

      {:ok, %{
        stage1: stage1_results,
        stage2: stage2_results,
        stage3: stage3_result,
        metadata: %{
          label_to_member: label_to_member,
          aggregate_rankings: aggregate_rankings
        }
      }}
    end
  end

  @doc """
  Run deliberation with callbacks for each stage (useful for streaming UI).

  ## Callbacks

    * `on_stage1_start` - Called when Stage 1 begins
    * `on_stage1_member` - Called for each member response: `(member_info, response)`
    * `on_stage1_complete` - Called when Stage 1 completes: `(results)`
    * `on_stage2_start` - Called when Stage 2 begins
    * `on_stage2_member` - Called for each ranking: `(member_info, ranking)`
    * `on_stage2_complete` - Called when Stage 2 completes: `(results, metadata)`
    * `on_stage3_start` - Called when Stage 3 begins
    * `on_stage3_complete` - Called when Stage 3 completes: `(result)`

  """
  @spec deliberate_with_callbacks(%__MODULE__{}, String.t(), keyword()) ::
          {:ok, council_result()} | {:error, term()}
  def deliberate_with_callbacks(%__MODULE__{} = council, query, callbacks) do
    notify(callbacks, :on_stage1_start, [])

    stage1_results = stage1_collect_responses(council, query, fn member_info, response ->
      notify(callbacks, :on_stage1_member, [member_info, response])
    end)

    notify(callbacks, :on_stage1_complete, [stage1_results])

    if Enum.empty?(stage1_results) do
      {:error, "All council members failed to respond"}
    else
      notify(callbacks, :on_stage2_start, [])

      {stage2_results, label_to_member} = stage2_collect_rankings(
        council, query, stage1_results, fn member_info, ranking ->
          notify(callbacks, :on_stage2_member, [member_info, ranking])
        end
      )

      aggregate_rankings = calculate_aggregate_rankings(stage2_results, label_to_member)
      notify(callbacks, :on_stage2_complete, [stage2_results, %{label_to_member: label_to_member, aggregate_rankings: aggregate_rankings}])

      notify(callbacks, :on_stage3_start, [])
      stage3_result = stage3_synthesize(council, query, stage1_results, stage2_results, aggregate_rankings)
      notify(callbacks, :on_stage3_complete, [stage3_result])

      {:ok, %{
        stage1: stage1_results,
        stage2: stage2_results,
        stage3: stage3_result,
        metadata: %{
          label_to_member: label_to_member,
          aggregate_rankings: aggregate_rankings
        }
      }}
    end
  end

  # ============================================================================
  # Stage 1: Collect Individual Responses
  # ============================================================================

  defp stage1_collect_responses(council, query, on_member \\ nil) do
    # Note: For local models like LM Studio, we run sequentially since they
    # typically can only handle one request at a time. For cloud APIs,
    # you can increase max_concurrency for parallelism.
    council.council_members
    |> Task.async_stream(
      fn {agent, role, model_string} ->
        member_info = %{model: model_string, role: role}
        IO.puts("  Querying: #{role}...")

        case Agent.run(agent, query) do
          {:ok, result} ->
            response = %{
              model: model_string,
              role: role,
              response: result.output
            }
            if on_member, do: on_member.(member_info, response)
            IO.puts("  #{role} responded (#{result.usage.total_tokens} tokens)")
            response

          {:error, reason} ->
            IO.puts("  #{role} FAILED: #{inspect(reason)}")
            nil
        end
      end,
      max_concurrency: 1,  # Sequential for local models (LM Studio can only handle one at a time)
      timeout: 180_000     # 3 minutes per request for local models
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Enum.filter(& &1)
  end

  # ============================================================================
  # Stage 2: Anonymized Peer Rankings
  # ============================================================================

  defp stage2_collect_rankings(council, query, stage1_results, on_member \\ nil) do
    # Create anonymous labels (A, B, C, ...)
    labels = Enum.map(0..(length(stage1_results) - 1), fn i ->
      <<65 + i::utf8>>  # A, B, C, ...
    end)

    # Build label_to_member mapping
    label_to_member =
      Enum.zip(labels, stage1_results)
      |> Enum.into(%{}, fn {label, result} ->
        {"Response #{label}", %{model: result.model, role: result.role}}
      end)

    # Build anonymized responses text
    responses_text =
      Enum.zip(labels, stage1_results)
      |> Enum.map(fn {label, result} ->
        """
        Response #{label}:
        #{result.response}
        """
      end)
      |> Enum.join("\n" <> String.duplicate("-", 40) <> "\n")

    ranking_prompt = build_ranking_prompt(query, responses_text, labels)

    # Collect rankings from each council member sequentially (for local models)
    rankings =
      council.council_members
      |> Task.async_stream(
        fn {agent, role, model_string} ->
          member_info = %{model: model_string, role: role}
          IO.puts("  #{role} is evaluating...")

          case Agent.run(agent, ranking_prompt) do
            {:ok, result} ->
              parsed = parse_ranking_from_text(result.output)
              ranking = %{
                model: model_string,
                role: role,
                ranking: result.output,
                parsed_ranking: parsed
              }
              if on_member, do: on_member.(member_info, ranking)
              IO.puts("  #{role} ranked: #{inspect(parsed)}")
              ranking

            {:error, reason} ->
              IO.puts("  #{role} ranking FAILED: #{inspect(reason)}")
              nil
          end
        end,
        max_concurrency: 1,  # Sequential for local models
        timeout: 180_000     # 3 minutes per request
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.filter(& &1)

    {rankings, label_to_member}
  end

  # ============================================================================
  # Stage 3: Chairman Synthesis
  # ============================================================================

  defp stage3_synthesize(council, query, stage1_results, stage2_results, aggregate_rankings) do
    chairman_prompt = build_chairman_prompt(query, stage1_results, stage2_results, aggregate_rankings)

    IO.puts("  Chairman is synthesizing final answer...")

    case Agent.run(council.chairman_agent, chairman_prompt) do
      {:ok, result} ->
        IO.puts("  Chairman synthesis complete (#{result.usage.total_tokens} tokens)")
        %{
          model: council.chairman_name,
          role: "Chairman",
          response: result.output
        }

      {:error, reason} ->
        IO.puts("  Chairman synthesis FAILED: #{inspect(reason)}")
        %{
          model: council.chairman_name,
          role: "Chairman",
          response: "Error: Unable to synthesize final answer. Reason: #{inspect(reason)}"
        }
    end
  end

  # ============================================================================
  # Aggregate Rankings Calculation
  # ============================================================================

  @doc """
  Calculate aggregate rankings from all peer evaluations.

  Returns a sorted list (best first) with average rank position for each response.
  """
  def calculate_aggregate_rankings(stage2_results, label_to_member) do
    # Collect all positions for each label
    positions_by_label =
      Enum.reduce(stage2_results, %{}, fn ranking, acc ->
        ranking.parsed_ranking
        |> Enum.with_index(1)  # 1-indexed positions
        |> Enum.reduce(acc, fn {label, position}, inner_acc ->
          Map.update(inner_acc, label, [position], fn positions -> [position | positions] end)
        end)
      end)

    # Calculate average rank for each
    positions_by_label
    |> Enum.map(fn {label, positions} ->
      member = Map.get(label_to_member, label, %{model: "unknown", role: "unknown"})
      avg_rank = Enum.sum(positions) / length(positions)

      %{
        label: label,
        model: member.model,
        role: member.role,
        average_rank: Float.round(avg_rank, 2),
        rankings_count: length(positions)
      }
    end)
    |> Enum.sort_by(& &1.average_rank)
  end

  # ============================================================================
  # Prompt Builders
  # ============================================================================

  defp build_ranking_prompt(query, responses_text, labels) do
    labels_list = Enum.map_join(labels, ", ", &"Response #{&1}")

    """
    You are evaluating responses to the following question:

    QUESTION: #{query}

    Here are the responses to evaluate (identities hidden):

    #{responses_text}

    Please analyze each response for:
    1. Accuracy and correctness
    2. Completeness and depth
    3. Clarity and helpfulness
    4. Quality of reasoning

    After your analysis, provide your FINAL RANKING in this exact format:

    FINAL RANKING:
    1. Response [letter]
    2. Response [letter]
    3. Response [letter]

    Rank from BEST to WORST. Available responses: #{labels_list}

    IMPORTANT: Your ranking MUST include all responses and end with the ranking list.
    Do not include any text after the final ranking.
    """
  end

  defp build_chairman_prompt(query, stage1_results, stage2_results, aggregate_rankings) do
    # Format Stage 1 responses
    stage1_text =
      stage1_results
      |> Enum.map(fn result ->
        """
        #{result.role} (#{result.model}):
        #{result.response}
        """
      end)
      |> Enum.join("\n" <> String.duplicate("-", 40) <> "\n")

    # Format Stage 2 rankings
    stage2_text =
      stage2_results
      |> Enum.map(fn ranking ->
        """
        #{ranking.role}'s evaluation:
        #{ranking.ranking}
        """
      end)
      |> Enum.join("\n" <> String.duplicate("-", 40) <> "\n")

    # Format aggregate rankings
    aggregate_text =
      aggregate_rankings
      |> Enum.with_index(1)
      |> Enum.map(fn {agg, position} ->
        "##{position}. #{agg.role} (avg rank: #{agg.average_rank}, from #{agg.rankings_count} votes)"
      end)
      |> Enum.join("\n")

    """
    You are the Chairman of an LLM Council. Your role is to synthesize multiple expert
    perspectives into one comprehensive, authoritative answer.

    ORIGINAL QUESTION:
    #{query}

    ════════════════════════════════════════════════════════════════════════════════
    STAGE 1 - Individual Expert Responses:
    ════════════════════════════════════════════════════════════════════════════════

    #{stage1_text}

    ════════════════════════════════════════════════════════════════════════════════
    STAGE 2 - Peer Evaluations (how experts ranked each other):
    ════════════════════════════════════════════════════════════════════════════════

    #{stage2_text}

    ════════════════════════════════════════════════════════════════════════════════
    AGGREGATE RANKINGS (combined peer evaluation scores):
    ════════════════════════════════════════════════════════════════════════════════

    #{aggregate_text}

    ════════════════════════════════════════════════════════════════════════════════
    YOUR TASK AS CHAIRMAN:
    ════════════════════════════════════════════════════════════════════════════════

    Based on all of the above, synthesize a comprehensive final answer that:
    1. Incorporates the strongest points from the top-ranked responses
    2. Addresses any valid concerns raised in the peer reviews
    3. Resolves any contradictions between experts
    4. Provides a clear, authoritative answer to the original question

    Begin your synthesis:
    """
  end

  # ============================================================================
  # Ranking Parser
  # ============================================================================

  @doc """
  Parse the FINAL RANKING section from a model's response.

  Handles various formats:
  - "1. Response A"
  - "Response B"
  - "1) Response C"

  Returns a list like ["Response A", "Response B", "Response C"]
  """
  def parse_ranking_from_text(text) do
    # Try to find FINAL RANKING section first
    ranking_section =
      case String.split(text, ~r/FINAL RANKING:?/i) do
        [_, after_header | _] -> after_header
        _ -> text  # Fall back to full text
      end

    # Extract all "Response X" patterns in order
    ~r/Response\s+([A-Z])/i
    |> Regex.scan(ranking_section)
    |> Enum.map(fn [full_match, _letter] ->
      # Normalize to "Response X" format
      String.replace(full_match, ~r/\s+/, " ")
      |> String.trim()
      |> String.capitalize()
      |> then(fn s ->
        # Ensure proper format
        case Regex.run(~r/Response\s+([A-Z])/i, s) do
          [_, letter] -> "Response #{String.upcase(letter)}"
          _ -> s
        end
      end)
    end)
    |> Enum.uniq()  # Remove duplicates while preserving order
  end

  # ============================================================================
  # Agent Creation Helpers
  # ============================================================================

  defp create_member_agent(model_string, role_name, base_url, api_key, model_settings) do
    # Parse the model string to get provider and model name
    [_provider, model_name] = String.split(model_string, ":", parts: 2)

    Agent.new("custom:#{model_name}",
      base_url: base_url,
      api_key: api_key,
      instructions: """
      You are #{role_name}.

      Approach every question from your unique perspective. Be thoughtful,
      thorough, and provide well-reasoned responses.

      When evaluating other responses, be fair and objective. Judge based
      on accuracy, completeness, and quality of reasoning.
      """,
      model_settings: model_settings
    )
  end

  defp create_chairman_agent(model_string, base_url, api_key, model_settings) do
    [_provider, model_name] = String.split(model_string, ":", parts: 2)

    Agent.new("custom:#{model_name}",
      base_url: base_url,
      api_key: api_key,
      instructions: """
      You are the Chairman of an LLM Council.

      Your role is to synthesize multiple expert perspectives into clear,
      comprehensive, and authoritative answers. You should:

      1. Weigh each expert's input based on the peer rankings
      2. Identify areas of consensus and disagreement
      3. Resolve contradictions using evidence and reasoning
      4. Present a unified, well-structured final answer
      """,
      model_settings: model_settings
    )
  end

  # ============================================================================
  # Utility Helpers
  # ============================================================================

  defp notify(callbacks, event, args) do
    if callback = Keyword.get(callbacks, event) do
      apply(callback, args)
    end
  end
end
