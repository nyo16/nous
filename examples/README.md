# Nous Examples

Learn Nous through practical examples, from basic usage to advanced patterns.

## Quick Start

```bash
# Run any example
mix run examples/01_hello_world.exs

# Requires LM Studio running locally (default)
# Or set API keys for cloud providers:
export ANTHROPIC_API_KEY="sk-..."
export OPENAI_API_KEY="sk-..."
```

## Core Examples (01-10)

Progressive learning path from basics to advanced features:

| File | Description |
|------|-------------|
| [01_hello_world.exs](01_hello_world.exs) | Minimal example - create agent, run, get output |
| [02_with_tools.exs](02_with_tools.exs) | Function-based tools and context access |
| [03_streaming.exs](03_streaming.exs) | Real-time streaming responses |
| [04_conversation.exs](04_conversation.exs) | Multi-turn conversations with context continuation |
| [05_callbacks.exs](05_callbacks.exs) | Map callbacks and process messages (LiveView) |
| [06_prompt_templates.exs](06_prompt_templates.exs) | EEx templates with variable substitution |
| [07_module_tools.exs](07_module_tools.exs) | Tool.Behaviour pattern for module-based tools |
| [08_tool_testing.exs](08_tool_testing.exs) | Mock tools, spy tools, and test helpers |
| [09_agent_server.exs](09_agent_server.exs) | GenServer-based agent with PubSub |
| [10_react_agent.exs](10_react_agent.exs) | ReAct pattern for complex reasoning |
| [11_human_in_the_loop.exs](11_human_in_the_loop.exs) | HITL approval workflows (sync + async PubSub) |
| [12_pubsub_agent.exs](12_pubsub_agent.exs) | PubSub agent lifecycle, registry, persistence |
| [13_sub_agents.exs](13_sub_agents.exs) | Sub-agents (single + parallel) with fan-out/fan-in |
| [14_structured_output.exs](14_structured_output.exs) | Ecto schemas, JSON schema, multi-schema selection |
| [15_input_guard.exs](15_input_guard.exs) | Prompt injection detection and blocking |
| [16_hooks.exs](16_hooks.exs) | Lifecycle hooks: blocking, modification, priority ordering |
| [17_skills.exs](17_skills.exs) | Skills: modules, file-based (load from .md files/dirs), groups, matching, built-in catalog |
| [18_workflow.exs](18_workflow.exs) | DAG workflow engine: pipelines, branching, parallel, cycles, HITL, hooks, LLM agents |
| [19_coding_agent.exs](19_coding_agent.exs) | Coding agent: file/shell tools, permissions, session guardrails, transcript compaction |

## Workflow Examples

End-to-end workflows with real LLM agent steps:

| File | Description |
|------|-------------|
| [workflow/research_pipeline.exs](workflow/research_pipeline.exs) | Multi-agent research: plan → parallel search → synthesize report |
| [workflow/quality_loop.exs](workflow/quality_loop.exs) | LLM generates content, loops until quality gate passes |
| [workflow/human_review.exs](workflow/human_review.exs) | Human-in-the-loop: approve, edit, and suspend patterns |
| [workflow/parallel_analysis.exs](workflow/parallel_analysis.exs) | Batch sentiment analysis + multi-specialist parallel branches |

## Provider Examples

Provider-specific configuration and features:

| File | Description |
|------|-------------|
| [providers/anthropic.exs](providers/anthropic.exs) | Claude models, extended thinking, tools |
| [providers/openai.exs](providers/openai.exs) | GPT models, function calling, settings |
| [providers/lmstudio.exs](providers/lmstudio.exs) | Local AI with LM Studio |
| [providers/vllm_sglang.exs](providers/vllm_sglang.exs) | vLLM & SGLang high-performance local inference |
| [providers/vertex_ai.exs](providers/vertex_ai.exs) | Google Vertex AI with Goth auth |
| [providers/vertex_ai_multi_region.exs](providers/vertex_ai_multi_region.exs) | Vertex AI across multiple regions |
| [providers/llamacpp.exs](providers/llamacpp.exs) | Local NIF-based inference via llama.cpp |
| [providers/custom_providers.exs](providers/custom_providers.exs) | The `custom:` OpenAI-compatible provider prefix |
| [providers/switching_providers.exs](providers/switching_providers.exs) | Provider comparison and selection |

