# Contributing to Nous

Thanks for your interest in contributing. This document covers everything
you need to develop, test, and submit changes to Nous.

## Prerequisites

- **Elixir** 1.18+ (uses the built-in `JSON` module)
- **OTP** 27+

## Setup

```bash
git clone https://github.com/nyo16/nous.git
cd nous
mix deps.get
mix compile
```

## Running Tests

```bash
# Run all tests
mix test

# Run a specific test file
mix test test/nous/decisions_test.exs

# Run tests with verbose output
mix test --trace
```

## Code Quality

```bash
# Check formatting
mix format --check-formatted

# Run credo linter
mix credo --strict

# Run dialyzer (first run builds PLT, takes a few minutes)
mix dialyzer

# All checks at once
mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && mix test
```

## Configuration

API keys are configured via environment variables:

```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
export GROQ_API_KEY="gsk_..."
# See config/config.exs for all supported providers
```

For local models (no API key needed):

```bash
# LM Studio — start the server, then:
agent = Nous.new("lmstudio:qwen3")

# Ollama — start the server, then:
agent = Nous.new("ollama:llama2")

# LlamaCpp — load a GGUF model directly (requires llama_cpp_ex dep):
:ok = LlamaCppEx.init()
{:ok, llm} = LlamaCppEx.load_model("model.gguf", n_gpu_layers: -1)
agent = Nous.new("llamacpp:local", llamacpp_model: llm)

# For thinking models (Qwen3, DeepSeek, etc.), disable <think> tags:
agent = Nous.new("llamacpp:local",
  llamacpp_model: llm,
  model_settings: %{enable_thinking: false}
)
```

## Running Examples

```bash
# Run any example script
mix run examples/01_hello_world.exs

# Run with a specific provider
OPENAI_API_KEY=sk-... mix run examples/02_with_tools.exs
```

## Generating Docs

```bash
mix docs
open doc/index.html
```

## Project Structure

```
lib/nous/
├── agent.ex              # Agent struct and builder
├── agent_runner.ex       # Core execution loop
├── agent_server.ex       # GenServer wrapper for supervised agents
├── fallback.ex           # Fallback model chain support
├── decisions/            # Decision graph (goals, decisions, outcomes)
│   ├── store/            # Store backends (ETS, DuckDB)
│   ├── node.ex           # Node struct
│   ├── edge.ex           # Edge struct
│   ├── tools.ex          # LLM-callable decision tools
│   └── context_builder.ex
├── knowledge_base/       # LLM-compiled wiki knowledge base
│   ├── store/            # Store backends (ETS)
│   ├── tools.ex          # 9 KB agent tools
│   ├── workflows.ex      # DAG pipelines (ingest, update, health, generate)
│   └── prompts.ex        # LLM prompt templates
├── memory/               # Persistent memory with hybrid search
│   ├── store/            # Store backends (ETS, SQLite, DuckDB, etc.)
│   ├── embedding/        # Embedding providers
│   └── tools.ex          # LLM-callable memory tools
├── plugins/              # Agent plugins
│   ├── decisions.ex      # Decision graph plugin
│   ├── memory.ex         # Memory plugin
│   ├── team_tools.ex     # Team communication plugin
│   ├── sub_agent.ex      # Sub-agent delegation
│   └── human_in_the_loop.ex
├── providers/            # LLM provider adapters
├── teams/                # Multi-agent team orchestration
│   ├── coordinator.ex    # Team lifecycle management
│   ├── shared_state.ex   # Per-team shared state (ETS)
│   ├── rate_limiter.ex   # Budget and rate limiting
│   ├── role.ex           # Role-based tool scoping
│   └── comms.ex          # PubSub topic helpers
├── tool/                 # Tool system
│   ├── behaviour.ex      # Tool behaviour
│   ├── schema.ex         # Declarative tool DSL
│   └── registry.ex       # Tool collection and filtering
├── research/             # Deep research system
└── eval/                 # Evaluation framework
```

## Submitting changes

```bash
# Fork, clone, then:
mix deps.get
mix test                     # Make sure tests pass
mix format                   # Format your code
mix credo --strict           # Check for issues
# Open a PR against master
```

See [CHANGELOG.md](CHANGELOG.md) for recent changes.

## Security

Nous has project-wide security rules that are non-negotiable. Code that
breaks these will be rejected on review:

1. **Never `String.to_atom/1` on untrusted input.** Use
   `String.to_existing_atom/1` with rescue, or pattern-match on a
   whitelist of literal strings.
2. **Tools requiring approval are rejected without an `:approval_handler`.**
   `Bash`, `FileWrite`, `FileEdit` need one wired in `RunContext` or they
   refuse to run.
3. **File tools enforce a workspace root** via `PathGuard`. Don't bypass it.
4. **HTTP from agents goes through `UrlGuard`.** Don't make raw `Req.get/1`
   calls from a tool to a user-controlled URL.
5. **`PromptTemplate` rejects `<% ... %>` blocks** — only `<%= @var %>`
   substitution is allowed (RCE prevention).
6. **Sub-agent deps don't auto-forward.** Declare which deps a sub-agent
   sees with `:sub_agent_shared_deps, [:key1, :key2]`.

The full text and rationale for each rule lives in
[AGENTS.md](AGENTS.md#critical-rules-security--correctness).
