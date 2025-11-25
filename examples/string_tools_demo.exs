#!/usr/bin/env elixir

# String Tools Demo - Shows all built-in string manipulation tools

IO.puts("\n📝 Yggdrasil AI - String Tools Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

alias Yggdrasil.Tools.StringTools

# Create agent with all string tools
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a helpful assistant with access to string manipulation tools.
  Always use the tools to perform string operations accurately.
  Be concise in your responses.
  """,
  tools: [
    &StringTools.string_length/2,
    &StringTools.replace_text/2,
    &StringTools.split_text/2,
    &StringTools.join_text/2,
    &StringTools.count_occurrences/2,
    &StringTools.to_uppercase/2,
    &StringTools.to_lowercase/2,
    &StringTools.capitalize_text/2,
    &StringTools.trim_text/2,
    &StringTools.substring/2,
    &StringTools.contains/2,
    &StringTools.starts_with/2,
    &StringTools.ends_with/2,
    &StringTools.reverse_text/2,
    &StringTools.repeat_text/2,
    &StringTools.extract_words/2,
    &StringTools.pad_text/2,
    &StringTools.is_palindrome/2,
    &StringTools.extract_numbers/2
  ]
)

# Test 1: String length
IO.puts("Test 1: String length")
IO.puts("-" |> String.duplicate(70))

{:ok, result1} = Yggdrasil.run(agent, "How many characters are in 'Hello World'?")
IO.puts(result1.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 2: Replace text
IO.puts("Test 2: Replace text")
IO.puts("-" |> String.duplicate(70))

{:ok, result2} = Yggdrasil.run(agent, "Replace 'cat' with 'dog' in the text 'The cat sat on the cat mat'")
IO.puts(result2.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 3: Split text
IO.puts("Test 3: Split text")
IO.puts("-" |> String.duplicate(70))

{:ok, result3} = Yggdrasil.run(agent, "Split 'apple,banana,orange,grape' by comma")
IO.puts(result3.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 4: Count occurrences
IO.puts("Test 4: Count occurrences")
IO.puts("-" |> String.duplicate(70))

{:ok, result4} = Yggdrasil.run(agent, "How many times does 'the' appear in 'the quick brown fox jumps over the lazy dog'?")
IO.puts(result4.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 5: Case conversion
IO.puts("Test 5: Case conversion")
IO.puts("-" |> String.duplicate(70))

{:ok, result5} = Yggdrasil.run(agent, "Convert 'hello world' to uppercase")
IO.puts(result5.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 6: Capitalize
IO.puts("Test 6: Capitalize words")
IO.puts("-" |> String.duplicate(70))

{:ok, result6} = Yggdrasil.run(agent, "Capitalize each word in 'hello world from elixir'")
IO.puts(result6.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 7: Substring extraction
IO.puts("Test 7: Extract substring")
IO.puts("-" |> String.duplicate(70))

{:ok, result7} = Yggdrasil.run(agent, "Extract characters from position 0 to 5 in 'Hello World'")
IO.puts(result7.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 8: Contains check
IO.puts("Test 8: Check if text contains pattern")
IO.puts("-" |> String.duplicate(70))

{:ok, result8} = Yggdrasil.run(agent, "Does 'Hello World' contain 'World'?")
IO.puts(result8.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 9: Reverse text
IO.puts("Test 9: Reverse text")
IO.puts("-" |> String.duplicate(70))

{:ok, result9} = Yggdrasil.run(agent, "Reverse the text 'Hello World'")
IO.puts(result9.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 10: Extract words
IO.puts("Test 10: Extract words")
IO.puts("-" |> String.duplicate(70))

{:ok, result10} = Yggdrasil.run(agent, "Extract all words from 'The quick brown fox, jumps over the lazy dog!'")
IO.puts(result10.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 11: Palindrome check
IO.puts("Test 11: Check palindrome")
IO.puts("-" |> String.duplicate(70))

{:ok, result11} = Yggdrasil.run(agent, "Is 'racecar' a palindrome?")
IO.puts(result11.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 12: Extract numbers
IO.puts("Test 12: Extract numbers")
IO.puts("-" |> String.duplicate(70))

{:ok, result12} = Yggdrasil.run(agent, "Extract all numbers from 'I have 3 apples, 5 oranges, and 2.5 kg of grapes'")
IO.puts(result12.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 13: Complex query
IO.puts("Test 13: Complex string operation")
IO.puts("-" |> String.duplicate(70))

{:ok, result13} = Yggdrasil.run(agent,
  "Take 'hello world', convert to uppercase, then count how many times 'L' appears")
IO.puts(result13.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("✅ Demo complete!")
IO.puts("")
IO.puts("Available String Tools:")
IO.puts("  • string_length - Get length of text")
IO.puts("  • replace_text - Replace pattern in text")
IO.puts("  • split_text - Split text by delimiter")
IO.puts("  • join_text - Join parts with delimiter")
IO.puts("  • count_occurrences - Count pattern occurrences")
IO.puts("  • to_uppercase - Convert to uppercase")
IO.puts("  • to_lowercase - Convert to lowercase")
IO.puts("  • capitalize_text - Capitalize words/sentences")
IO.puts("  • trim_text - Remove whitespace")
IO.puts("  • substring - Extract substring")
IO.puts("  • contains - Check if contains pattern")
IO.puts("  • starts_with - Check if starts with prefix")
IO.puts("  • ends_with - Check if ends with suffix")
IO.puts("  • reverse_text - Reverse text")
IO.puts("  • repeat_text - Repeat text N times")
IO.puts("  • extract_words - Extract words from text")
IO.puts("  • pad_text - Pad text to length")
IO.puts("  • is_palindrome - Check if palindrome")
IO.puts("  • extract_numbers - Extract numbers from text")
IO.puts("")
IO.puts("Features:")
IO.puts("  ✓ Case-sensitive and case-insensitive operations")
IO.puts("  ✓ Pattern matching and replacement")
IO.puts("  ✓ Text transformation (upper/lower/capitalize)")
IO.puts("  ✓ String analysis (length, word count, palindrome)")
IO.puts("  ✓ Number extraction and parsing")
IO.puts("")
