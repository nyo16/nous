# Changelog

All notable changes to this project will be documented in this file.

## [0.12.0] - 2026-02-28

### Added

- **Memory System**: Persistent memory for agents with hybrid text + vector search, temporal decay, importance weighting, and flexible scoping.
  - `Nous.Memory.Entry` — memory entry struct with type (semantic/episodic/procedural), importance, evergreen flag, and scoping fields (agent_id, session_id, user_id, namespace)
  - `Nous.Memory.Store` — storage behaviour with 8 callbacks (init, store, fetch, delete, update, search_text, search_vector, list)
  - `Nous.Memory.Store.ETS` — zero-dep in-memory backend with Jaro-distance text search
  - `Nous.Memory.Store.SQLite` — SQLite + FTS5 backend (requires `exqlite`)
  - `Nous.Memory.Store.DuckDB` — DuckDB + FTS + vector backend (requires `duckdbex`)
  - `Nous.Memory.Store.Muninn` — Tantivy BM25 text search backend (requires `muninn`)
  - `Nous.Memory.Store.Zvec` — HNSW vector search backend (requires `zvec`)
  - `Nous.Memory.Store.Hybrid` — combines Muninn + Zvec for maximum retrieval quality
  - `Nous.Memory.Scoring` — pure functions for Reciprocal Rank Fusion, temporal decay, composite scoring
  - `Nous.Memory.Search` — hybrid search orchestrator (text + vector → RRF merge → decay → composite score)
  - `Nous.Memory.Embedding` — embedding provider behaviour with pluggable implementations
  - `Nous.Memory.Embedding.Bumblebee` — local on-device embeddings via Bumblebee + EXLA (Qwen 0.6B default)
  - `Nous.Memory.Embedding.OpenAI` — OpenAI text-embedding-3-small provider
  - `Nous.Memory.Embedding.Local` — generic local endpoint (Ollama, vLLM, LMStudio)
  - `Nous.Memory.Tools` — agent tools: `remember`, `recall`, `forget`
  - `Nous.Plugins.Memory` — plugin with auto-injection of relevant memories, configurable search scope and injection strategy
  - 6 example scripts in `examples/memory/` (basic ETS, Bumblebee, SQLite, DuckDB, Hybrid, cross-agent)
  - 62 new tests across 6 test files

- **Graceful degradation**: No embedding provider = keyword-only search. No optional deps = `Store.ETS` with Jaro matching. The core memory system has zero additional dependencies.

## [0.11.3] - 2026-02-26

### Fixed

- **Anthropic and Gemini streaming**: Added missing `Nous.StreamNormalizer.Anthropic` and `Nous.StreamNormalizer.Gemini` modules. These were referenced in `Provider.default_stream_normalizer/0` but never created, causing runtime crashes when streaming with Anthropic or Gemini providers.

### Added

- `Nous.StreamNormalizer.Anthropic` — normalizes Anthropic SSE events (`content_block_delta`, `message_delta`, `content_block_start` for tool use, thinking deltas, error events)
- `Nous.StreamNormalizer.Gemini` — normalizes Gemini SSE events (`candidates` array with text parts, `functionCall`, `finishReason` mapping)
- 42 tests for both new stream normalizers

## [0.11.0] - 2026-02-20

### Added

