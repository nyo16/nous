# Changelog

All notable changes to this project will be documented in this file.

## [0.12.15] - 2026-03-26

### Fixed

- **`receive_timeout` silently dropped in `Nous.LLM`**: `generate_text/3` and `stream_text/3` with a string model only passed `[:base_url, :api_key, :llamacpp_model]` to `Model.parse`, so `receive_timeout` was silently ignored. Now correctly forwarded.

### Removed

- **Dead timeout config**: Removed unused `default_timeout` and `stream_timeout` from `config/config.exs`. Timeouts are determined by per-provider defaults in `Model.default_receive_timeout/1` and each provider module's `@default_timeout`/`@streaming_timeout` constants.

### Documentation

- Added "Timeouts" section to README documenting `receive_timeout` option and default timeouts per provider.

## [0.13.0] - 2026-03-21

### Added

- **Hooks system**: Granular lifecycle interceptors for tool execution and request/response flow.
  - 6 lifecycle events: `pre_tool_use`, `post_tool_use`, `pre_request`, `post_response`, `session_start`, `session_end`
  - 3 handler types: `:function` (inline), `:module` (behaviour), `:command` (shell via NetRunner)
  - Matcher-based dispatch: string (exact tool name), regex, or predicate function
  - Blocking semantics for `pre_tool_use` and `pre_request` — hooks can deny or modify tool calls
  - Priority-based execution ordering (lower = earlier)
  - Telemetry events: `[:nous, :hook, :execute, :start | :stop]`, `[:nous, :hook, :denied]`
  - `Nous.Hook`, `Nous.Hook.Registry`, `Nous.Hook.Runner`
  - New option on `Agent.new/2`: `:hooks`
  - New example: `examples/16_hooks.exs`

- **Skills system**: Reusable instruction/capability packages for agents.
  - Module-based skills with `use Nous.Skill` macro and behaviour callbacks
  - File-based skills: markdown files with YAML frontmatter, loaded from directories
  - 5 activation modes: `:manual`, `:auto`, `{:on_match, fn}`, `{:on_tag, tags}`, `{:on_glob, patterns}`
  - Skill groups: `:coding`, `:review`, `:testing`, `:debug`, `:git`, `:docs`, `:planning`
  - Registry with load/unload, activate/deactivate, group operations, and input matching
  - `Nous.Plugins.Skills` — auto-included plugin bridging skills into the agent lifecycle
  - Directory scanning: `skill_dirs:` option and `Registry.register_directory/2`
  - Telemetry events: `[:nous, :skill, :activate | :deactivate | :load | :match]`
  - New options on `Agent.new/2`: `:skills`, `:skill_dirs`
  - New example: `examples/17_skills.exs`
  - New guides: `docs/guides/skills.md`, `docs/guides/hooks.md`

- **21 built-in skills**:
  - Language-agnostic (10): CodeReview, TestGen, Debug, Refactor, ExplainCode, CommitMessage, DocGen, SecurityScan, Architect, TaskBreakdown
  - Elixir-specific (5): PhoenixLiveView, EctoPatterns, OtpPatterns, ElixirTesting, ElixirIdioms
  - Python-specific (6): PythonFastAPI, PythonTesting, PythonTyping, PythonDataScience, PythonSecurity, PythonUv

- **NetRunner dependency** (`~> 1.0.4`): Zero-zombie-process OS command execution for command hooks with SIGTERM→SIGKILL timeout escalation.

- 76 new tests for hooks and skills systems.

## [0.12.11] - 2026-03-19

### Added

- **Per-run structured output override**: Pass `output_type:` and `structured_output:` as options to `Agent.run/3`, `run_stream/3`, and `run_with_context/3` to override the agent's defaults per call. The same agent can return raw text or structured data depending on the request.
- **Multi-schema selection (`{:one_of, [SchemaA, SchemaB]}`)**: New output_type variant where the LLM dynamically chooses which schema to use per response. Each schema becomes a synthetic tool — the LLM's tool choice acts as schema selection. Includes automatic retry and validation against the selected schema.
  - `OutputSchema.schema_name/1` — public helper to get snake_case name for a schema module
  - `OutputSchema.tool_name_for_schema/1` — build synthetic tool name from schema module
  - `OutputSchema.find_schema_for_tool_name/2` — reverse-map tool name to schema module
  - `OutputSchema.synthetic_tool_name?/1` — predicate for synthetic tool call detection
  - `OutputSchema.extract_response_for_one_of/2` — extract text and identify matched schema from tool call
  - New example: Example 6 (per-run override) and Example 7 (multi-schema) in `examples/14_structured_output.exs`
  - New sections in `docs/guides/structured_output.md`

