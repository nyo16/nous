#!/usr/bin/env elixir

# Complete Real-World Tool Example
#
# This demonstrates a realistic use case: A personal assistant AI
# that can search files, check system info, and perform calculations.

IO.puts("\n🤖 Personal Assistant AI - Complete Tool Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# ============================================================================
# Define Tools - These are just regular Elixir functions!
# ============================================================================

defmodule AssistantTools do
  @moduledoc "Tools for the personal assistant"

  @doc """
  Search for files in the current directory.

  ## Parameters
  - pattern: Search pattern (e.g., "*.ex", "test*")
  """
  def search_files(_ctx, args) do
    pattern = Map.get(args, "pattern", "*")
    IO.puts("  🔍 Searching for files matching: #{pattern}")

    # Use File.ls! to get files
    case File.ls() do
      {:ok, files} ->
        matched =
          files
          |> Enum.filter(fn file ->
            String.contains?(file, String.replace(pattern, "*", ""))
          end)
          |> Enum.take(10)

        %{
          pattern: pattern,
          count: length(matched),
          files: matched
        }

      {:error, _} ->
        %{error: "Could not read directory"}
    end
  end

  @doc """
  Get system information.

  ## Parameters
  - info_type: Type of info ("memory", "processes", "all")
  """
  def get_system_info(_ctx, args) do
    info_type = Map.get(args, "info_type", "all")
    IO.puts("  💻 Getting system info: #{info_type}")

    case info_type do
      "memory" ->
        memory = :erlang.memory()

        %{
          type: "memory",
          total_mb: div(memory[:total], 1024 * 1024),
          processes_mb: div(memory[:processes], 1024 * 1024),
          atom_mb: div(memory[:atom], 1024 * 1024)
        }

      "processes" ->
        %{
          type: "processes",
          count: length(Process.list()),
          system: "BEAM VM"
        }

      _ ->
        %{
          type: "all",
          processes: length(Process.list()),
          memory_mb: div(:erlang.memory(:total), 1024 * 1024),
          system: "Elixir #{System.version()}"
        }
    end
  end

  @doc """
  Calculate a mathematical expression.

  ## Parameters
  - operation: Type of operation ("add", "multiply", "divide")
  - x: First number
  - y: Second number
  """
  def calculate(_ctx, args) do
    operation = Map.get(args, "operation", "add")
    x = Map.get(args, "x", 0)
    y = Map.get(args, "y", 0)

    IO.puts("  🔢 Calculating: #{operation}(#{x}, #{y})")

    result =
      case operation do
        "add" -> x + y
        "subtract" -> x - y
        "multiply" -> x * y
        "divide" when y != 0 -> x / y
        "divide" -> "Error: Division by zero"
        _ -> "Unknown operation"
      end

    %{
      operation: operation,
      x: x,
      y: y,
      result: result
    }
  end

  @doc """
  Get current time and date.
  """
  def get_datetime(_ctx, _args) do
    IO.puts("  🕐 Getting current date and time")

    now = DateTime.utc_now()

    %{
      datetime: DateTime.to_string(now),
      date: Date.to_string(DateTime.to_date(now)),
      time: Time.to_string(DateTime.to_time(now)),
      timezone: "UTC",
      unix_timestamp: DateTime.to_unix(now)
    }
  end
end

# ============================================================================
# Setup Agent
# ============================================================================

# Choose your provider
provider =
  cond do
    System.get_env("ANTHROPIC_API_KEY") ->
      {"anthropic", "claude-sonnet-4-5-20250929",
       [api_key: System.get_env("ANTHROPIC_API_KEY")]}

    true ->
      {"lmstudio", "qwen/qwen3-30b-a3b-2507", []}
  end

{provider_name, model_name, opts} = provider

IO.puts("Using provider: #{provider_name}")
IO.puts("Model: #{model_name}")
IO.puts("")

# Create the agent
agent =
  Yggdrasil.new("#{provider_name}:#{model_name}", opts ++
    [
      instructions: """
      You are a helpful personal assistant with access to various tools.
      When users ask questions, use the appropriate tools to help them.
      Always explain what you're doing and why.
      Be friendly and concise.
      """,
      tools: [
        &AssistantTools.search_files/2,
        &AssistantTools.get_system_info/2,
        &AssistantTools.calculate/2,
        &AssistantTools.get_datetime/2
      ],
      model_settings: %{
        temperature: 0.7,
        max_tokens: 1000
      }
    ]
  )

IO.puts("🤖 Personal Assistant ready!")
IO.puts("   Tools available: #{length(agent.tools)}")
IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Interactive Tests
# ============================================================================

defmodule TestRunner do
  def run_test(agent, question) do
    IO.puts("\n#{question}")
    IO.puts("-" |> String.duplicate(70))

    case Yggdrasil.run(agent, question) do
      {:ok, result} ->
        IO.puts("\n✅ Response:")
        IO.puts(result.output)
        IO.puts("\n📊 Stats: #{result.usage.tool_calls} tool calls, #{result.usage.total_tokens} tokens")
        :ok

      {:error, error} ->
        IO.puts("\n❌ Error: #{inspect(error)}")
        :error
    end

    IO.puts("")
  end
end

# Run tests
TestRunner.run_test(agent, "Q1: What Elixir files (.ex) are in this directory?")

TestRunner.run_test(
  agent,
  "Q2: How much memory is the system using? Give me the total in MB."
)

TestRunner.run_test(agent, "Q3: What is 156 multiplied by 23?")

TestRunner.run_test(agent, "Q4: What's the current date and time?")

# Multi-step question
TestRunner.run_test(
  agent,
  "Q5: Can you calculate 45 + 67, then tell me how many Elixir processes are running?"
)

IO.puts("=" |> String.duplicate(70))
IO.puts("🎉 Demo complete! The AI used tools intelligently to answer questions!")
IO.puts("")
IO.puts("💡 Key takeaways:")
IO.puts("  - AI automatically chooses which tools to call")
IO.puts("  - Multiple tools can be called in sequence")
IO.puts("  - Same tools work with ANY provider (LM Studio, Claude, etc.)")
IO.puts("  - Tools are just regular Elixir functions!")
IO.puts("")
