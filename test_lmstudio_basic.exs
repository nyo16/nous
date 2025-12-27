#!/usr/bin/env elixir

# Test basic functionality with our new Message system and LMStudio
alias Nous.{Agent, AgentRunner, Message}

IO.puts("🧪 Testing Nous with LMStudio - Basic Message System")
IO.puts("=" <> String.duplicate("=", 60))

# Test 1: Create messages using our new Message structs
IO.puts("\n📝 Test 1: Creating Messages with new struct system")
conversation = [
  Message.system("You are a helpful assistant that explains things clearly and concisely."),
  Message.user("What is Elixir programming language?")
]

IO.puts("System message: #{inspect(conversation |> hd() |> Message.extract_text())}")
IO.puts("User message: #{inspect(conversation |> tl() |> hd() |> Message.extract_text())}")

# Test 2: Test message utilities
IO.puts("\n🔍 Test 2: Testing Message utilities")
user_messages = Nous.Messages.find_by_role(conversation, :user)
IO.puts("Found #{length(user_messages)} user messages")

role_counts = Nous.Messages.count_by_role(conversation)
IO.puts("Role counts: #{inspect(role_counts)}")

# Test 3: Test with LMStudio model
IO.puts("\n🤖 Test 3: Testing with LMStudio")

# Configure for LMStudio
model = "lmstudio:qwen3-4b-thinking-2507-mlx"
agent = Agent.new(model,
  instructions: "Be helpful and explain things clearly.",
  model_settings: %{
    base_url: "http://localhost:1234/v1",
    temperature: 0.7
  }
)

IO.puts("Created agent with model: #{model}")
IO.puts("Agent instructions: #{agent.instructions}")

# Make a request
prompt = "Explain Elixir's pattern matching in one sentence."
IO.puts("\n📤 Sending: #{prompt}")

case AgentRunner.run(agent, prompt) do
  {:ok, result} ->
    IO.puts("\n✅ Success!")
    IO.puts("📥 Response: #{result.output}")
    IO.puts("📊 Usage: #{inspect(result.usage)}")
    IO.puts("🔄 Iterations: #{result.iterations}")

  {:error, error} ->
    IO.puts("\n❌ Error: #{inspect(error)}")
end

IO.puts("\n🎉 Test completed!")