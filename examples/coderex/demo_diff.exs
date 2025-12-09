# Demo script to show the diff formatter in action
# Run with: mix run demo_diff.exs

alias Coderex.Tools.FileTools

# Create a temp directory for testing
tmp_dir = Path.join(System.tmp_dir!(), "coderex_demo_#{:rand.uniform(10000)}")
File.mkdir_p!(tmp_dir)

# Create a sample file
sample_code = """
defmodule Calculator do
  @moduledoc "A simple calculator"

  def add(a, b) do
    a + b
  end

  def subtract(a, b) do
    a - b
  end
end
"""

test_file = Path.join(tmp_dir, "calculator.ex")
File.write!(test_file, sample_code)

IO.puts("=" |> String.duplicate(60))
IO.puts("CODEREX DIFF FORMATTER DEMO")
IO.puts("=" |> String.duplicate(60))

# Create a context
ctx = %{deps: %{cwd: tmp_dir, show_diff: true}}

# Show a preview of changes
diff = """
------- SEARCH
  def add(a, b) do
    a + b
  end
=======
  @doc "Adds two numbers together"
  def add(a, b) do
    a + b
  end
+++++++ REPLACE
------- SEARCH
  def subtract(a, b) do
    a - b
  end
=======
  @doc "Subtracts b from a"
  def subtract(a, b) do
    a - b
  end

  @doc "Multiplies two numbers"
  def multiply(a, b) do
    a * b
  end
+++++++ REPLACE
"""

IO.puts("\n1. PREVIEW (without applying):")
IO.puts("-" |> String.duplicate(40))

result = FileTools.preview_edit(ctx, %{"path" => "calculator.ex", "diff" => diff})
IO.puts(result.preview)

IO.puts("\n2. APPLY THE EDIT:")
IO.puts("-" |> String.duplicate(40))

result = FileTools.edit_file(ctx, %{"path" => "calculator.ex", "diff" => diff})
IO.puts(result.diff_output)

IO.puts("\n3. FINAL FILE CONTENT:")
IO.puts("-" |> String.duplicate(40))

final = FileTools.read_file(ctx, %{"path" => "calculator.ex"})
IO.puts(final.content)

# Cleanup
File.rm_rf!(tmp_dir)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Demo complete!")