### Fixed

- **Synthetic tool call handling**: Structured output tool calls (`__structured_output__`) in `:tool_call` mode are now correctly filtered from the tool execution loop. Previously, these synthetic calls would produce "Tool not found" errors and cause an unnecessary extra LLM round-trip. Now they terminate the loop immediately and the structured output is extracted directly.

## [0.12.10] - 2026-03-19

### Added

- **Fallback model/provider support**: Automatic failover to alternative models when the primary model fails with a `ProviderError` or `ModelError` (rate limit, server error, timeout, auth issue).
  - `Nous.Fallback` — core fallback logic: eligibility checks, recursive model chain traversal, model string/struct parsing
  - `:fallback` option on `Nous.Agent.new/2` — ordered list of fallback model strings or `Model` structs
  - `:fallback` option on `Nous.generate_text/3` and `Nous.stream_text/3`
  - Tool schemas are automatically re-converted when falling back across providers (e.g., OpenAI → Anthropic)
  - Structured output settings are re-injected for the target provider on cross-provider fallback
  - Agent model is swapped on successful fallback so remaining iterations use the working model
  - Streaming fallback retries stream initialization only, not mid-stream failures
  - New telemetry events: `[:nous, :fallback, :activated]` and `[:nous, :fallback, :exhausted]`
  - Only `ProviderError` and `ModelError` trigger fallback; application-level errors (`ValidationError`, `MaxIterationsExceeded`, `ExecutionCancelled`, `ToolError`) are returned immediately
  - 52 new tests across `test/nous/fallback_test.exs` and `test/nous/agent_fallback_test.exs`

### Changed

- `Nous.Agent` struct gains `fallback: [Model.t()]` field (default: `[]`)
- `Nous.LLM` now uses injectable dispatcher (`get_dispatcher/0`) for testability, consistent with `AgentRunner`

## [0.12.9] - 2026-03-12

### Added

- **InputGuard plugin**: Modular malicious input classifier with pluggable strategy pattern. Detects prompt injection, jailbreak attempts, and other malicious inputs before they reach the LLM.
  - `Nous.Plugins.InputGuard` — Main plugin with configurable aggregation (`:any`/`:majority`/`:all`), short-circuit mode, and violation callbacks
  - `Nous.Plugins.InputGuard.Strategy` — Behaviour for custom detection strategies
  - `Nous.Plugins.InputGuard.Strategies.Pattern` — Built-in regex patterns for instruction override, role reassignment, DAN jailbreaks, prompt extraction, and encoding evasion. Supports `:extra_patterns` (additive) and `:patterns` (full override)
  - `Nous.Plugins.InputGuard.Strategies.LLMJudge` — Secondary LLM classification with fail-open/fail-closed modes
  - `Nous.Plugins.InputGuard.Strategies.Semantic` — Embedding cosine similarity against pre-computed attack vectors
  - `Nous.Plugins.InputGuard.Policy` — Severity-to-action resolution (`:block`, `:warn`, `:log`, `:callback`, custom `fun/2`)
  - Tracks checked message index to prevent re-triggering on tool-call loop iterations
  - New example: `examples/15_input_guard.exs`

### Fixed

- **AgentRunner**: `before_request` plugin hook now short-circuits the LLM call when a plugin sets `needs_response: false` (e.g., InputGuard blocking). Previously the current iteration would still call the LLM before the block took effect on the next iteration.

## [0.12.8] - 2026-03-12

### Fixed

- **Vertex AI v1/v1beta1 bug**: `Model.parse("vertex_ai:gemini-2.5-pro-preview-06-05")` with `GOOGLE_CLOUD_PROJECT` set was storing a hardcoded `v1` URL in `model.base_url`, causing the provider's `v1beta1` selection logic to be bypassed. Preview models now correctly use `v1beta1` at request time.

