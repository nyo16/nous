#!/usr/bin/env elixir

# Yggdrasil AI - Conversation History Example
# Multi-turn conversations with memory and context management

IO.puts("💬 Conversation History Demo")
IO.puts("Watch how AI remembers what we talked about!")
IO.puts("")

# ============================================================================
# Simple Conversation History
# ============================================================================

agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: """
  You are a friendly assistant having a conversation.
  Remember everything we've discussed in this conversation.
  Reference previous messages when relevant and helpful.
  Be conversational and natural.
  """,
  model_settings: %{temperature: 0.7}
)

IO.puts("🎬 Scripted Conversation Demo:")
IO.puts("Let's have a conversation and see how AI remembers context...")
IO.puts("")

# Start with empty message history
message_history = []

# Conversation sequence
conversation_turns = [
  "Hi! My name is Alex. What's your name?",
  "I'm working on a machine learning project about image recognition.",
  "What did I say my name was?",
  "What kind of project am I working on?",
  "Can you summarize our entire conversation so far?"
]

# Execute the conversation
final_history = Enum.reduce(conversation_turns, message_history, fn user_message, history ->
  IO.puts("👤 User: #{user_message}")

  case Yggdrasil.run(agent, user_message, message_history: history) do
    {:ok, result} ->
      IO.puts("🤖 Assistant: #{result.output}")
      IO.puts("")

      # The new_messages contains the updated conversation history
      result.new_messages

    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
      history
  end
end)

IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Conversation Statistics
# ============================================================================

IO.puts("📊 Conversation Statistics:")
total_messages = length(final_history)
user_messages = Enum.count(final_history, &(&1.role == "user"))
assistant_messages = total_messages - user_messages

IO.puts("   Total messages: #{total_messages}")
IO.puts("   User messages: #{user_messages}")
IO.puts("   Assistant messages: #{assistant_messages}")
IO.puts("")

# ============================================================================
# Message History Analysis
# ============================================================================

defmodule ConversationAnalyzer do
  @doc """
  Analyze conversation patterns and content
  """
  def analyze_conversation(messages) do
    %{
      total_messages: length(messages),
      user_messages: count_by_role(messages, "user"),
      assistant_messages: count_by_role(messages, "assistant"),
      total_characters: total_characters(messages),
      average_message_length: average_message_length(messages),
      conversation_topics: extract_topics(messages)
    }
  end

  defp count_by_role(messages, role) do
    Enum.count(messages, &(&1.role == role))
  end

  defp total_characters(messages) do
    messages
    |> Enum.map(& &1.content)
    |> Enum.join("")
    |> String.length()
  end

  defp average_message_length(messages) do
    if length(messages) > 0 do
      Float.round(total_characters(messages) / length(messages), 1)
    else
      0
    end
  end

  defp extract_topics(messages) do
    # Simple topic extraction (look for keywords)
    text = messages |> Enum.map(& &1.content) |> Enum.join(" ") |> String.downcase()

    topics = [
      {"AI/ML", Regex.scan(~r/\b(ai|artificial intelligence|machine learning|ml|model|neural|algorithm)\b/, text)},
      {"Technology", Regex.scan(~r/\b(computer|software|programming|code|technology|tech)\b/, text)},
      {"Personal", Regex.scan(~r/\b(name|personal|myself|i am|my name|working on)\b/, text)},
      {"Project", Regex.scan(~r/\b(project|working|building|creating|developing)\b/, text)}
    ]

    topics
    |> Enum.map(fn {topic, matches} -> {topic, length(matches)} end)
    |> Enum.filter(fn {_, count} -> count > 0 end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  def print_analysis(analysis) do
    IO.puts("🔍 Conversation Analysis:")
    IO.puts("   Messages: #{analysis.total_messages}")
    IO.puts("   Characters: #{analysis.total_characters}")
    IO.puts("   Avg message length: #{analysis.average_message_length} chars")

    if length(analysis.conversation_topics) > 0 do
      IO.puts("   Topics mentioned:")
      Enum.each(analysis.conversation_topics, fn {topic, count} ->
        IO.puts("     • #{topic}: #{count} mentions")
      end)
    end
  end
end

analysis = ConversationAnalyzer.analyze_conversation(final_history)
ConversationAnalyzer.print_analysis(analysis)

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Advanced: Context Window Management
# ============================================================================

defmodule ContextManager do
  @doc """
  Manage conversation context to stay within model limits
  """
  def manage_context(messages, max_tokens \\ 4000) do
    # Estimate tokens (rough: 4 chars per token)
    estimated_tokens = estimate_total_tokens(messages)

    if estimated_tokens > max_tokens do
      IO.puts("⚠️  Context getting large (#{estimated_tokens} tokens), trimming...")
      trim_conversation(messages, max_tokens)
    else
      messages
    end
  end

  defp estimate_total_tokens(messages) do
    total_chars = messages
    |> Enum.map(& &1.content)
    |> Enum.join("")
    |> String.length()

    # Rough estimation: 4 characters per token
    div(total_chars, 4)
  end

  defp trim_conversation(messages, max_tokens) do
    target_chars = max_tokens * 4

    # Always keep system messages
    system_messages = Enum.filter(messages, & &1.role == "system")

    # Keep recent messages up to token limit
    other_messages = Enum.filter(messages, & &1.role != "system")
    recent_messages = keep_recent_within_limit(other_messages, target_chars * 0.8)

    system_messages ++ recent_messages
  end

  defp keep_recent_within_limit(messages, target_chars) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {acc, chars} ->
      msg_chars = String.length(msg.content)

      if chars + msg_chars <= target_chars do
        {:cont, {[msg | acc], chars + msg_chars}}
      else
        {:halt, {acc, chars}}
      end
    end)
    |> elem(0)
  end
