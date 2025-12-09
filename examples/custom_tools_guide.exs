#!/usr/bin/env elixir

# Nous AI - Custom Tools Development Guide
# Complete tutorial for creating powerful AI tools

IO.puts("🔧 Custom Tools Development Guide")
IO.puts("Learn how to create powerful tools for your AI agents!")
IO.puts("")

# ============================================================================
# Tool Basics - Understanding the Fundamentals
# ============================================================================

IO.puts("📚 Chapter 1: Tool Fundamentals")
IO.puts("")

defmodule ToolBasics do
  @doc """
  The simplest possible tool - just returns a string
  """
  def hello_world(_ctx, _args) do
    "Hello from a custom tool!"
  end

  @doc """
  Tool with parameters - extracts name from arguments
  """
  def greet(_ctx, %{"name" => name}) do
    "Hello, #{name}! Nice to meet you."
  end

  @doc """
  Tool with default parameters and error handling
  """
  def greet_safe(_ctx, args) do
    name = Map.get(args, "name", "friend")
    "Hello, #{name}! How can I help you today?"
  end

  @doc """
  Tool that returns structured data
  """
  def get_user_info(_ctx, %{"user_id" => user_id}) do
    %{
      id: user_id,
      name: "User #{user_id}",
      email: "user#{user_id}@example.com",
      status: "active",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end

IO.puts("1️⃣  Basic Tool Examples:")

basic_agent = Nous.new("lmstudio:qwen/qwen3-30b",
  instructions: """
  You have access to several basic tools.
  Use them to demonstrate different tool patterns when asked.
  """,
  tools: [
    &ToolBasics.hello_world/2,
    &ToolBasics.greet/2,
    &ToolBasics.greet_safe/2,
    &ToolBasics.get_user_info/2
  ]
)

basic_examples = [
  "Use the hello_world tool",
  "Greet someone named Alice using the greet tool",
  "Get user info for user ID 42"
]

Enum.each(basic_examples, fn example ->
  IO.puts("👤 Request: #{example}")

  case Nous.run(basic_agent, example) do
    {:ok, result} ->
      IO.puts("🤖 Response: #{result.output}")
      IO.puts("🔧 Tools used: #{result.usage.tool_calls}")

    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end

  IO.puts("")
end)

IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Advanced Tool Patterns
# ============================================================================

IO.puts("📚 Chapter 2: Advanced Tool Patterns")
IO.puts("")

defmodule AdvancedTools do
  @doc """
  Tool that uses context (deps) to access external resources
  """
  def database_query(ctx, %{"table" => table, "id" => id}) do
    # Access database connection from context
    database = ctx.deps[:database]

    if database do
      # Simulate database query
      "Query result from #{table} with ID #{id}: {record_found: true, data: 'sample_data'}"
    else
      {:error, "Database connection not available"}
    end
  end

  @doc """
  Tool that makes HTTP requests
  """
  def fetch_url(_ctx, %{"url" => url}) do
    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        # Return first 200 characters to avoid overwhelming the AI
        truncated_body = String.slice(body, 0, 200)
        "Successfully fetched #{url}: #{truncated_body}..."

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "HTTP request failed with status #{status}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Network error: #{reason}"}
    end
  rescue
    _error ->
      # HTTPoison might not be available in this environment
      "Simulated HTTP response from #{url}: {'status': 'success', 'data': 'example response'}"
  end

  @doc """
  Tool that performs file operations
  """
  def file_operations(_ctx, %{"action" => action, "filename" => filename} = args) do
    case action do
      "read" ->
        case File.read(filename) do
          {:ok, content} -> "File contents: #{String.slice(content, 0, 200)}..."
          {:error, reason} -> {:error, "Cannot read file: #{reason}"}
        end

      "write" ->
        content = Map.get(args, "content", "")

        case File.write(filename, content) do
          :ok -> "Successfully wrote #{byte_size(content)} bytes to #{filename}"
          {:error, reason} -> {:error, "Cannot write file: #{reason}"}
        end

      "exists" ->
        exists = File.exists?(filename)
        "File #{filename} exists: #{exists}"

      "delete" ->
        case File.rm(filename) do
          :ok -> "Successfully deleted #{filename}"
          {:error, reason} -> {:error, "Cannot delete file: #{reason}"}
        end

      _ ->
        {:error, "Unknown action: #{action}. Use 'read', 'write', 'exists', or 'delete'"}
    end
  end

  @doc """
  Tool that validates and sanitizes inputs
  """
  def secure_calculator(_ctx, %{"operation" => op, "a" => a, "b" => b}) do
    # Validate inputs
    with {:ok, num_a} <- validate_number(a),
         {:ok, num_b} <- validate_number(b),
         {:ok, operation} <- validate_operation(op) do
      # Perform calculation
      result = case operation do
        :add -> num_a + num_b
        :subtract -> num_a - num_b
        :multiply -> num_a * num_b
        :divide when num_b != 0 -> num_a / num_b
        :divide -> {:error, "Division by zero"}
      end

      case result do
        {:error, msg} -> {:error, msg}
        value -> "#{num_a} #{op} #{num_b} = #{value}"
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp validate_number(value) when is_number(value), do: {:ok, value}
  defp validate_number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} -> {:ok, num}
      {num, _} -> {:ok, num}
      :error -> {:error, "Invalid number: #{value}"}
    end
  end
  defp validate_number(value), do: {:error, "Invalid number: #{inspect(value)}"}

  defp validate_operation("add"), do: {:ok, :add}
  defp validate_operation("subtract"), do: {:ok, :subtract}
  defp validate_operation("multiply"), do: {:ok, :multiply}
  defp validate_operation("divide"), do: {:ok, :divide}
  defp validate_operation(op), do: {:error, "Invalid operation: #{op}"}

  @doc """
  Tool that processes data in chunks (useful for large datasets)
  """
  def process_list(_ctx, %{"items" => items, "operation" => operation}) do
    case operation do
      "count" ->
        "List contains #{length(items)} items"

      "sum" ->
        if Enum.all?(items, &is_number/1) do
          sum = Enum.sum(items)
          "Sum of #{length(items)} numbers: #{sum}"
        else
          {:error, "All items must be numbers for sum operation"}
        end

      "average" ->
        numbers = Enum.filter(items, &is_number/1)

        if length(numbers) > 0 do
          avg = Enum.sum(numbers) / length(numbers)
          "Average of #{length(numbers)} numbers: #{Float.round(avg, 2)}"
        else
          {:error, "No valid numbers found for average"}
        end

      "filter_positive" ->
        positive = Enum.filter(items, fn x -> is_number(x) and x > 0 end)
        "Found #{length(positive)} positive numbers: #{inspect(positive)}"

      _ ->
        {:error, "Unknown operation. Use: count, sum, average, filter_positive"}
    end
  end
