#!/usr/bin/env elixir

# Nous Conversation Agent Template
# Shows how to handle multi-turn conversations with memory

# ============================================================================
# Configuration
# ============================================================================

model = "lmstudio:qwen/qwen3-30b"

instructions = """
You are a helpful assistant having a conversation.
Remember what we've talked about in this conversation.
Be conversational and reference previous messages when relevant.
"""

# ============================================================================
# Conversation Manager
# ============================================================================

defmodule ConversationManager do
  @moduledoc """
  Manages conversation state and message history.
  """

  def start_conversation do
    %{
      agent: nil,
      message_history: [],
      conversation_id: :erlang.unique_integer([:positive])
    }
  end

  def create_agent(conversation, model, instructions) do
    agent = Nous.new(model,
      instructions: instructions,
      model_settings: %{temperature: 0.7, max_tokens: -1}
    )

    %{conversation | agent: agent}
  end

  def send_message(conversation, user_message) do
    IO.puts("👤 You: #{user_message}")
    IO.puts("🤖 Assistant: ", [:cyan])

    case Nous.run(conversation.agent, user_message,
           message_history: conversation.message_history) do
      {:ok, result} ->
        IO.puts(result.output)
        IO.puts("")

        # Update conversation with new messages
        updated_conversation = %{
          conversation |
          message_history: result.new_messages
        }

        {:ok, updated_conversation, result}

      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}")
        {:error, conversation, reason}
    end
  end

  def send_message_stream(conversation, user_message) do
    IO.puts("👤 You: #{user_message}")
    IO.puts("🤖 Assistant: ", [:cyan])

    case Nous.run_stream(conversation.agent, user_message,
           message_history: conversation.message_history) do
      {:ok, stream} ->
        # Collect the response text as we stream
        response_text = stream
        |> Enum.reduce("", fn event, acc ->
          case event do
            {:text_delta, text} ->
              IO.write(text)
              acc <> text

            {:finish, result} ->
              IO.puts("\n")

              # Return the final conversation state
              send(self(), {:stream_complete, result})
              acc

            _ -> acc
          end
        end)

        # Wait for the complete result
        receive do
          {:stream_complete, result} ->
            updated_conversation = %{
              conversation |
              message_history: result.new_messages
            }

            {:ok, updated_conversation, result}
        after
          30_000 -> {:error, conversation, :timeout}
        end

      {:error, reason} ->
        IO.puts("❌ Stream error: #{inspect(reason)}")
        {:error, conversation, reason}
    end
  end

  def conversation_stats(conversation) do
    total_messages = length(conversation.message_history)
    user_messages = Enum.count(conversation.message_history, &(&1.role == "user"))
    assistant_messages = total_messages - user_messages

    %{
      id: conversation.conversation_id,
      total_messages: total_messages,
      user_messages: user_messages,
      assistant_messages: assistant_messages
    }
  end

  def print_conversation_history(conversation, limit \\ nil) do
    messages_to_show = case limit do
      nil -> conversation.message_history
      n -> Enum.take(conversation.message_history, -n)
    end

    IO.puts("\n📜 Conversation History:")
    IO.puts(String.duplicate("=", 50))

    messages_to_show
    |> Enum.with_index(1)
    |> Enum.each(fn {message, index} ->
      role_emoji = if message.role == "user", do: "👤", else: "🤖"
      IO.puts("#{index}. #{role_emoji} #{String.capitalize(message.role)}: #{message.content}")
      IO.puts("")
    end)

    stats = conversation_stats(conversation)
    IO.puts("📊 Stats: #{stats.total_messages} messages (#{stats.user_messages} user, #{stats.assistant_messages} assistant)")
    IO.puts(String.duplicate("=", 50))
  end
end

# ============================================================================
# Interactive Conversation Demo
# ============================================================================

