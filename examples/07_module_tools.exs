#!/usr/bin/env elixir

# Nous AI - Module-Based Tools (v0.8.0)
# Better organization and testability with Tool.Behaviour

IO.puts("=== Nous AI - Module Tools Demo ===\n")

# ============================================================================
# Define a Tool as a Module
# ============================================================================

defmodule MyTools.Calculator do
  @moduledoc "A calculator tool that evaluates math expressions"

  @behaviour Nous.Tool.Behaviour

  @impl true
  def metadata do
    %{
      name: "calculate",
      description: "Evaluate a mathematical expression",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "expression" => %{
            "type" => "string",
            "description" => "The math expression to evaluate, e.g., '2 + 2'"
          }
        },
        "required" => ["expression"]
      }
    }
  end

  @impl true
  def execute(_ctx, %{"expression" => expression}) do
    try do
      {result, _} = Code.eval_string(expression)
      {:ok, %{expression: expression, result: result}}
    rescue
      e -> {:error, "Failed to evaluate: #{inspect(e)}"}
    end
  end
end

# ============================================================================
# Define Another Tool Module
# ============================================================================

defmodule MyTools.UnitConverter do
  @behaviour Nous.Tool.Behaviour

  @impl true
  def metadata do
    %{
      name: "convert_units",
      description: "Convert between units of measurement",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "value" => %{"type" => "number", "description" => "The value to convert"},
          "from" => %{"type" => "string", "description" => "Source unit (celsius, fahrenheit, meters, feet)"},
          "to" => %{"type" => "string", "description" => "Target unit"}
        },
        "required" => ["value", "from", "to"]
      }
    }
  end

  @impl true
  def execute(_ctx, %{"value" => value, "from" => from, "to" => to}) do
    result = convert(value, String.downcase(from), String.downcase(to))

    case result do
      {:ok, converted} -> {:ok, %{original: value, from: from, to: to, result: converted}}
      {:error, msg} -> {:error, msg}
    end
  end

  defp convert(v, "celsius", "fahrenheit"), do: {:ok, v * 9/5 + 32}
  defp convert(v, "fahrenheit", "celsius"), do: {:ok, (v - 32) * 5/9}
  defp convert(v, "meters", "feet"), do: {:ok, v * 3.28084}
  defp convert(v, "feet", "meters"), do: {:ok, v / 3.28084}
  defp convert(_, from, to), do: {:error, "Unknown conversion: #{from} to #{to}"}
end

# ============================================================================
# Tool with Context Dependencies
# ============================================================================

defmodule MyTools.DatabaseQuery do
  @behaviour Nous.Tool.Behaviour

  @impl true
  def metadata do
    %{
      name: "query_database",
      description: "Query the database for records",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "table" => %{"type" => "string", "description" => "Table name"},
          "limit" => %{"type" => "integer", "description" => "Max records to return"}
        },
        "required" => ["table"]
      }
    }
  end

  @impl true
  def execute(ctx, %{"table" => table} = args) do
    # Get database from context deps (injected at runtime)
    db = ctx.deps[:database] || MockDB

    limit = Map.get(args, "limit", 10)
    records = db.query(table, limit)

    {:ok, %{table: table, records: records, count: length(records)}}
  end
end

# Mock database for demo
defmodule MockDB do
  def query("users", limit) do
    [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]
    |> Enum.take(limit)
  end
  def query(table, _), do: [%{table: table, note: "mock data"}]
end

# ============================================================================
# Using Module Tools
# ============================================================================

IO.puts("--- Creating Tools from Modules ---")

# Create tools from modules
calc_tool = Nous.Tool.from_module(MyTools.Calculator)
converter_tool = Nous.Tool.from_module(MyTools.UnitConverter)
db_tool = Nous.Tool.from_module(MyTools.DatabaseQuery, timeout: 5_000)

IO.puts("Created tools:")
IO.puts("  - #{calc_tool.name}: #{calc_tool.description}")
IO.puts("  - #{converter_tool.name}: #{converter_tool.description}")
IO.puts("  - #{db_tool.name}: #{db_tool.description}")
IO.puts("")

# ============================================================================
# Run Agent with Module Tools
# ============================================================================

IO.puts("--- Agent with Module Tools ---")

agent = Nous.new("lmstudio:qwen3",
  instructions: "You are a helpful assistant with math, conversion, and database tools.",
  tools: [calc_tool, converter_tool, db_tool]
)

# Math query
IO.puts("Query: What is 15 * 7 + 23?")
{:ok, result} = Nous.run(agent, "What is 15 * 7 + 23?")
IO.puts("Response: #{result.output}\n")

# Conversion query
IO.puts("Query: Convert 100 celsius to fahrenheit")
{:ok, result} = Nous.run(agent, "Convert 100 celsius to fahrenheit")
IO.puts("Response: #{result.output}\n")

# Database query with context
IO.puts("Query: List users from database")
{:ok, result} = Nous.run(agent, "List all users from the database",
  deps: %{database: MockDB}
)
IO.puts("Response: #{result.output}\n")

# ============================================================================
# Benefits of Module Tools
# ============================================================================

IO.puts("""
--- Benefits of Module Tools ---

1. **Organization**: Group related logic in modules
2. **Testability**: Test tool logic independently
3. **Metadata**: Define name, description, parameters in one place
4. **Context Injection**: Use ctx.deps for dependencies (DBs, APIs, etc.)
5. **Timeouts**: Set per-tool timeout: from_module(M, timeout: 5_000)

Testing a module tool:

    test "calculator evaluates expressions" do
      ctx = Nous.Tool.Testing.test_context()
      assert {:ok, %{result: 4}} = MyTools.Calculator.execute(ctx, %{"expression" => "2 + 2"})
    end

    test "database tool uses injected db" do
      mock_db = %{query: fn _, _ -> [%{id: 1}] end}
      ctx = Nous.Tool.Testing.test_context(%{database: mock_db})
      assert {:ok, result} = MyTools.DatabaseQuery.execute(ctx, %{"table" => "users"})
    end
""")

IO.puts("Next: mix run examples/08_tool_testing.exs")