end

IO.puts("2️⃣  Advanced Tool Examples:")

# Create agent with advanced tools and context
advanced_agent = Nous.new("lmstudio:qwen/qwen3-30b",
  instructions: """
  You have access to advanced tools that can:
  - Query databases (with proper context)
  - Make HTTP requests
  - Perform file operations
  - Do secure calculations with validation
  - Process lists of data

  Use these tools appropriately based on user requests.
  Always handle errors gracefully.
  """,
  tools: [
    &AdvancedTools.database_query/2,
    &AdvancedTools.fetch_url/2,
    &AdvancedTools.file_operations/2,
    &AdvancedTools.secure_calculator/2,
    &AdvancedTools.process_list/2
  ]
)

advanced_examples = [
  "Calculate 15.5 multiplied by 3.2 using the secure calculator",
  "Check if the file '/tmp/test.txt' exists",
  "Process this list of numbers [1, 5, 3, 8, 2] and calculate their average",
  "Fetch the content from https://httpbin.org/json (if available)"
]

Enum.each(advanced_examples, fn example ->
  IO.puts("👤 Request: #{example}")

  # Add context for database tool
  case Nous.run(advanced_agent, example, deps: %{database: "mock_database_connection"}) do
    {:ok, result} ->
      IO.puts("🤖 Response: #{result.output}")

    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end

  IO.puts("")
end)

IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Tool Development Best Practices
# ============================================================================

IO.puts("📚 Chapter 3: Tool Development Best Practices")
IO.puts("")

defmodule BestPracticeTools do
  @doc """
  Example of a well-designed tool following best practices
  """
  def weather_service(ctx, args) do
    with {:ok, location} <- validate_location(args),
         {:ok, units} <- validate_units(args),
         {:ok, api_key} <- get_api_key(ctx),
         {:ok, weather_data} <- fetch_weather(location, units, api_key) do
      format_weather_response(weather_data)
    else
      {:error, reason} ->
        {:error, "Weather service error: #{reason}"}
    end
  end

  # Helper functions with clear responsibilities
  defp validate_location(%{"location" => location}) when is_binary(location) and location != "" do
    {:ok, String.trim(location)}
  end

  defp validate_location(_), do: {:error, "Location is required and must be a non-empty string"}

  defp validate_units(%{"units" => units}) when units in ["metric", "imperial", "kelvin"] do
    {:ok, units}
  end

  defp validate_units(%{"units" => units}) do
    {:error, "Invalid units '#{units}'. Use: metric, imperial, or kelvin"}
  end

  defp validate_units(_), do: {:ok, "metric"}  # Default

  defp get_api_key(ctx) do
    case Map.get(ctx.deps || %{}, :weather_api_key) do
      nil -> {:error, "Weather API key not configured"}
      key -> {:ok, key}
    end
  end

  defp fetch_weather(location, units, _api_key) do
    # Simulate API call (in real implementation, use HTTPoison or similar)
    weather_data = %{
      location: location,
      temperature: if(units == "metric", do: 22, else: 72),
      description: "Partly cloudy",
      humidity: 65,
      wind_speed: if(units == "metric", do: 10, else: 6.2),
      units: units
    }

    {:ok, weather_data}
  end

  defp format_weather_response(data) do
    temp_unit = if data.units == "metric", do: "°C", else: "°F"
    speed_unit = if data.units == "metric", do: "km/h", else: "mph"

    """
    Weather in #{data.location}:
    - Temperature: #{data.temperature}#{temp_unit}
    - Conditions: #{data.description}
    - Humidity: #{data.humidity}%
    - Wind: #{data.wind_speed} #{speed_unit}
    """
  end

  @doc """
  Tool that demonstrates proper error handling patterns
  """
  def robust_file_processor(ctx, args) do
    try do
      # Step 1: Validate inputs
      filepath = validate_filepath(args)
      operation = validate_file_operation(args)

      # Step 2: Check permissions and context
      if authorized?(ctx, operation) do
        # Step 3: Perform operation with error handling
        execute_file_operation(filepath, operation, args)
      else
        {:error, "Unauthorized: insufficient permissions for #{operation}"}
      end
    rescue
      error ->
        # Log error for debugging (in production, use proper logging)
        IO.puts("🐛 Debug: Tool error - #{inspect(error)}")
        {:error, "Internal tool error occurred"}
    catch
      :throw, reason ->
        {:error, "Operation failed: #{reason}"}
    end
  end

  defp validate_filepath(%{"filepath" => path}) when is_binary(path) do
    # Prevent path traversal attacks
    if String.contains?(path, ["../", "..\\"]) do
      throw("Path traversal not allowed")
    end

    path
  end

  defp validate_filepath(_), do: throw("filepath parameter is required")

  defp validate_file_operation(%{"operation" => op}) when op in ["read", "write", "stat"] do
    String.to_atom(op)
  end

  defp validate_file_operation(_), do: throw("operation must be one of: read, write, stat")

  defp authorized?(ctx, operation) do
    permissions = Map.get(ctx.deps || %{}, :permissions, [])
    :file_read in permissions or (operation == :read and :file_read in permissions) or
      (operation == :write and :file_write in permissions) or
      (operation == :stat and :file_stat in permissions)
  end

  defp execute_file_operation(filepath, :stat, _args) do
    case File.stat(filepath) do
      {:ok, stat} ->
        %{
          size: stat.size,
          type: stat.type,
          access: stat.access,
          mtime: stat.mtime
        }

      {:error, reason} ->
        {:error, "Cannot get file stats: #{reason}"}
    end
  end

  defp execute_file_operation(filepath, :read, _args) do
    case File.read(filepath) do
      {:ok, content} ->
        # Limit content size to prevent overwhelming the AI
        if byte_size(content) > 1000 do
          "File content (truncated): #{String.slice(content, 0, 1000)}..."
        else
          "File content: #{content}"
        end

      {:error, reason} ->
        {:error, "Cannot read file: #{reason}"}
    end
  end

  defp execute_file_operation(filepath, :write, %{"content" => content}) do
    case File.write(filepath, content) do
      :ok -> "Successfully wrote #{byte_size(content)} bytes to #{filepath}"
      {:error, reason} -> {:error, "Cannot write file: #{reason}"}
    end
  end

  defp execute_file_operation(_filepath, :write, _args) do
    {:error, "content parameter required for write operation"}
  end
