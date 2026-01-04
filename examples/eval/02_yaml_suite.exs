# YAML Suite Example
#
# This example shows how to load and run test suites defined in YAML files.
#
# Run with: mix run examples/eval/02_yaml_suite.exs

alias Nous.Eval
alias Nous.Eval.{Suite, Reporter}

# Create a sample YAML file
yaml_content = """
name: yaml_example_suite
default_model: lmstudio:ministral-3-14b-reasoning
default_instructions: Be concise and helpful.

test_cases:
  - id: greeting_test
    name: Greeting Test
    input: "Say hi!"
    expected:
      contains:
        - hello
        - hi
        - hey
    eval_type: contains
    tags:
      - basic
      - greeting

  - id: list_colors
    name: List Colors
    input: "Name 3 primary colors, one per line"
    expected:
      contains:
        - red
        - blue
        - yellow
    eval_type: contains
    tags:
      - basic
      - knowledge

  - id: math_test
    name: Simple Addition
    input: "What is 100 + 50? Reply with just the number."
    expected: "150"
    eval_type: fuzzy_match
    eval_config:
      threshold: 0.9
    agent_config:
      model_settings:
        temperature: 0.1
    tags:
      - math
"""

# Write to temp file
yaml_path = Path.join(System.tmp_dir!(), "example_suite.yaml")
File.write!(yaml_path, yaml_content)

IO.puts("Loading suite from: #{yaml_path}\n")

# Load suite from YAML
case Suite.from_yaml(yaml_path) do
  {:ok, suite} ->
    IO.puts("Loaded suite: #{suite.name}")
    IO.puts("Test cases: #{Suite.count(suite)}")
    IO.puts("Tags: #{inspect(Suite.tags(suite))}\n")

    # Run all tests
    IO.puts("Running all tests...")
    {:ok, result} = Eval.run(suite, timeout: 60_000)
    Reporter.print(result)

    # Run only tests with specific tag
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Running only 'basic' tagged tests...\n")

    {:ok, filtered_result} = Eval.run(suite,
      tags: [:basic],
      timeout: 60_000
    )
    Reporter.print(filtered_result)

  {:error, reason} ->
    IO.puts("Failed to load suite: #{inspect(reason)}")
end

# Cleanup
File.rm(yaml_path)
