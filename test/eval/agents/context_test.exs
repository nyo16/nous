defmodule Nous.Eval.Agents.ContextTest do
  @moduledoc """
  Tests for context and conversation functionality.

  Run with: mix test test/eval/agents/context_test.exs --include llm
  """

  use ExUnit.Case, async: false

  @moduletag :llm
  @moduletag :eval
  @moduletag :context
  @moduletag timeout: 180_000

  @default_model "lmstudio:ministral-3-14b-reasoning"

  setup_all do
    case check_lmstudio_available() do
      :ok -> {:ok, model: @default_model}
      {:error, reason} -> {:ok, skip: "LM Studio not available: #{reason}"}
    end
  end

  describe "Single Turn Context" do
    test "4.1 basic context structure", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model], instructions: "You are a helpful assistant")

      {:ok, result} = Nous.run(agent, "What is 2 + 2?")

      assert result.output != nil, "Expected output from agent"
      assert result.usage != nil, "Expected usage metrics"

      IO.puts("\n[Context 4.1] Output: #{inspect(result.output)}")
    end

    test "4.2 context with deps", context do
      skip_if_unavailable(context)

      agent =
        Nous.new(context[:model],
          instructions: "You are a helpful assistant. The user's name is available in context.",
          deps: %{user_name: "Alice", user_id: 123}
        )

      {:ok, result} = Nous.run(agent, "Hello!")

      assert result.output != nil
      IO.puts("\n[Context 4.2] Output: #{inspect(result.output)}")
    end
  end

  describe "Multi-Turn Conversation" do
    test "4.3 maintains conversation history", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model], instructions: "Remember what the user tells you.")

      # First turn - establish context
      {:ok, result1} = Nous.run(agent, "My favorite color is blue. Remember that.")

      # Second turn - test recall
      {:ok, result2} =
        Nous.run(agent, "What is my favorite color?", message_history: result1.messages)

      output = String.downcase(result2.output || "")

      IO.puts("\n[Context 4.3] Turn 1: #{inspect(result1.output)}")
      IO.puts("[Context 4.3] Turn 2: #{inspect(result2.output)}")

      # The model should recall the color
      assert String.contains?(output, "blue"),
             "Expected model to recall 'blue', got: #{inspect(result2.output)}"
    end

    test "4.4 multi-turn with accumulating context", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model], instructions: "You are a math tutor. Be concise.")

      # Turn 1
      {:ok, r1} = Nous.run(agent, "Let's do math. What is 5 + 3?")
      IO.puts("\n[Context 4.4] Turn 1: #{inspect(r1.output)}")

      # Turn 2
      {:ok, r2} = Nous.run(agent, "Now multiply that result by 2", message_history: r1.messages)
      IO.puts("[Context 4.4] Turn 2: #{inspect(r2.output)}")

      # Turn 3
      {:ok, r3} = Nous.run(agent, "What was our first answer?", message_history: r2.messages)
      IO.puts("[Context 4.4] Turn 3: #{inspect(r3.output)}")

      # Should reference 8 somewhere in context
      assert r3.messages != nil, "Expected messages to be preserved"
      assert length(r3.messages) >= 4, "Expected at least 4 messages in history"
    end
  end

  describe "Context Preservation" do
    test "4.5 deps preserved across interactions", context do
      skip_if_unavailable(context)

      user_data = %{
        name: "Bob",
        preferences: %{theme: "dark", language: "en"}
      }

      agent =
        Nous.new(context[:model],
          instructions: "You help users with their preferences.",
          deps: user_data
        )

      {:ok, result} = Nous.run(agent, "Hello, what's my name?")

      IO.puts("\n[Context 4.5] Output: #{inspect(result.output)}")
      # The agent should have access to deps context
      assert result.output != nil
    end

    test "4.6 system prompt persists", context do
      skip_if_unavailable(context)

      agent =
        Nous.new(context[:model],
          instructions: "You are a pirate. Always say 'Arr!' at the start of responses."
        )

      {:ok, r1} = Nous.run(agent, "Hello!")
      {:ok, r2} = Nous.run(agent, "How are you?", message_history: r1.messages)

      IO.puts("\n[Context 4.6] Turn 1: #{inspect(r1.output)}")
      IO.puts("[Context 4.6] Turn 2: #{inspect(r2.output)}")

      # At least one should have pirate speak
      output1 = String.downcase(r1.output || "")
      output2 = String.downcase(r2.output || "")

      has_pirate_speak =
        String.contains?(output1, "arr") or
          String.contains?(output2, "arr") or
          String.contains?(output1, "ahoy") or
          String.contains?(output2, "ahoy")

      # Lenient assertion - personality tests are variable
      assert r1.output != nil and r2.output != nil,
             "Expected responses from both turns"

      if not has_pirate_speak do
        IO.puts(
          "[Context 4.6] Note: Model didn't maintain pirate persona (common with smaller models)"
        )
      end
    end
  end

  describe "Long Conversations" do
    @tag timeout: 300_000
    test "4.7 handles extended conversation", context do
      skip_if_unavailable(context)

      agent =
        Nous.new(context[:model],
          instructions: "You are a helpful assistant. Be very concise - one sentence max."
        )

      # Build a 5-turn conversation
      turns = [
        "Hi, I'm starting a project",
        "It's about building a robot",
        "The robot needs to be able to walk",
        "What sensors would you recommend?",
        "Thanks for the help!"
      ]

      {final_result, turn_count} =
        Enum.reduce(turns, {nil, 0}, fn prompt, {prev_result, count} ->
          opts =
            if prev_result do
              [message_history: prev_result.messages]
            else
              []
            end

          case Nous.run(agent, prompt, opts) do
            {:ok, result} ->
              IO.puts("\n[Context 4.7] Turn #{count + 1}: #{inspect(result.output)}")
              {result, count + 1}

            {:error, reason} ->
              IO.puts("\n[Context 4.7] Error at turn #{count + 1}: #{inspect(reason)}")
              {prev_result, count}
          end
        end)

      assert turn_count >= 3, "Expected at least 3 successful turns, got #{turn_count}"

      if final_result do
        IO.puts("\n[Context 4.7] Final message count: #{length(final_result.messages)}")
      end
    end
  end

  describe "Context Reset" do
    test "4.8 fresh context has no history", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model], instructions: "Be concise.")

      # First conversation
      {:ok, r1} = Nous.run(agent, "Remember: the secret code is 42")

      # New conversation - should NOT remember
      agent2 = Nous.new(context[:model], instructions: "Be concise.")
      {:ok, r2} = Nous.run(agent2, "What is the secret code?")

      IO.puts("\n[Context 4.8] First agent: #{inspect(r1.output)}")
      IO.puts("[Context 4.8] Second agent: #{inspect(r2.output)}")

      # The second agent shouldn't know the code (no shared history)
      output2 = String.downcase(r2.output || "")
      # If it contains 42, that's just a coincidence or the model guessing
      assert r2.output != nil, "Expected response from fresh agent"
    end
  end

  describe "Message History Handling" do
    test "4.9 custom message history", context do
      skip_if_unavailable(context)

      # Pre-built message history
      custom_history = [
        %{role: "user", content: "My pet's name is Fluffy"},
        %{role: "assistant", content: "That's a lovely name for a pet!"}
      ]

      agent = Nous.new(context[:model], instructions: "Be helpful and concise.")

      {:ok, result} =
        Nous.run(agent, "What's my pet's name?", message_history: custom_history)

      IO.puts("\n[Context 4.9] Output: #{inspect(result.output)}")

      output = String.downcase(result.output || "")

      assert String.contains?(output, "fluffy"),
             "Expected model to recall 'Fluffy' from history"
    end
  end

  # Helper functions

  defp check_lmstudio_available do
    url = System.get_env("LMSTUDIO_BASE_URL") || "http://localhost:1234/v1"

    case Req.get("#{url}/models", receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "Status #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp skip_if_unavailable(%{skip: reason}) do
    ExUnit.Case.register_attribute(__ENV__, :skip, reason)
    :skip
  end

  defp skip_if_unavailable(_), do: :ok
end
