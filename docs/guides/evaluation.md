# Evaluation Framework Guide

The Nous evaluation framework provides comprehensive testing, benchmarking, and optimization capabilities for AI agents. This guide covers all aspects of using the framework.

## Overview

The evaluation framework enables you to:

- **Test agents** with various scenarios and measure correctness
- **Collect metrics** including latency, token usage, and cost
- **Compare configurations** with A/B testing
- **Optimize parameters** using grid search or Bayesian optimization
- **Define tests in YAML** or Elixir for flexibility

## Quick Start

```elixir
# Define a test suite
suite = Nous.Eval.Suite.new(
  name: "my_tests",
  default_model: "lmstudio:ministral-3-14b-reasoning",
  test_cases: [
    Nous.Eval.TestCase.new(
      id: "greeting",
      input: "Say hello",
      expected: %{contains: ["hello", "hi"]},
      eval_type: :contains
    )
  ]
)

# Run evaluation
{:ok, result} = Nous.Eval.run(suite)

# Print results
Nous.Eval.Reporter.print(result)
```

## Core Concepts

### Test Cases

A `TestCase` represents a single test scenario:

```elixir
Nous.Eval.TestCase.new(
  id: "unique_id",           # Required: unique identifier
  name: "Descriptive Name",  # Optional: human-readable name
  input: "User prompt",      # Required: the input to test
  expected: %{...},          # Required: expected result (format depends on eval_type)
  eval_type: :contains,      # Required: evaluator to use
  eval_config: %{},          # Optional: evaluator-specific config
  tags: [:basic, :tool],     # Optional: tags for filtering
  agent_config: [            # Optional: agent configuration
    instructions: "You are helpful",
    model_settings: %{temperature: 0.3}
  ],
  timeout: 30_000            # Optional: timeout in ms
)
```

### Suites

A `Suite` is a collection of test cases:

```elixir
Nous.Eval.Suite.new(
  name: "suite_name",
  default_model: "lmstudio:model",
  default_instructions: "Be helpful",
  test_cases: [...]
)
```

### Results

Evaluation results include:

```elixir
%{
  suite_name: "basic_tests",
  total: 10,
  pass_count: 8,
  fail_count: 2,
  pass_rate: 0.8,
  aggregate_score: 0.85,
  test_results: [...],
  metrics_summary: %{
    latency: %{p50: 1200, p95: 2500, p99: 3000},
    tokens: %{input: 500, output: 800, total: 1300},
    cost: %{total: 0.002}
  }
}
```

## Evaluators

### Built-in Evaluators

#### :exact_match

Output must exactly match expected string:

```elixir
TestCase.new(
  input: "What is 2+2?",
  expected: "4",
  eval_type: :exact_match
)
```

#### :fuzzy_match

String similarity above threshold (uses Jaro-Winkler distance):

```elixir
TestCase.new(
  input: "Spell color",
  expected: "colour",
  eval_type: :fuzzy_match,
  eval_config: %{threshold: 0.85}  # Default: 0.8
)
```

#### :contains

Output must contain specified substrings or patterns:

```elixir
# Simple contains
TestCase.new(
  input: "List 3 fruits",
  expected: %{contains: ["apple", "banana"]},
  eval_type: :contains
)

# With regex patterns
TestCase.new(
  input: "Write an email",
  expected: %{
    contains: ["Subject:", "Dear"],
    patterns: ["\\d{4}"]  # Must contain 4-digit number
  },
  eval_type: :contains
)

# All must match (default) vs any
TestCase.new(
  expected: %{contains: ["hello", "hi"], match_all: false},
  eval_type: :contains
)
```

#### :tool_usage

Verify correct tools were called:

```elixir
TestCase.new(
  input: "Calculate 15% tip on $50",
  expected: %{
    tools_called: ["calculate"],      # These tools must be called
    tools_not_called: ["search"],     # These must NOT be called
    call_count: %{calculate: 1},      # Expected call counts
    args_contain: %{                   # Arguments validation
      calculate: %{amount: 50}
    }
  },
  eval_type: :tool_usage,
  agent_config: [tools: [CalculatorTool]]
)
```

#### :schema

Validate structured output against Ecto schema:

```elixir
defmodule Person do
  use Ecto.Schema
  embedded_schema do
    field :name, :string
    field :age, :integer
  end
end

TestCase.new(
  input: "Extract: John is 30 years old",
  expected: %{schema: Person},
  eval_type: :schema,
  agent_config: [response_schema: Person]
)
```

#### :llm_judge

Use an LLM to judge quality:

```elixir
TestCase.new(
  input: "Write a haiku about coding",
  expected: %{
    criteria: """
    Evaluate if this is a valid haiku:
    1. Has 3 lines
    2. Follows 5-7-5 syllable pattern
    3. Relates to coding/programming
    """,
    min_score: 0.7
  },
  eval_type: :llm_judge,
  eval_config: %{
    judge_model: "lmstudio:ministral-3-14b-reasoning"
  }
)
```

### Custom Evaluators