### Added

- **Vertex AI input validation**: Project ID and region from environment variables are now validated with helpful error messages instead of producing opaque DNS/HTTP errors.
- **`GOOGLE_CLOUD_LOCATION` support**: Added as a fallback for `GOOGLE_CLOUD_REGION`, consistent with other Google Cloud libraries and tooling.
- Multi-region example script: `examples/providers/vertex_ai_multi_region.exs`

## [0.12.7] - 2026-03-10

### Fixed

- **Vertex AI model routing**: Fixed `build_request_params/3` not including the `"model"` key in the params map, causing `chat/2` and `chat_stream/2` to always fall back to `"gemini-2.0-flash"` regardless of the requested model.
- **Vertex AI 404 on preview models**: Use `v1beta1` API version for preview and experimental models (e.g., `gemini-3.1-pro-preview`). The `v1` endpoint returns 404 for these models.

### Added

- `Nous.Providers.VertexAI.api_version_for_model/1` — returns `"v1beta1"` for preview/experimental models, `"v1"` for stable models.
- `Nous.Providers.VertexAI.endpoint/3` now accepts an optional model name to select the correct API version.
- Debug logging for Vertex AI request URLs.

## [0.12.6] - 2026-03-07

### Added

- **Auto-update memory**: `Nous.Plugins.Memory` can now automatically reflect on conversations and update memories after each run — no explicit tool calls needed. Enable with `auto_update_memory: true` in `memory_config`. Configurable reflection model, frequency, and context limits.
  - New `after_run/3` callback in `Nous.Plugin` behaviour — runs once after the entire agent run completes. Wired into both `AgentRunner.run/3` and `run_with_context/3`.
  - `Nous.Plugin.run_after_run/4` helper for executing the hook across all plugins
  - New config options: `:auto_update_memory`, `:auto_update_every`, `:reflection_model`, `:reflection_max_tokens`, `:reflection_max_messages`, `:reflection_max_memories`
  - New example: `examples/memory/auto_update.exs`

## [0.12.5] - 2026-03-06

### Added

- **Vertex AI provider**: `Nous.Providers.VertexAI` for accessing Gemini models through Google Cloud Vertex AI. Supports enterprise features (VPC-SC, CMEK, regional endpoints, IAM).
  - Three auth modes: app config Goth (`config :nous, :vertex_ai, goth: MyApp.Goth`), per-model Goth (`default_settings: %{goth: MyApp.Goth}`), or direct access token (`api_key` / `VERTEX_AI_ACCESS_TOKEN`)
  - Bearer token auth via `api_key` option, `VERTEX_AI_ACCESS_TOKEN` env var, or Goth integration
  - Goth integration (`{:goth, "~> 1.4", optional: true}`) for automatic service account token management — reuse existing Goth processes from PubSub, etc.
  - URL auto-construction from `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_REGION` env vars
  - `Nous.Providers.VertexAI.endpoint/2` helper to build endpoint URLs
  - Reuses existing Gemini message format, response parsing, and stream normalization
  - Model string: `"vertex_ai:gemini-2.0-flash"`

## [0.12.2] - 2026-03-04

### Fixed

- **Gemini streaming**: Fixed streaming responses returning 0 events. The Gemini `streamGenerateContent` endpoint returns a JSON array (`application/json`) by default, not Server-Sent Events. Instead of forcing SSE via `alt=sse` query parameter, added a pluggable stream parser to `Nous.Providers.HTTP`.

### Added

- `Nous.Providers.HTTP.JSONArrayParser` — stream buffer parser for JSON array responses. Extracts complete JSON objects from a streaming `[{...},{...},...]` response by tracking `{}` nesting depth while respecting string literals and escape sequences.
- `:stream_parser` option on `HTTP.stream/4` — accepts any module implementing `parse_buffer/1` with the same `{events, remaining_buffer}` contract as SSE parsing. Defaults to the existing SSE parser. Enables any provider with a non-SSE streaming format to plug in a custom parser.

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