end

IO.puts("🧠 Context Management Demo:")

# Simulate a long conversation
long_conversation = [
  %{role: "user", content: "Tell me about the history of computers. Make it detailed."},
  %{role: "assistant", content: String.duplicate("Computer history is fascinating... ", 100)},
  %{role: "user", content: "What about artificial intelligence?"},
  %{role: "assistant", content: String.duplicate("AI development started... ", 100)},
  %{role: "user", content: "How do neural networks work?"},
  %{role: "assistant", content: String.duplicate("Neural networks are... ", 100)}
]

managed_context = ContextManager.manage_context(long_conversation, 200)  # Small limit for demo

IO.puts("Original conversation: #{length(long_conversation)} messages")
IO.puts("Managed context: #{length(managed_context)} messages")
IO.puts("")

# ============================================================================
# Interactive Conversation Mode
# ============================================================================

defmodule InteractiveConversation do
  @doc """
  Start an interactive conversation with the AI
  """
  def start_interactive(agent) do
    IO.puts("🎮 Interactive Mode Started!")
    IO.puts("Type 'quit' to exit, 'history' to see conversation, 'clear' to reset")
    IO.puts("")

    conversation_loop(agent, [])
  end

  defp conversation_loop(agent, history) do
    IO.write("👤 You: ")
    user_input = IO.gets("") |> String.trim()

    case user_input do
      "quit" ->
        IO.puts("👋 Goodbye! We had #{length(history)} messages total.")

      "history" ->
        print_conversation_history(history)
        conversation_loop(agent, history)

      "clear" ->
        IO.puts("🔄 Conversation history cleared!")
        conversation_loop(agent, [])

      "" ->
        IO.puts("Please enter a message.")
        conversation_loop(agent, history)

      message ->
        case Yggdrasil.run(agent, message, message_history: history) do
          {:ok, result} ->
            IO.puts("🤖 Assistant: #{result.output}")
            IO.puts("")
            conversation_loop(agent, result.new_messages)

          {:error, reason} ->
            IO.puts("❌ Error: #{inspect(reason)}")
            IO.puts("Try again? (y/n)")

            case IO.gets("") |> String.trim() |> String.downcase() do
              "y" -> conversation_loop(agent, history)
              _ -> IO.puts("👋 Goodbye!")
            end
        end
    end
  end

  defp print_conversation_history(messages) do
    IO.puts("\n📜 Conversation History:")
    IO.puts(String.duplicate("─", 40))

    messages
    |> Enum.with_index(1)
    |> Enum.each(fn {msg, index} ->
      emoji = if msg.role == "user", do: "👤", else: "🤖"
      IO.puts("#{index}. #{emoji} #{String.capitalize(msg.role)}: #{msg.content}")
    end)

    IO.puts(String.duplicate("─", 40))
    IO.puts("")
  end
end

IO.puts("🎮 Want to try interactive mode?")
IO.write("Start interactive conversation? (y/n): ")

case IO.gets("") |> String.trim() |> String.downcase() do
  "y" ->
    InteractiveConversation.start_interactive(agent)

  _ ->
    IO.puts("Skipping interactive mode.")
end

IO.puts("")

# ============================================================================
# Best Practices Summary
# ============================================================================

IO.puts("💡 Conversation History Best Practices:")
IO.puts("")
IO.puts("✅ Always pass message_history:")
IO.puts("   Yggdrasil.run(agent, message, message_history: history)")
IO.puts("")
IO.puts("✅ Use result.new_messages for updated history:")
IO.puts("   {:ok, result} = Yggdrasil.run(...)")
IO.puts("   updated_history = result.new_messages")
IO.puts("")
IO.puts("✅ Monitor context size:")
IO.puts("   • Most models have token limits (4k-200k)")
IO.puts("   • Trim old messages when needed")
IO.puts("   • Keep system messages")
IO.puts("")
IO.puts("✅ For production apps:")
IO.puts("   • Save conversation state to database")
IO.puts("   • Implement user sessions")
IO.puts("   • Handle concurrent conversations")
IO.puts("   • Add conversation analytics")

# ============================================================================
# Next Steps
# ============================================================================

IO.puts("")
IO.puts("🚀 Next Steps:")
IO.puts("1. Try changing the conversation script above")
IO.puts("2. Run interactive mode to chat with the AI")
IO.puts("3. See templates/conversation_agent.exs for more patterns")
IO.puts("4. Check liveview_chat_example.ex for web chat")
IO.puts("5. Try distributed_agent_example.ex for multi-user conversations")
IO.puts("6. Explore streaming_example.exs for real-time conversation updates")