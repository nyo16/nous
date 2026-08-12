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
├── agent.ex                  # Agent struct and builder
├── agent_dynamic_supervisor.ex # DynamicSupervisor for AgentServer processes
├── agent_registry.ex         # Registry for agent lookup by session ID
├── agent_runner.ex           # Core execution loop
├── agent_server.ex           # GenServer wrapper for supervised agents
├── application.ex            # OTP application and supervision tree
├── decisions.ex              # Decision graph top-level API
├── errors.ex                 # Error types
├── eval.ex                   # Evaluation framework entry point
├── fallback.ex               # Fallback model chain support
├── hook.ex                   # Lifecycle interceptor structs
├── json.ex                   # Internal JSON helpers
├── knowledge_base.ex         # Knowledge base top-level API
├── llm.ex                    # Direct model calls without agents
├── memory.ex                 # Memory system top-level API
├── message.ex                # Conversation message struct
├── messages.ex               # Conversation/message-list utilities
├── model.ex                  # Provider + model configuration
├── model_dispatcher.ex       # Routes requests to provider modules
├── output_schema.ex          # Structured output
├── permissions.ex            # Tool-level permission policy engine
├── persistence.ex            # Context persistence API
├── plugin.ex                 # Plugin behaviour
├── prompt_template.ex        # Safe prompt templates
├── provider.ex               # Provider behaviour
├── pubsub.ex                 # PubSub abstraction and topic helpers
├── react_agent.ex            # ReAct agent wrapper
├── research.ex               # Deep research top-level API
├── run_context.ex            # Context passed to tools and dynamic prompts
├── skill.ex                  # Skill struct and API
├── stream_normalizer.ex      # Stream chunk normalization behaviour
├── teams.ex                  # Multi-agent team orchestration API
├── telemetry.ex              # Telemetry events
├── tool.ex                   # Tool struct
├── tool_call.ex              # Tool-call field access helpers
├── tool_executor.ex          # Tool execution with retries and timeouts
├── tool_schema.ex            # Tool -> provider schema conversion
├── transcript.ex             # Conversation history compaction
├── types.ex                  # Core type definitions
├── usage.ex                  # Token/cost usage tracking
├── util.ex                   # Shared internal helpers
├── workflow.ex               # Workflow DAG top-level API
├── agent/                    # Context, callbacks, agent behaviour
├── agent_runner/             # Runner internals (prompt assembly, dispatch,
│                             #   iteration loop, streaming, tool execution)
├── agents/                   # Built-in behaviours (basic, ReAct, KB)
├── decisions/                # Decision graph (nodes, edges, store backends,
│                             #   context builder)
├── errors/                   # Error base and retry info
├── eval/                     # Evaluators, metrics, optimizer, reporters,
│                             #   suites, YAML loader
├── hook/                     # Hook registry and runner
├── http/                     # HTTP + streaming backend behaviours and impls
├── knowledge_base/           # LLM-compiled wiki (entries, links, documents,
│                             #   tools, workflows, prompts, store backends)
├── memory/                   # Persistent memory (search, scoring, scopes,
│                             #   tools, store and embedding backends)
├── message/                  # Multimodal content parts
├── messages/                 # Per-provider message marshalling
├── output_schema/            # `use Nous.OutputSchema` macro and validator
├── permissions/              # Permission policy struct
├── persistence/              # Persistence backends (ETS)
├── plugins/                  # Agent plugins (memory, decisions, KB, skills,
│                             #   sub-agent, teams, HITL, guards, summarization)
├── prom_ex/                  # PromEx plugin for Prometheus metrics
├── providers/                # LLM provider adapters
├── pubsub/                   # Approval request/response over PubSub
├── research/                 # Deep research pipeline
├── session/                  # Session config and guardrails
├── skill/                    # Skill loader and registry
├── skills/                   # Bundled skill modules
├── stream_normalizer/        # Per-provider stream chunk normalizers
├── teams/                    # Team coordinator, shared state, roles, limits
├── tool/                     # Tool system (behaviour, schema DSL, registry,
│                             #   validator, context updates, test helpers)
├── tools/                    # Built-in tools (bash, files, search, web, todos)
└── workflow/                 # Workflow graph, compiler, engine, checkpoints
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