defmodule InteractiveDemo do
  def run do
    IO.puts("🗣️  Starting interactive conversation...")
    IO.puts("Type 'quit' to exit, 'history' to see conversation, 'stats' for statistics")
    IO.puts("")

    # Start conversation
    conversation = ConversationManager.start_conversation()
    conversation = ConversationManager.create_agent(conversation, model, instructions)

    # Interactive loop
    conversation_loop(conversation)
  end

  defp conversation_loop(conversation) do
    # Get user input
    IO.write("👤 You: ")
    user_input = IO.gets("") |> String.trim()

    case user_input do
      "quit" ->
        IO.puts("👋 Goodbye!")
        stats = ConversationManager.conversation_stats(conversation)
        IO.puts("Final conversation: #{stats.total_messages} messages exchanged")

      "history" ->
        ConversationManager.print_conversation_history(conversation)
        conversation_loop(conversation)

      "stats" ->
        stats = ConversationManager.conversation_stats(conversation)
        IO.inspect(stats, label: "📊 Conversation Stats")
        conversation_loop(conversation)

      "" ->
        IO.puts("Please enter a message or 'quit' to exit.")
        conversation_loop(conversation)

      message ->
        # Send message and continue conversation
        case ConversationManager.send_message(conversation, message) do
          {:ok, updated_conversation, _result} ->
            conversation_loop(updated_conversation)

          {:error, conversation, reason} ->
            IO.puts("Error occurred: #{inspect(reason)}")
            IO.puts("Would you like to try again? (y/n)")

            case IO.gets("") |> String.trim() |> String.downcase() do
              "y" -> conversation_loop(conversation)
              _ -> IO.puts("👋 Goodbye!")
            end
        end
    end
  end
end

# ============================================================================
# Pre-scripted Conversation Demo
# ============================================================================

defmodule ScriptedDemo do
  def run do
    IO.puts("🎭 Running scripted conversation demo...")
    IO.puts("")

    # Start conversation
    conversation = ConversationManager.start_conversation()
    conversation = ConversationManager.create_agent(conversation, model, instructions)

    # Pre-scripted conversation
    messages = [
      "Hi! What's your name?",
      "What's the capital of France?",
      "What did I ask you before this question?",
      "Can you summarize our entire conversation so far?"
    ]

    # Send each message
    final_conversation = Enum.reduce(messages, conversation, fn message, conv ->
      case ConversationManager.send_message(conv, message) do
        {:ok, updated_conv, _result} ->
          # Small delay to make it readable
          Process.sleep(1000)
          updated_conv

        {:error, conv, reason} ->
          IO.puts("Error: #{inspect(reason)}")
          conv
      end
    end)

    # Show final stats
    ConversationManager.print_conversation_history(final_conversation)
  end
end

# ============================================================================
# Choose Demo Mode
# ============================================================================

IO.puts("Choose demo mode:")
IO.puts("1. Interactive conversation (type with the AI)")
IO.puts("2. Scripted conversation (watch pre-written conversation)")
IO.write("Enter choice (1 or 2): ")

choice = IO.gets("") |> String.trim()

case choice do
  "1" -> InteractiveDemo.run()
  "2" -> ScriptedDemo.run()
  _ ->
    IO.puts("Invalid choice. Running scripted demo...")
    ScriptedDemo.run()
end

# ============================================================================
# Conversation Management Tips
# ============================================================================

# Best practices for conversation management:
#
# 1. **Message History**: Always pass previous messages for context
#
# 2. **Memory Limits**: Monitor token usage and trim old messages if needed:
#    message_history = conversation.message_history |> Enum.take(-20)
#
# 3. **State Persistence**: For production, save conversation state:
#    MyApp.Conversations.save(conversation_id, message_history)
#
# 4. **Context Window**: Some models have limited context windows
#
# 5. **Error Recovery**: Handle network errors gracefully
#
# 6. **User Experience**: Show typing indicators, message status, etc.

# Example: Trimming old messages to manage context size
# defp trim_old_messages(messages, max_tokens \\ 4000) do
#   # Simple heuristic: ~4 characters per token
#   total_chars = messages |> Enum.map(& &1.content) |> Enum.join() |> String.length()
#
#   if total_chars > max_tokens * 4 do
#     # Keep recent messages, preserve system message
#     system_messages = Enum.filter(messages, & &1.role == "system")
#     recent_messages = Enum.take(messages, -10)
#     system_messages ++ recent_messages
#   else
#     messages
#   end
# end

# ============================================================================
# Next Steps
# ============================================================================

# Ready for more advanced patterns?
# - ../genserver_agent_example.ex (stateful agent processes)
# - ../liveview_agent_example.ex (web chat interface)
# - ../distributed_agent_example.ex (multi-user conversations)
# - ../specialized/council/ (multi-AI conversations)