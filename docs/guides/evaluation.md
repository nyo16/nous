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
  id: "math",
  input: "What is 2+2?",
  expected: "4",
  eval_type: :exact_match
)
```

#### :fuzzy_match

String similarity above threshold (uses Jaro-Winkler distance):

```elixir
TestCase.new(
  id: "spelling",
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
  id: "fruits",
  input: "List 3 fruits",
  expected: %{contains: ["apple", "banana"]},
  eval_type: :contains
)

# Regex patterns. Exactly one mode applies per test case: the first of
# :contains, :contains_any, :regex found in the map wins, so don't combine them.
TestCase.new(
  id: "email_format",
  input: "Write an email",
  expected: %{regex: ["\\d{4}"]},  # Must contain a 4-digit number
  eval_type: :contains
)

# Any one match is enough
TestCase.new(
  id: "greeting_any",
  input: "Say hello",
  expected: %{contains_any: ["hello", "hi"]},
  eval_type: :contains
)

# Matching is case-insensitive unless you say otherwise
TestCase.new(
  id: "constant_name",
  input: "Name the retry constant",
  expected: %{contains: ["MAX_RETRIES"]},
  eval_type: :contains,
  eval_config: %{case_insensitive: false}
)
```

#### :tool_usage

Verify correct tools were called:

```elixir
TestCase.new(
  id: "tip_calculation",
  input: "Calculate 15% tip on $50",
  expected: %{
    tools_called: ["calculate"],      # These tools must be called
    tools_not_called: ["search"],     # These must NOT be called
    min_tool_calls: 1,                # Bounds on the total number of calls
    max_tool_calls: 3,
    output_contains: ["7.5"],         # Substrings the final output must contain
    tool_args: %{                     # Arguments at least one call must carry
      "calculate" => %{"amount" => 50}
    }
  },
  eval_type: :tool_usage,
  agent_config: [tools: [&MyApp.Tools.calculate/2]]
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
  id: "extract_person",
  input: "Extract: John is 30 years old",
  expected: %{schema: Person},
  eval_type: :schema,
  agent_config: [output_type: Person]
)
```

#### :llm_judge

Use an LLM to judge quality:

```elixir
TestCase.new(
  id: "haiku",
  input: "Write a haiku about coding",
  expected: %{
    criteria: """
    Evaluate if this is a valid haiku:
    1. Has 3 lines
    2. Follows 5-7-5 syllable pattern
    3. Relates to coding/programming
    """,
    rubric: "5: valid haiku on topic, 3: right shape but off topic, 1: neither"
  },
  eval_type: :llm_judge,
  eval_config: %{
    judge_model: "lmstudio:ministral-3-14b-reasoning",
    pass_threshold: 0.7    # Minimum normalized score to pass (default: 0.6)
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
  id: "sentiment",
  input: "Review: This product is amazing!",
  expected: %{sentiment: :positive},
  eval_type: :custom,
  eval_config: %{evaluator: MyApp.SentimentEvaluator}
)
```

## YAML Test Definitions

Suites can live in YAML instead of Elixir. `Nous.Eval.Suite.from_yaml/1` loads one file (`from_yaml!/1` raises instead of returning a tuple); `Nous.Eval.Suite.from_directory/1` loads every `*.yaml` and `*.yml` file in a directory. Failures come back as `{:error, {:yaml_load_error, path, reason}}`.

### Suite keys

Every top-level key is optional, and unknown keys are ignored.

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `name` | string | the filename without its extension | Suite name. |
| `description` | string | `nil` | Free text. |
| `test_cases` | list of maps | `[]` | See below. An empty suite loads, but `Nous.Eval.Suite.validate/1` rejects it. |
| `default_model` | string | `nil` | `"provider:model"`. Used when a case sets no `agent_config.model`. |
| `default_instructions` | string | `nil` | Agent instructions, unless a case sets `agent_config.instructions`. |
| `default_timeout` | integer (ms) | `30000` | Budget for a parallel run's task stream (plus a 5s margin). It is *not* a per-case fallback for YAML suites — the loader always gives a case a `timeout`. |
| `parallelism` | integer | `1` | Concurrent test cases; anything above `1` runs them through `Task.Supervisor.async_stream_nolink/4`. |
| `retry_failed` | integer | `0` | Retry attempts per failing case. |
| `metadata` | map | `{}` | Carried through untouched; its keys stay strings. |

The `setup` and `teardown` fields of `%Nous.Eval.Suite{}` hold functions, so they have no YAML representation — build the suite in Elixir when you need them.

### Test case keys

`id` and `input` are required; a case missing either aborts the whole load with `{:error, "Missing required field: :id"}`.

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `id` | string | — (**required**) | Unique within the suite; run through `to_string/1`. |
| `input` | string | — (**required**) | The prompt sent to the agent. |
| `name` | string | `nil` | Display name; the `id` is shown when absent. |
| `description` | string | `nil` | Free text. |
| `expected` | scalar, list, or map | `nil` | Shape depends on `eval_type` — see [Evaluators](#evaluators). Its keys stay strings, and every built-in evaluator accepts both string and atom keys. |
| `eval_type` | string | `contains` | One of `exact_match`, `fuzzy_match`, `contains`, `tool_usage`, `schema`, `llm_judge`, `custom`. |
| `eval_config` | map | `{}` | Evaluator options (`threshold`, `case_insensitive`, `judge_model`, `pass_threshold`, …). Keys are atomized recursively, but only when the atom already exists; anything else stays a string and the evaluator ignores it. |
| `tags` | list of strings | `[]` | Drives `--tags` / `--exclude`. Each tag becomes an atom **only if that atom already exists** in the VM; unknown tags are dropped silently. |
| `deps` | map | `{}` | Passed as `deps:` to the agent run. Keys are *not* atomized — they arrive as strings. |
| `agent_config` | map | `{}` | Merged into the `Nous.new/2` options. Keys are atomized when the atom exists and dropped when it does not. `model` overrides `default_model`; `instructions` overrides `default_instructions`. |
| `timeout` | integer (ms) | `30000` | Per-case timeout. Always set by the loader, so it wins over the suite's `default_timeout`. |
| `metadata` | map | `{}` | Untouched. |

Two `%Nous.Eval.TestCase{}` fields can never come from YAML. `tools` is always `nil` after a YAML load, and `agent_config.tools` is no substitute — YAML gives you strings, while `Nous.new/2` needs functions, `%Nous.Tool{}` structs, or tool modules, and anything else raises. A case that must exercise tools has to be defined in Elixir, or the tools attached to the loaded suite afterwards. `input` is likewise limited to a string; the message-list form needs `Nous.Message` structs.

### A complete suite

```yaml
# test/eval/suites/basic.yaml
name: basic_agent_tests
description: Smoke tests for the support agent
default_model: lmstudio:ministral-3-14b-reasoning
default_instructions: Be concise and helpful.
default_timeout: 30000
parallelism: 2
retry_failed: 1
metadata:
  owner: platform-team

test_cases:
  - id: greeting
    name: Basic Greeting
    description: The agent should greet back.
    input: Say hello to the user
    expected:
      contains_any:
        - hello
        - hi
    eval_type: contains
    eval_config:
      case_insensitive: true
    tags:
      - basic
    timeout: 20000

  - id: math
    input: What is 15 + 27?
    expected: "42"
    eval_type: fuzzy_match
    eval_config:
      threshold: 0.9

  # The tools themselves must be attached in Elixir — see the note above.
  - id: tip_calculation
    input: Calculate 15% tip on $50
    expected:
      tools_called:
        - calculate
      output_contains:
        - "7.5"
    eval_type: tool_usage

  - id: explanation_quality
    input: Explain recursion to a beginner
    expected:
      criteria: Is the explanation correct, concise, and free of jargon?
    eval_type: llm_judge
    eval_config:
      judge_model: lmstudio:ministral-3-14b-reasoning
      pass_threshold: 0.7
    agent_config:
      model: lmstudio:qwen3
      instructions: Explain things simply.
    deps:
      account_id: acct_123
```

Load and run:

```elixir
{:ok, suite} = Nous.Eval.Suite.from_yaml("test/eval/suites/basic.yaml")
{:ok, result} = Nous.Eval.run(suite)
```

`mix nous.eval --suite test/eval/suites/basic.yaml` does the same from the shell.

### What YAML cannot express

- **`eval_type: custom` does not work from a YAML file.** The evaluator is read from `eval_config.evaluator` and must be a module atom; YAML values are never converted, so you get the string `"MyApp.SentimentEvaluator"` and the run fails. Define custom-evaluator cases in Elixir.
- **`eval_type: schema` has the same limitation** — `expected.schema` must be a real module.
- An unrecognised `eval_type` falls back to `contains` instead of failing the load, so a typo quietly becomes a different assertion.

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