- **Structured Output Mode**: Agents return validated, typed data instead of raw strings. Inspired by [instructor_ex](https://github.com/thmsmlr/instructor_ex).
  - `Nous.OutputSchema` core module: JSON schema generation, provider settings dispatch, parsing and validation
  - `use Nous.OutputSchema` macro with `@llm_doc` attribute for schema-level LLM documentation
  - `validate_changeset/1` optional callback for custom Ecto validation rules
  - Validation retry loop: failed outputs are sent back to the LLM with error details (`max_retries` option)
  - System prompt augmentation with schema instructions

- **Output Type Variants**:
  - Ecto schema modules — full JSON schema + changeset validation
  - Schemaless Ecto types (`%{name: :string, age: :integer}`) — lightweight, no module needed
  - Raw JSON schema maps (string keys) — passed through as-is
  - `{:regex, pattern}` — regex-constrained output (vLLM/SGLang)
  - `{:grammar, ebnf}` — EBNF grammar-constrained output (vLLM)
  - `{:choice, choices}` — choice-constrained output (vLLM/SGLang)

- **Provider Modes**: Controls how structured output is enforced per-provider
  - `:auto` (default) — picks best mode for the provider
  - `:json_schema` — `response_format` with strict JSON schema (OpenAI, vLLM, SGLang, Gemini)
  - `:tool_call` — synthetic tool with tool_choice (Anthropic default)
  - `:json` — `response_format: json_object` (OpenAI-compatible)
  - `:md_json` — prompt-only enforcement with markdown fence + stop token (all providers)

- **Provider Passthrough**: `response_format`, `guided_json`, `guided_regex`, `guided_grammar`, `guided_choice`, `json_schema`, `regex`, `generationConfig` now passed through in `build_request_params`

- **New Files**:
  - `lib/nous/output_schema.ex` — core module
  - `lib/nous/output_schema/validator.ex` — behaviour definition
  - `lib/nous/output_schema/use_macro.ex` — `use Nous.OutputSchema` macro
  - `docs/guides/structured_output.md` — comprehensive guide
  - `examples/14_structured_output.exs` — example script with 5 patterns
  - `test/nous/output_schema_test.exs` — 42 unit tests
  - `test/nous/structured_output_integration_test.exs` — 16 integration tests
  - `test/eval/agents/structured_output_test.exs` — 3 LLM integration tests

### Changed

- `Nous.Agent` struct gains `structured_output` keyword list field (mode, max_retries)
- `Nous.Types.output_type` expanded with schemaless, raw JSON schema, and guided mode tuples
- `Nous.AgentRunner` injects structured output settings, augments system prompt, handles validation retries
- `Nous.Agents.BasicAgent.extract_output/2` routes through `OutputSchema.parse_and_validate/2`
- `Nous.Agents.ReActAgent.extract_output/2` validates `final_answer` against output_type
- Provider `build_request_params/3` passes through structured output parameters

## [0.10.1] - 2026-02-14

### Changed

- **Sub-Agent plugin unified**: Merged `ParallelSubAgent` into `Nous.Plugins.SubAgent`
  - Single plugin now provides both `delegate_task` (single) and `spawn_agents` (parallel) tools
  - `system_prompt/2` callback injects orchestration guidance including available templates
  - Templates accept `%Nous.Agent{}` structs (recommended) or config maps (legacy)
  - Parallel execution via `Task.Supervisor.async_stream_nolink`
  - Configurable concurrency (`parallel_max_concurrency`, default: 5) and timeout (`parallel_timeout`, default: 120s)
  - Graceful partial failure: crashed/timed-out sub-agents don't block others

- **New Example**: `examples/13_sub_agents.exs`
  - Template-based sub-agents using `Nous.Agent.new/2` structs
  - Parallel execution with inline model config
  - Direct programmatic invocation bypassing the LLM

## [0.10.0] - 2026-02-14

### Added

- **Plugin System**: Composable agent extensions via `Nous.Plugin` behaviour
  - Callbacks: `init/2`, `tools/2`, `system_prompt/2`, `before_request/3`, `after_response/3`
  - Add `plugins: [MyPlugin]` to any agent for cross-cutting concerns
  - AgentRunner iterates plugins at each stage of the execution loop

- **Human-in-the-Loop (HITL)**: Approval workflows for sensitive tool calls
  - `requires_approval: true` on `Nous.Tool` struct
  - `approval_handler` on `Nous.Agent.Context` for approve/edit/reject decisions
  - `Nous.Plugins.HumanInTheLoop` for per-tool configuration via deps

- **Sub-Agent System**: Enable agents to delegate tasks to specialized child agents
  - `Nous.Plugins.SubAgent` provides `delegate_task` tool
  - Pre-configured agent templates via `deps[:sub_agent_templates]`
  - Isolated context per sub-agent with shared deps support

- **Conversation Summarization**: Automatic context window management
  - `Nous.Plugins.Summarization` monitors token usage against configurable threshold
  - LLM-powered summarization with safe split points (never separates tool_call/tool_result pairs)
  - Error-resilient: keeps all messages if summarization fails

- **State Persistence**: Save and restore agent conversation state
  - `Nous.Agent.Context.serialize/1` and `deserialize/1` for JSON-safe round-trips
  - `Nous.Persistence` behaviour with `save/load/delete/list` callbacks
  - `Nous.Persistence.ETS` reference implementation
  - Auto-save hooks on `Nous.AgentServer`

- **Enhanced Supervision**: Production lifecycle management for agents
  - `Nous.AgentRegistry` for session-based process lookup via Registry
  - `Nous.AgentDynamicSupervisor` for on-demand agent creation/destruction
  - Configurable inactivity timeout on `AgentServer` (default: 5 minutes)
  - Added to application supervision tree

- **Dangling Tool Call Recovery**: Resilient session resumption
  - `Nous.Agent.Context.patch_dangling_tool_calls/1` injects synthetic results for interrupted tool calls
  - Called automatically when continuing from an existing context

- **PubSub Abstraction Layer**: Unified `Nous.PubSub` module for all PubSub usage
  - `Nous.PubSub` wraps Phoenix.PubSub with graceful no-op fallback when unavailable
  - Application-level configuration via `config :nous, pubsub: MyApp.PubSub`
  - Topic builders: `agent_topic/1`, `research_topic/1`, `approval_topic/1`
  - `Nous.Agent.Context` gains `pubsub` and `pubsub_topic` fields (runtime-only, never serialized)
  - `Nous.Agent.Callbacks.execute/3` now broadcasts via PubSub as a third channel alongside callbacks and `notify_pid`
  - `AgentServer` refactored to use `Nous.PubSub` — removes ad-hoc `setup_pubsub_functions/0` and `subscribe_fn`/`broadcast_fn` from state
  - Research Coordinator broadcasts progress via PubSub when `:session_id` is provided
  - SubAgent plugin propagates parent's PubSub context to child agents

- **Async HITL Approval via PubSub**: `Nous.PubSub.Approval` module
  - `handler/1` builds an approval handler compatible with `Nous.Plugins.HumanInTheLoop`
  - Broadcasts `{:approval_required, info}` and blocks via `receive` for response
  - `respond/4` sends approval decisions from external processes (e.g., LiveView)
  - Configurable timeout with `:reject` as default on expiry
  - Enables async approval workflows without synchronous I/O

- **Deep Research Agent**: Autonomous multi-step research with citations
  - `Nous.Research.run/2` public API with HITL checkpoints between iterations
  - Five-phase loop: plan → search → synthesize → evaluate → report
  - `Nous.Research.Planner` decomposes queries into searchable sub-questions
  - `Nous.Research.Searcher` runs parallel search agents per sub-question
  - `Nous.Research.Synthesizer` for deduplication, contradiction detection, gap analysis
  - `Nous.Research.Reporter` generates markdown reports with inline citations
  - Progress broadcasting via callbacks, `notify_pid`, and PubSub

- **New Research Tools**:
  - `Nous.Tools.WebFetch` — URL content extraction with Floki HTML parsing
  - `Nous.Tools.Summarize` — LLM-powered text summarization focused on research queries
  - `Nous.Tools.SearchScrape` — Parallel fetch + summarize for multiple URLs
  - `Nous.Tools.TavilySearch` — Tavily AI search API integration
  - `Nous.Tools.ResearchNotes` — Structured finding/gap/contradiction tracking via ContextUpdate

- **New Dependencies**:
  - `floki ~> 0.36` (optional, for HTML content extraction)
  - `phoenix_pubsub ~> 2.1` (test-only, for PubSub integration tests)

### Changed

- `Nous.Agent` struct now accepts `plugins: [module()]` option
- `Nous.Tool` struct now accepts `requires_approval: boolean()` option
- `Nous.Agent.Context` now includes `approval_handler`, `pubsub`, and `pubsub_topic` fields
- `Nous.AgentServer` supports optional `:name` registration, `:persistence` backend, and uses `Nous.PubSub` (removed ad-hoc `setup_pubsub_functions/0`)
- `Nous.AgentServer` `:pubsub` option now defaults to `Nous.PubSub.configured_pubsub()` instead of `MyApp.PubSub`
- `Nous.AgentRunner` accepts `:pubsub` and `:pubsub_topic` options when building context
- Application supervision tree includes AgentRegistry and AgentDynamicSupervisor

## [0.9.0] - 2026-01-04

### Added

- **Evaluation Framework**: Production-grade testing and benchmarking for AI agents
  - `Nous.Eval` module for defining and running test suites
  - `Nous.Eval.Suite` for test suite management with YAML support
  - `Nous.Eval.TestCase` for individual test case definitions
  - `Nous.Eval.Runner` for sequential and parallel test execution
  - `Nous.Eval.Metrics` for collecting latency, token usage, and cost metrics
  - `Nous.Eval.Reporter` for console and JSON result reporting
  - A/B testing support with `Nous.Eval.run_ab/2`

- **Six Built-in Evaluators**:
  - `:exact_match` - Strict string equality matching
  - `:fuzzy_match` - Jaro-Winkler similarity with configurable thresholds
  - `:contains` - Substring and regex pattern matching
  - `:tool_usage` - Tool call verification with argument validation
  - `:schema` - Ecto schema validation for structured outputs
  - `:llm_judge` - LLM-based quality assessment with custom rubrics

- **Optimization Engine**: Automated parameter tuning for agents
  - `Nous.Eval.Optimizer` with three strategies: grid search, random search, Bayesian optimization
  - Support for float, integer, choice, and boolean parameter types
  - Early stopping on threshold achievement
  - Detailed trial history and best configuration reporting

- **New Mix Tasks**:
  - `mix nous.eval` - Run evaluation suites with filtering, parallelism, and multiple output formats
  - `mix nous.optimize` - Parameter optimization with configurable strategies and metrics

- **New Dependency**: `yaml_elixir ~> 2.9` for YAML test suite parsing

### Documentation

- New comprehensive evaluation framework guide (`docs/guides/evaluation.md`)
- Five new example scripts in `examples/eval/`:
  - `01_basic_evaluation.exs` - Simple test execution
  - `02_yaml_suite.exs` - Loading and running YAML suites
  - `03_optimization.exs` - Parameter optimization workflows
  - `04_custom_evaluator.exs` - Implementing custom evaluators
  - `05_ab_testing.exs` - A/B testing configurations

## [0.8.1] - 2025-12-31

### Fixed

- Fixed `Usage` struct not implementing Access behaviour for telemetry metrics
- Fixed `Task.shutdown/2` nil return case in `AgentServer` cancellation
- Fixed tool call field access for OpenAI-compatible APIs (string vs atom keys)

### Added

- Vision/multimodal test suite with image fixtures (`test/nous/vision_test.exs`)
- ContentPart test suite for image conversion utilities (`test/nous/content_part_test.exs`)
- Multimodal message examples in conversation demo (`examples/04_conversation.exs`)

### Changed

- Updated docs to link examples to GitHub source files
- Improved sidebar grouping in hexdocs

## [0.8.0] - 2025-12-31

### Added

- **Context Management**: New `Nous.Agent.Context` struct for immutable conversation state, message history, and dependency injection. Supports context continuation between runs:
  ```elixir
  {:ok, result1} = Nous.run(agent, "My name is Alice")
  {:ok, result2} = Nous.run(agent, "What's my name?", context: result1.context)
  ```

- **Agent Behaviour**: New `Nous.Agent.Behaviour` for implementing custom agents with lifecycle callbacks (`init_context/2`, `build_messages/2`, `process_response/3`, `extract_output/2`).

- **Dual Callback System**: New `Nous.Agent.Callbacks` supporting both map-based callbacks and process messages:
  ```elixir
  # Map callbacks
  Nous.run(agent, "Hello", callbacks: %{
    on_llm_new_delta: fn _event, delta -> IO.write(delta) end
  })

  # Process messages (for LiveView)
  Nous.run(agent, "Hello", notify_pid: self())
  ```

- **Module-Based Tools**: New `Nous.Tool.Behaviour` for defining tools as modules with `metadata/0` and `execute/2` callbacks. Use `Nous.Tool.from_module/2` to create tools from modules.

- **Tool Context Updates**: New `Nous.Tool.ContextUpdate` struct allowing tools to modify context state:
  ```elixir
  def my_tool(ctx, args) do
    {:ok, result, ContextUpdate.new() |> ContextUpdate.set(:key, value)}
  end
  ```

- **Tool Testing Helpers**: New `Nous.Tool.Testing` module with `mock_tool/2`, `spy_tool/1`, and `test_context/1` for testing tool interactions.

- **Tool Validation**: New `Nous.Tool.Validator` for JSON Schema validation of tool arguments.

- **Prompt Templates**: New `Nous.PromptTemplate` for EEx-based prompt templates with variable substitution.

- **Built-in Agent Implementations**: `Nous.Agents.BasicAgent` (default) and `Nous.Agents.ReActAgent` (reasoning with planning tools).

- **Structured Errors**: New `Nous.Errors` module with `MaxIterationsReached`, `ToolExecutionError`, and `ExecutionCancelled` error types.

- **Enhanced Telemetry**: New events for iterations (`:iteration`), tool timeouts (`:tool_timeout`), and context updates (`:context_update`).

### Changed

- **Result Structure**: `Nous.run/3` now returns `%{output: _, context: _, usage: _}` instead of just output string.

- **Tool Function Signature**: Tools now receive `(ctx, args)` instead of `(args)`. The context provides access to `ctx.deps` for dependency injection.

- **Examples Modernized**: Reduced from ~95 files to 21 files. Flattened directory structure from 4 levels to 2 levels. All examples updated to v0.8.0 API.

### Removed

- Removed deprecated provider modules: `Nous.Providers.Gemini`, `Nous.Providers.Mistral`, `Nous.Providers.VLLM`, `Nous.Providers.SGLang`.

- Removed built-in tools: `Nous.Tools.BraveSearch`, `Nous.Tools.DateTimeTools`, `Nous.Tools.StringTools`, `Nous.Tools.TodoTools`. These can be implemented as custom tools.

- Removed `Nous.RunContext` (replaced by `Nous.Agent.Context`).

- Removed `Nous.PromEx.Plugin` (users can implement custom Prometheus metrics using telemetry events).

## [0.7.2] - 2025-12-29

### Fixed

- **Stream completion events**: The `[DONE]` SSE event now properly emits a `{:finish, "stop"}` event instead of being silently discarded. This ensures stream consumers always receive a completion signal.

- **Documentation links**: Fixed broken links in hexdocs documentation. Relative links to `.exs` example files now use absolute GitHub URLs so they work correctly on hexdocs.pm.

## [0.7.1] - 2025-12-29

### Changed

- **Make all provider dependencies optional**: `openai_ex`, `anthropix`, and `gemini_ex` are now truly optional dependencies. Users only need to install the dependencies for the providers they use.

- **Runtime dependency checks**: Provider modules now check for dependency availability at runtime instead of compile-time, allowing the library to compile without any provider-specific dependencies.

- **OpenAI message format**: Messages are now returned as plain maps with string keys (`%{"role" => "user", "content" => "Hi"}`) instead of `OpenaiEx.ChatMessage` structs. This removes the compile-time dependency on `openai_ex` for message formatting.

### Fixed

- Fixed "anthropix dependency not available" errors that occurred when using the library in applications without `anthropix` installed.

- Fixed compile-time errors that occurred when `openai_ex` was not present in the consuming application.

## [0.7.0] - 2025-12-27

Initial public release with multi-provider LLM support:

- OpenAI-compatible providers (OpenAI, Groq, OpenRouter, Ollama, LM Studio, vLLM)
- Native Anthropic Claude support with extended thinking
- Google Gemini support
- Mistral AI support
- Tool/function calling
- Streaming support
- ReAct agent implementation
