defmodule Nous.Plugins.Summarization do
  @moduledoc """
  Plugin for managing context window size via conversation summarization.

  When the conversation exceeds a configurable token threshold, this plugin
  summarizes older messages to free up context space while preserving
  important information.

  ## Usage

      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.Summarization],
        deps: %{
          summarization_config: %{
            max_context_tokens: 170_000,
            keep_recent: 10,
            summary_model: "openai:gpt-4o-mini"
          }
        }
      )

  ## Configuration (via deps)

  - `:max_context_tokens` - Token threshold to trigger summarization (default: 100_000)
  - `:keep_recent` - Number of recent messages to keep intact (default: 10)
  - `:summary_model` - Model string for summarization calls (default: uses same model)

  ## Safety

  - Never splits tool_call/tool_result pairs
  - Keeps system prompt intact
  - Falls back to keeping all messages if summarization fails
  """

  @behaviour Nous.Plugin

  require Logger

  @default_max_tokens 100_000
  @default_keep_recent 10

  @impl true
  def init(_agent, ctx) do
    # Ensure summarization config exists in deps
    config = ctx.deps[:summarization_config] || %{}

    ctx
    |> put_in_deps(:summarization_config, %{
      max_context_tokens: Map.get(config, :max_context_tokens, @default_max_tokens),
      keep_recent: Map.get(config, :keep_recent, @default_keep_recent),
      summary_model: Map.get(config, :summary_model),
      summary_count: Map.get(config, :summary_count, 0)
    })
  end

  @impl true
  def before_request(agent, ctx, tools) do
    config = ctx.deps[:summarization_config] || %{}
    max_tokens = Map.get(config, :max_context_tokens, @default_max_tokens)

    if ctx.usage.total_tokens > max_tokens do
      Logger.info(
        "Summarization triggered: #{ctx.usage.total_tokens} tokens exceeds #{max_tokens} limit"
      )

      ctx = summarize_older_messages(agent, ctx, config)
      {ctx, tools}
    else
      {ctx, tools}
    end
  end

  defp summarize_older_messages(agent, ctx, config) do
    keep_recent = Map.get(config, :keep_recent, @default_keep_recent)
    messages = ctx.messages

    # Separate system messages from conversation
    {system_msgs, conversation} = Enum.split_with(messages, &(&1.role == :system))

    # If we don't have enough messages to summarize, skip
    if length(conversation) <= keep_recent do
      ctx
    else
      # Find safe split point - never split tool_call/tool_result pairs
      split_index = find_safe_split(conversation, keep_recent)

      {old_messages, recent_messages} = Enum.split(conversation, split_index)

      if Enum.empty?(old_messages) do
        ctx
      else
        case generate_summary(agent, old_messages, config) do
          {:ok, summary} ->
            summary_count = Map.get(config, :summary_count, 0) + 1
            summary_msg = Nous.Message.system("[Conversation Summary]\n#{summary}")

            updated_config = Map.put(config, :summary_count, summary_count)

            %{
              ctx
              | messages: system_msgs ++ [summary_msg | recent_messages]
            }
            |> put_in_deps(:summarization_config, updated_config)

          {:error, reason} ->
            Logger.warning("Summarization failed, keeping all messages: #{inspect(reason)}")
            ctx
        end
      end
    end
  end

  # Find a safe index to split messages, ensuring we never separate
  # an assistant message with tool_calls from its tool result messages
  defp find_safe_split(messages, keep_recent) do
    target = length(messages) - keep_recent

    if target <= 0 do
      0
    else
      # Walk backwards from target to find a safe split point
      # Safe = not in the middle of a tool_call/tool_result sequence
      find_safe_index(messages, target)
    end
  end

  defp find_safe_index(_messages, index) when index <= 0, do: 0

  defp find_safe_index(messages, index) do
    msg = Enum.at(messages, index)

    cond do
      # Don't split right before a tool result
      msg && msg.role == :tool ->
        find_safe_index(messages, index - 1)

      # Don't split right after an assistant message with tool calls
      msg && msg.role == :assistant && Nous.Message.has_tool_calls?(msg) ->
        find_safe_index(messages, index - 1)

      true ->
        index
    end
  end

  defp generate_summary(agent, messages, config) do
    summary_text =
      messages
      |> Enum.map(fn msg ->
        role = msg.role |> to_string() |> String.capitalize()
        content = msg.content || ""

        truncated =
          if String.length(content) > 500,
            do: String.slice(content, 0, 500) <> "...",
            else: content

        "#{role}: #{truncated}"
      end)
      |> Enum.join("\n")

    summary_prompt = """
    Summarize this conversation concisely, preserving key facts, decisions, and context needed for continuation:

    #{summary_text}

    Provide a concise summary (3-5 paragraphs max).
    """

    # Use the configured summary model or fall back to the agent's model
    model_string =
      Map.get(config, :summary_model) || "#{agent.model.provider}:#{agent.model.model}"

    try do
      summary_agent =
        Nous.Agent.new(model_string,
          instructions:
            "You are a conversation summarizer. Be concise and preserve key information.",
          model_settings: %{temperature: 0.3, max_tokens: 1000}
        )

      case Nous.Agent.run(summary_agent, summary_prompt) do
        {:ok, result} -> {:ok, result.output}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp put_in_deps(ctx, key, value) do
    %{ctx | deps: Map.put(ctx.deps, key, value)}
  end
end
