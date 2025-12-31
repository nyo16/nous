# Changelog

All notable changes to this project will be documented in this file.

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