end

IO.puts("3️⃣  Best Practice Examples:")

best_practice_agent = Nous.new("lmstudio:qwen/qwen3-30b",
  instructions: """
  You have access to well-designed tools that follow best practices:
  - Proper input validation
  - Error handling
  - Security considerations
  - Clear documentation

  Use these tools as examples of how to build robust AI tools.
  """,
  tools: [
    &BestPracticeTools.weather_service/2,
    &BestPracticeTools.robust_file_processor/2
  ]
)

# Test with proper context
weather_context = %{
  weather_api_key: "demo_api_key_12345",
  permissions: [:file_read, :file_stat]
}

best_practice_examples = [
  "Get weather information for Paris in metric units",
  "Get file statistics for '/tmp/example.txt'"
]

Enum.each(best_practice_examples, fn example ->
  IO.puts("👤 Request: #{example}")

  case Nous.run(best_practice_agent, example, deps: weather_context) do
    {:ok, result} ->
      IO.puts("🤖 Response: #{result.output}")

    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end

  IO.puts("")
end)

IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Tool Development Checklist
# ============================================================================

IO.puts("📚 Chapter 4: Tool Development Checklist")
IO.puts("")
IO.puts("✅ Tool Function Signature:")
IO.puts("   • Always use (context, args) parameters")
IO.puts("   • Context provides deps, user info, permissions")
IO.puts("   • Args is a map of parameters from AI")
IO.puts("")
IO.puts("✅ Input Validation:")
IO.puts("   • Validate all required parameters")
IO.puts("   • Provide meaningful error messages")
IO.puts("   • Use pattern matching for type checking")
IO.puts("   • Sanitize inputs to prevent injection attacks")
IO.puts("")
IO.puts("✅ Return Values:")
IO.puts("   • Return simple data types (string, number, map, list)")
IO.puts("   • Use {:error, reason} tuple for failures")
IO.puts("   • Keep responses concise but informative")
IO.puts("   • Structure complex data clearly")
IO.puts("")
IO.puts("✅ Error Handling:")
IO.puts("   • Handle all possible failure modes")
IO.puts("   • Provide actionable error messages")
IO.puts("   • Use try/rescue for external calls")
IO.puts("   • Log errors for debugging")
IO.puts("")
IO.puts("✅ Security:")
IO.puts("   • Validate and sanitize all inputs")
IO.puts("   • Check permissions before operations")
IO.puts("   • Prevent path traversal attacks")
IO.puts("   • Limit resource usage")
IO.puts("")
IO.puts("✅ Performance:")
IO.puts("   • Keep operations fast (< 5 seconds)")
IO.puts("   • Limit data size returned to AI")
IO.puts("   • Use caching for expensive operations")
IO.puts("   • Handle timeouts gracefully")
IO.puts("")
IO.puts("✅ Documentation:")
IO.puts("   • Add @doc strings to all tools")
IO.puts("   • Document parameters and return values")
IO.puts("   • Provide usage examples")
IO.puts("   • Explain any special requirements")

# ============================================================================
# Tool Testing Framework
# ============================================================================

IO.puts("")
IO.puts("📚 Chapter 5: Testing Your Tools")
IO.puts("")