Implement the `Nous.Eval.Evaluator` behaviour:

```elixir
defmodule MyApp.SentimentEvaluator do
  @behaviour Nous.Eval.Evaluator

  @impl true
  def evaluate(actual, expected, config) do
    # actual: %{output: "...", agent_result: ...}
    # expected: %{sentiment: :positive}
    # config: %{} evaluator config

    output = actual.output
    sentiment = analyze_sentiment(output)

    passed = sentiment == expected.sentiment
    score = if passed, do: 1.0, else: 0.0

    %{
      score: score,
      passed: passed,
      reason: unless(passed, do: "Expected #{expected.sentiment}, got #{sentiment}"),
      details: %{detected_sentiment: sentiment}
    }
  end

  defp analyze_sentiment(text) do
    # Your sentiment analysis logic
  end
end

# Usage
TestCase.new(
  input: "Review: This product is amazing!",
  expected: %{sentiment: :positive},
  eval_type: :custom,
  eval_config: %{evaluator: MyApp.SentimentEvaluator}
)
```

## YAML Test Definitions

Define tests in YAML for easier management:

```yaml
# test/eval/suites/basic.yaml
name: basic_agent_tests
default_model: lmstudio:ministral-3-14b-reasoning
default_instructions: Be concise and helpful.

test_cases:
  - id: greeting
    name: Basic Greeting
    input: "Say hello to the user"
    expected:
      contains:
        - hello
        - hi
    eval_type: contains
    tags:
      - basic
      - greeting

  - id: math
    input: "What is 15 + 27?"
    expected: "42"
    eval_type: fuzzy_match
    eval_config:
      threshold: 0.9

  - id: tool_test
    input: "Calculate 20% of 150"
    expected:
      tools_called:
        - calculator
    eval_type: tool_usage
    agent_config:
      tools:
        - calculator
```

Load and run:

```elixir
{:ok, suite} = Nous.Eval.Suite.from_yaml("test/eval/suites/basic.yaml")
{:ok, result} = Nous.Eval.run(suite)
```

## Running Evaluations

### Mix Task

```bash
# Run all suites from default directory
mix nous.eval

# Run specific suite
mix nous.eval --suite test/eval/suites/basic.yaml

# Filter by tags
mix nous.eval --tags basic,tool

# Exclude tags
mix nous.eval --exclude slow,stress

# Override model
mix nous.eval --model lmstudio:qwen-7b

# Parallel execution
mix nous.eval --parallel 4

# JSON output
mix nous.eval --format json --output results.json
```

### Programmatic

```elixir
# Basic run
{:ok, result} = Nous.Eval.run(suite)

# With options
{:ok, result} = Nous.Eval.run(suite,
  model: "lmstudio:different-model",
  parallelism: 4,
  timeout: 60_000,
  tags: [:basic],
  retry_failed: 2
)

# A/B testing
{:ok, comparison} = Nous.Eval.run_ab(suite,
  config_a: [model_settings: %{temperature: 0.3}],
  config_b: [model_settings: %{temperature: 0.7}]
)

# Single test case
{:ok, result} = Nous.Eval.run_case(test_case, model: "lmstudio:model")
```

## Parameter Optimization

### Grid Search

Exhaustive search over all parameter combinations:

```elixir
alias Nous.Eval.Optimizer
alias Nous.Eval.Optimizer.Parameter

params = [
  Parameter.float(:temperature, 0.0, 1.0, step: 0.2),
  Parameter.integer(:max_tokens, 256, 1024, step: 256)
]

{:ok, result} = Optimizer.optimize(suite, params,
  strategy: :grid_search,
  metric: :score,
  max_trials: 50
)

IO.puts("Best config: #{inspect(result.best_config)}")
IO.puts("Best score: #{result.best_score}")
```

### Bayesian Optimization

Smart search that learns from previous trials:

```elixir
params = [
  Parameter.float(:temperature, 0.0, 1.0),
  Parameter.float(:top_p, 0.5, 1.0),
  Parameter.integer(:max_tokens, 256, 2048)
]

{:ok, result} = Optimizer.optimize(suite, params,
  strategy: :bayesian,
  n_trials: 30,
  n_initial: 10,  # Random trials before optimization
  gamma: 0.25,    # Top 25% are "good"
  metric: :score
)
```

### Random Search

Random sampling with optional Latin Hypercube Sampling:

```elixir
{:ok, result} = Optimizer.optimize(suite, params,
  strategy: :random,
  n_trials: 50,
  latin_hypercube: true  # Better coverage
)
```

### Mix Task

```bash
# Basic optimization
mix nous.optimize --suite basic.yaml

# Bayesian with 50 trials
mix nous.optimize --suite basic.yaml --strategy bayesian --trials 50

# Minimize latency
mix nous.optimize --suite basic.yaml --metric latency_p50 --minimize

# Custom parameters
mix nous.optimize --suite basic.yaml --params params.exs
```

Create `params.exs`:

```elixir
alias Nous.Eval.Optimizer.Parameter

[
  Parameter.float(:temperature, 0.0, 1.0, step: 0.1),
  Parameter.choice(:model, [
    "lmstudio:ministral-3-14b-reasoning",
    "lmstudio:qwen-7b"
  ])
]
```

## Metrics

### Collected Metrics

The framework automatically collects:

| Metric | Description |
|--------|-------------|
| `latency.total` | Total request duration |
| `latency.first_token` | Time to first token (streaming) |
| `latency.p50/p95/p99` | Latency percentiles |
| `tokens.input` | Input tokens used |
| `tokens.output` | Output tokens generated |
| `tokens.total` | Total tokens |
| `cost.total` | Estimated cost |
| `tool_calls` | Number of tool invocations |
| `iterations` | Agent loop iterations |

### Custom Metrics

Add custom metrics via telemetry:

```elixir
:telemetry.execute(
  [:nous, :eval, :custom_metric],
  %{value: 42},
  %{test_id: "my_test"}
)
```

## Reporting

### Console

```elixir
Nous.Eval.Reporter.print(result)
# Or detailed
Nous.Eval.Reporter.print_detailed(result)
```

Output:
```
══════════════════════════════════════════════════════════════════
                    Evaluation Results: basic_tests
══════════════════════════════════════════════════════════════════

  Total: 10 | Passed: 8 | Failed: 2 | Pass Rate: 80.0%

  Metrics:
    Latency (p50/p95/p99): 1.2s / 2.5s / 3.0s
    Tokens (in/out/total): 500 / 800 / 1300
    Estimated Cost: $0.002

  Failed Tests:
    ✗ test_complex_reasoning: Expected output to contain 'specific phrase'
    ✗ test_edge_case: Timeout after 30000ms
```

### JSON Export

```elixir
json = Nous.Eval.Reporter.Json.to_json(result)
File.write!("results.json", json)
```

### Markdown

```elixir
md = Nous.Eval.Reporter.to_markdown(result)
File.write!("results.md", md)
```

## ExUnit Integration

Use the evaluation framework in ExUnit tests:

```elixir
defmodule MyAgentTest do
  use ExUnit.Case

  alias Nous.Eval.{TestCase, Runner}

  @model "lmstudio:ministral-3-14b-reasoning"

  test "agent handles basic greeting" do
    test_case = TestCase.new(
      id: "greeting",
      input: "Hello!",
      expected: %{contains: ["hello", "hi"]},
      eval_type: :contains
    )

    {:ok, result} = Runner.run_case(test_case, model: @model)

    assert result.passed, "Expected test to pass: #{result.reason}"
    assert result.score >= 0.8
  end

  test "agent uses calculator tool" do
    test_case = TestCase.new(
      id: "calculator",
      input: "What is 15% of 200?",
      expected: %{tools_called: ["calculator"]},
      eval_type: :tool_usage,
      agent_config: [tools: [CalculatorTool]]
    )

    {:ok, result} = Runner.run_case(test_case, model: @model)

    assert result.passed
  end
end
```

## Best Practices

### Test Design

1. **Use descriptive IDs**: `greeting_basic` not `test_1`
2. **Tag appropriately**: Use tags for filtering (`basic`, `slow`, `tool`)
3. **Set realistic timeouts**: Account for model inference time
4. **Test edge cases**: Empty input, long input, special characters

### Performance

1. **Run in parallel** when tests are independent
2. **Use caching** for repeated evaluations
3. **Set appropriate timeouts** to fail fast
4. **Use random/bayesian** over grid search for large spaces

### CI/CD Integration

```yaml
# .github/workflows/eval.yml
- name: Run evaluations
  run: mix nous.eval --format json --output eval-results.json

- name: Check pass rate
  run: |
    PASS_RATE=$(jq '.pass_rate' eval-results.json)
    if (( $(echo "$PASS_RATE < 0.9" | bc -l) )); then
      echo "Pass rate below threshold: $PASS_RATE"
      exit 1
    fi
```

## Troubleshooting

### Common Issues

**Timeout errors**
- Increase timeout: `timeout: 60_000`
- Use a faster model for testing
- Add concise instructions to reduce output

**Flaky tests**
- Use lower temperature: `model_settings: %{temperature: 0.1}`
- Use fuzzy matching instead of exact
- Add retry: `retry_failed: 2`

**Memory issues**
- Reduce parallelism
- Process results in batches
- Clear accumulated results

### Debug Mode

```elixir
{:ok, result} = Nous.Eval.run(suite, verbose: true)
```

Verbose mode prints:
- Each test case as it runs
- Tool calls made
- Token counts
- Timing information

## API Reference

See HexDocs for complete API documentation:

- `Nous.Eval` - Main entry point
- `Nous.Eval.TestCase` - Test case struct
- `Nous.Eval.Suite` - Test suite struct
- `Nous.Eval.Runner` - Test runner
- `Nous.Eval.Evaluator` - Evaluator behaviour
- `Nous.Eval.Optimizer` - Parameter optimization
- `Nous.Eval.Reporter` - Result reporting
