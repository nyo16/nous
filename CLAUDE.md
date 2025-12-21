# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

```bash
# Dependencies
mix deps.get              # Install dependencies

# Code quality
mix format                # Format code
mix credo                 # Linting
mix dialyzer              # Type checking (first run: mix dialyzer --plt)

# Testing
mix test                  # Run tests (excludes :llm tagged tests)
mix test --include llm    # Include tests requiring real LLM APIs
mix test path/to/test.exs # Run single test file

# Documentation
mix docs                  # Generate docs (copies images to doc/)

# Running examples
mix run examples/basic_hello_world.exs
```

## Architecture Overview

Nous is an AI agent framework for Elixir with multi-provider LLM support.

### Core Execution Flow

```
Nous.Agent (stateless config)
    ↓
Nous.AgentRunner (execution loop)
    ├→ ModelDispatcher → Provider adapters (Anthropic, Gemini, Mistral, OpenAICompatible)
    ├→ ToolExecutor → RunContext (inject deps into tools)
    ├→ Messages (format conversion to/from OpenAI format)
    └→ Usage (token tracking)
```

### Key Components

- **Nous.Agent** (`lib/nous/agent.ex`) - Stateless agent configuration (model, instructions, tools, settings)
- **Nous.AgentRunner** (`lib/nous/agent_runner.ex`) - Main execution loop: builds messages, calls model, executes tools, handles retries
- **Nous.ModelDispatcher** (`lib/nous/model_dispatcher.ex`) - Routes requests to provider-specific adapters
- **Nous.ToolExecutor** (`lib/nous/tool_executor.ex`) - Executes tool functions with context injection and retry logic

### Provider Adapters (`lib/nous/models/`)

- `anthropic.ex` - Uses Anthropix library for Claude API
- `gemini.ex` - Uses gemini_ex library for Google Gemini
- `mistral.ex` - Uses Req library for Mistral API
- `openai_compatible.ex` - Uses openai_ex for OpenAI, Groq, Ollama, LM Studio, vLLM, OpenRouter, Together AI

### Model String Format

Models are specified as `provider:model_name`, parsed by `Nous.ModelParser`:
- `openai:gpt-4`, `anthropic:claude-sonnet-4-5-20250929`, `lmstudio:qwen/qwen3-30b`

### Two Agent Types

1. **Nous.Agent** - Standard agent for simple tasks, auto-completes when model stops
2. **Nous.ReActAgent** (`lib/nous/react_agent.ex`) - Enhanced planning with structured reasoning, explicit `final_answer` required

### Tool System

Tools are function references with arity 2: `fn(ctx, args) -> result`
- `ctx` is `Nous.RunContext` with deps, agent_name, retry count
- `args` is a map of parameters from the LLM
- Built-in tools in `lib/nous/tools/`: DateTimeTools, StringTools, TodoTools, BraveSearch, ReActTools

### Configuration

- API keys via environment variables: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `MISTRAL_API_KEY`, etc.
- HTTP connection pooling via Finch, configured in `lib/nous/application.ex`
- Telemetry events emitted for agent runs, model requests, and tool executions

## Testing Notes

- Tests tagged with `@tag :llm` require real API connections and are excluded by default
- Use Mox for mocking in unit tests
- Test support files in `test/support/`
