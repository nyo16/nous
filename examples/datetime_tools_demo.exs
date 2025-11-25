#!/usr/bin/env elixir

# DateTime Tools Demo - Shows all built-in date/time tools

IO.puts("\n📅 Yggdrasil AI - DateTime Tools Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

alias Yggdrasil.Tools.DateTimeTools

# Create agent with all datetime tools
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a helpful assistant with access to date and time tools.
  Always use the tools to get accurate current information.
  Be concise in your responses.
  """,
  tools: [
    &DateTimeTools.current_date/2,
    &DateTimeTools.current_time/2,
    &DateTimeTools.current_datetime/2,
    &DateTimeTools.date_difference/2,
    &DateTimeTools.add_days/2,
    &DateTimeTools.is_weekend/2,
    &DateTimeTools.day_of_week/2,
    &DateTimeTools.parse_date/2,
    &DateTimeTools.current_week/2,
    &DateTimeTools.current_month/2
  ]
)

# Test 1: Current date and time
IO.puts("Test 1: What day is today?")
IO.puts("-" |> String.duplicate(70))

{:ok, result1} = Yggdrasil.run(agent, "What day is today? Is it a weekend?")
IO.puts(result1.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 2: Current time in different format
IO.puts("Test 2: What time is it?")
IO.puts("-" |> String.duplicate(70))

{:ok, result2} = Yggdrasil.run(agent, "What time is it now in 12-hour format?")
IO.puts(result2.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 3: Date calculations
IO.puts("Test 3: Date calculations")
IO.puts("-" |> String.duplicate(70))

{:ok, result3} = Yggdrasil.run(agent, "What day will it be 30 days from now?")
IO.puts(result3.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 4: Date difference
IO.puts("Test 4: How many days until Christmas?")
IO.puts("-" |> String.duplicate(70))

{:ok, result4} = Yggdrasil.run(agent, "How many days are there between today and 2025-12-25?")
IO.puts(result4.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 5: Week information
IO.puts("Test 5: Current week information")
IO.puts("-" |> String.duplicate(70))

{:ok, result5} = Yggdrasil.run(agent, "What are the dates for this week (Monday to Sunday)?")
IO.puts(result5.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 6: Month information
IO.puts("Test 6: Current month information")
IO.puts("-" |> String.duplicate(70))

{:ok, result6} = Yggdrasil.run(agent, "Tell me about the current month - what month is it and how many days?")
IO.puts(result6.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 7: Timezone support
IO.puts("Test 7: Different timezones")
IO.puts("-" |> String.duplicate(70))

{:ok, result7} = Yggdrasil.run(agent, "What time is it in New York (America/New_York timezone)?")
IO.puts(result7.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 8: Complex query
IO.puts("Test 8: Complex date query")
IO.puts("-" |> String.duplicate(70))

{:ok, result8} = Yggdrasil.run(agent,
  "If today is a weekday, when is the next weekend? Show me the Saturday and Sunday dates.")
IO.puts(result8.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("✅ Demo complete!")
IO.puts("")
IO.puts("Available DateTime Tools:")
IO.puts("  • current_date - Get today's date in various formats")
IO.puts("  • current_time - Get current time in 12h/24h format")
IO.puts("  • current_datetime - Get full datetime with timezone")
IO.puts("  • date_difference - Calculate days between two dates")
IO.puts("  • add_days - Add/subtract days from a date")
IO.puts("  • is_weekend - Check if a date is weekend")
IO.puts("  • day_of_week - Get day name for any date")
IO.puts("  • parse_date - Parse date strings in various formats")
IO.puts("  • current_week - Get start/end of current week")
IO.puts("  • current_month - Get current month information")
IO.puts("")
IO.puts("Features:")
IO.puts("  ✓ Timezone support")
IO.puts("  ✓ Multiple date formats (ISO8601, US, EU, human-readable)")
IO.puts("  ✓ Weekend detection")
IO.puts("  ✓ Date arithmetic (add/subtract days)")
IO.puts("  ✓ Date parsing and formatting")
IO.puts("  ✓ Week and month information")
IO.puts("")