defmodule ToolTester do
  @doc """
  Test framework for validating tools before using them with AI
  """

  def test_tool(tool_function, test_cases) do
    IO.puts("🧪 Testing tool: #{inspect(tool_function)}")
    IO.puts("")

    results = Enum.map(test_cases, fn test_case ->
      IO.puts("Test: #{test_case.description}")
      IO.puts("Input: #{inspect(test_case.args)}")

      start_time = System.monotonic_time(:millisecond)

      result = try do
        tool_function.(test_case.context || %{}, test_case.args)
      rescue
        error -> {:error, "Exception: #{inspect(error)}"}
      catch
        :throw, reason -> {:error, "Throw: #{reason}"}
      end

      duration = System.monotonic_time(:millisecond) - start_time

      case result do
        {:error, reason} ->
          IO.puts("❌ Failed: #{reason}")

        success_result ->
          IO.puts("✅ Success: #{inspect(success_result)}")
      end

      IO.puts("⏱️  Duration: #{duration}ms")
      IO.puts("")

      %{
        test: test_case.description,
        result: result,
        duration: duration,
        passed: not match?({:error, _}, result)
      }
    end)

    # Summary
    passed = Enum.count(results, & &1.passed)
    total = length(results)
    avg_duration = Enum.map(results, & &1.duration) |> Enum.sum() |> div(total)

    IO.puts("📊 Test Summary:")
    IO.puts("   Passed: #{passed}/#{total}")
    IO.puts("   Average duration: #{avg_duration}ms")
    IO.puts("")

    results
  end
end

# Example: Test the secure calculator tool
calculator_tests = [
  %{
    description: "Valid addition",
    args: %{"operation" => "add", "a" => 5, "b" => 3}
  },
  %{
    description: "Valid division",
    args: %{"operation" => "divide", "a" => 10, "b" => 2}
  },
  %{
    description: "Division by zero",
    args: %{"operation" => "divide", "a" => 5, "b" => 0}
  },
  %{
    description: "Invalid operation",
    args: %{"operation" => "power", "a" => 2, "b" => 3}
  },
  %{
    description: "Invalid number",
    args: %{"operation" => "add", "a" => "not_a_number", "b" => 5}
  }
]

IO.puts("5️⃣  Tool Testing Example:")
ToolTester.test_tool(&AdvancedTools.secure_calculator/2, calculator_tests)

IO.puts(String.duplicate("=", 60))

# ============================================================================
# Advanced Tool Composition
# ============================================================================

IO.puts("")
IO.puts("📚 Chapter 6: Advanced Tool Composition")
IO.puts("")