> The `providers/vertex_ai_goth_test.exs` and `providers/vertex_ai_integration_test.exs`
> files are manual integration smoke scripts (live credentials required), not
> tutorial examples.

## Evaluation Examples

Test, benchmark, and optimize agents:

| File | Description |
|------|-------------|
| [eval/01_basic_evaluation.exs](eval/01_basic_evaluation.exs) | Build a suite, run it, read pass/fail metrics |
| [eval/02_yaml_suite.exs](eval/02_yaml_suite.exs) | Load a test suite from YAML |
| [eval/03_optimization.exs](eval/03_optimization.exs) | Optimize prompt/model parameters over a search space |
| [eval/04_custom_evaluator.exs](eval/04_custom_evaluator.exs) | Write a custom evaluator |
| [eval/05_ab_testing.exs](eval/05_ab_testing.exs) | A/B compare two agent configurations |

## Memory Examples

Persistent agent memory with hybrid search:

| File | Description |
|------|-------------|
| [memory/basic_ets.exs](memory/basic_ets.exs) | Simplest setup — ETS store, keyword search, zero deps |
| [memory/local_bumblebee.exs](memory/local_bumblebee.exs) | Local semantic search via Bumblebee, no API keys |
| [memory/sqlite_full.exs](memory/sqlite_full.exs) | SQLite + FTS5, single-file production setup |
| [memory/duckdb_full.exs](memory/duckdb_full.exs) | DuckDB with FTS + vector search |
| [memory/postgresql_full.exs](memory/postgresql_full.exs) | PostgreSQL + tsvector + pgvector, full Store implementation |
| [memory/hybrid_full.exs](memory/hybrid_full.exs) | Muninn + Zvec for maximum search quality |
| [memory/cross_agent.exs](memory/cross_agent.exs) | Two agents sharing memory with scoping |
| [memory/auto_update.exs](memory/auto_update.exs) | Auto-update memory after each run (no explicit tool calls) |

## Advanced Examples

Production patterns and advanced features:

| File | Description |
|------|-------------|
| [advanced/context_updates.exs](advanced/context_updates.exs) | Tool context updates and state management |
| [advanced/error_handling.exs](advanced/error_handling.exs) | Manual retries and error handling |
| [advanced/fallback.exs](advanced/fallback.exs) | Built-in provider/model failover chains |
| [advanced/teams.exs](advanced/teams.exs) | Multi-agent team lifecycle: roles, shared state, comms |
| [advanced/decisions.exs](advanced/decisions.exs) | Decision-graph tracking (core API + agent plugin) |
| [advanced/deep_research.exs](advanced/deep_research.exs) | Autonomous deep research with citations |
| [advanced/telemetry.exs](advanced/telemetry.exs) | Custom metrics and cost tracking |
| [advanced/cancellation.exs](advanced/cancellation.exs) | Task and streaming cancellation |
| [advanced/liveview_integration.exs](advanced/liveview_integration.exs) | Phoenix LiveView integration patterns |
| [advanced/liveview_chat.exs](advanced/liveview_chat.exs) | Full chat UI: streaming, tools, sessions, auto-scroll |
| [advanced/liveview_multi_agent.exs](advanced/liveview_multi_agent.exs) | Multi-agent dashboard with real-time PubSub status |
| [advanced/tool_permissions.exs](advanced/tool_permissions.exs) | Permission policies: presets, custom deny/approve, tool filtering |

## Running Examples

Most examples use LM Studio by default (free, local):

1. Download [LM Studio](https://lmstudio.ai/)
2. Load a model (e.g., Qwen)
3. Start the local server
4. Run: `mix run examples/01_hello_world.exs`

For cloud providers, set the appropriate API key:
```bash
ANTHROPIC_API_KEY="..." mix run examples/providers/anthropic.exs
OPENAI_API_KEY="..." mix run examples/providers/openai.exs
```

## Project Examples

For larger project examples (multi-agent systems, trading bots, etc.), see:
- [projects/README.md](projects/README.md)