defmodule CompositeTools do
  @doc """
  Tool that orchestrates multiple other tools
  """
  def research_topic(_ctx, %{"topic" => topic}) do
    # This tool would orchestrate multiple research steps:
    # 1. Search for information
    # 2. Summarize findings
    # 3. Generate follow-up questions

    steps = [
      "🔍 Searching for information about '#{topic}'...",
      "📊 Analyzing search results...",
      "📝 Summarizing key findings...",
      "❓ Generating follow-up questions..."
    ]

    research_result = %{
      topic: topic,
      summary: "#{topic} is a complex subject with multiple aspects including technical, social, and economic dimensions.",
      key_points: [
        "#{topic} has significant impact on modern society",
        "Current research shows promising developments",
        "Several challenges remain to be addressed"
      ],
      follow_up_questions: [
        "What are the latest developments in #{topic}?",
        "How does #{topic} affect different industries?",
        "What are the ethical considerations of #{topic}?"
      ],
      sources: ["Academic papers", "Industry reports", "Expert interviews"],
      confidence: 0.85
    }

    # Simulate processing steps
    Enum.each(steps, fn step ->
      IO.puts(step)
      Process.sleep(200)  # Small delay for demonstration
    end)

    research_result
  end

  @doc """
  Tool that provides context-aware responses based on conversation history
  """
  def contextual_assistant(ctx, args) do
    # Access conversation history from context
    history = Map.get(ctx, :conversation_history, [])
    current_question = Map.get(args, "question", "")

    # Analyze context
    context_analysis = analyze_conversation_context(history, current_question)

    %{
      response: generate_contextual_response(context_analysis, current_question),
      context_factors: context_analysis,
      recommendation: suggest_next_actions(context_analysis)
    }
  end

  defp analyze_conversation_context(history, question) do
    %{
      conversation_length: length(history),
      topics_mentioned: extract_topics(history),
      user_intent: classify_intent(question),
      context_relevance: calculate_relevance(history, question)
    }
  end

  defp extract_topics(history) do
    # Simple topic extraction (in practice, use NLP libraries)
    text = history |> Enum.map(& &1.content || "") |> Enum.join(" ")
    ["technology", "business", "science"] |> Enum.filter(&String.contains?(text, &1))
  end

  defp classify_intent(question) do
    cond do
      String.contains?(question, ["how", "what", "why"]) -> "information_seeking"
      String.contains?(question, ["help", "assist"]) -> "assistance_request"
      String.contains?(question, ["recommend", "suggest"]) -> "recommendation_request"
      true -> "general_inquiry"
    end
  end

  defp calculate_relevance(history, question) do
    # Simple relevance calculation
    if length(history) > 0 do
      0.7  # Assume moderate relevance
    else
      0.3  # Low relevance for first interaction
    end
  end

  defp generate_contextual_response(context, question) do
    case context.user_intent do
      "information_seeking" -> "Based on our conversation, here's the information about: #{question}"
      "assistance_request" -> "I can help you with that. Given our previous discussion..."
      "recommendation_request" -> "Considering what we've discussed, I recommend..."
      _ -> "Let me address your question: #{question}"
    end
  end

  defp suggest_next_actions(context) do
    case context.user_intent do
      "information_seeking" -> "Would you like me to elaborate on any specific aspect?"
      "assistance_request" -> "Shall we break this down into smaller steps?"
      "recommendation_request" -> "Would you like me to prioritize these recommendations?"
      _ -> "Is there anything specific you'd like to explore further?"
    end
  end
end

IO.puts("6️⃣  Advanced Tool Composition:")

composite_agent = Nous.new("lmstudio:qwen/qwen3-30b",
  instructions: """
  You have access to advanced composite tools that can:
  - Conduct comprehensive research on topics
  - Provide context-aware assistance based on conversation history
  - Orchestrate multiple research and analysis steps

  These tools demonstrate how to build sophisticated AI capabilities.
  """,
  tools: [
    &CompositeTools.research_topic/2,
    &CompositeTools.contextual_assistant/2
  ]
)

composite_examples = [
  "Research the topic of 'renewable energy' for me",
  "I need contextual assistance with understanding AI ethics"
]

Enum.each(composite_examples, fn example ->
  IO.puts("👤 Request: #{example}")

  case Nous.run(composite_agent, example) do
    {:ok, result} ->
      IO.puts("🤖 Response: #{String.slice(result.output, 0, 200)}...")

    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end

  IO.puts("")
end)

# ============================================================================
# Summary and Next Steps
# ============================================================================

IO.puts("")
IO.puts("🎓 Custom Tools Development Guide - Complete!")
IO.puts("")
IO.puts("What you've learned:")
IO.puts("✅ Tool function patterns and signatures")
IO.puts("✅ Input validation and error handling")
IO.puts("✅ Security considerations and best practices")
IO.puts("✅ Testing frameworks for tool validation")
IO.puts("✅ Advanced tool composition patterns")
IO.puts("✅ Context management and conversation awareness")
IO.puts("")
IO.puts("🚀 Next Steps:")
IO.puts("1. Create your own tools following these patterns")
IO.puts("2. Test tools thoroughly before deploying")
IO.puts("3. See examples/by_feature/tools/ for more tool examples")
IO.puts("4. Check trading_desk/ for production tool architectures")
IO.puts("5. Explore error_handling_example.exs for robust tool error patterns")
IO.puts("6. Use templates/tool_agent.exs as a starting point for new projects")
IO.puts("")
IO.puts("💡 Remember: Great tools make great AI agents!")
IO.puts("   Focus on reliability, security, and user experience.")