# Tools & Function Calling Examples

Examples showing AI agents calling functions, tools, and external services.

## Learning Path
New to tools? Follow this progression:
1. **[Simple Tool Calling](../tutorials/01-basics/03-tool-calling.exs)** - Single weather function
2. **[Multi-Tool Chaining](../tutorials/01-basics/05-calculator.exs)** - Math operations
3. **[Advanced Tool Usage](../with_tools_working.exs)** - Complex tool coordination

## Simple Tools (Start Here)

### Basic Function Calling
- **[03-tool-calling.exs](../tutorials/01-basics/03-tool-calling.exs)** - Single weather tool
- **[tools_simple.exs](../tools_simple.exs)** - Weather function example
- **[with_tools_working.exs](../with_tools_working.exs)** - Multiple tools demo

### Multi-Tool Coordination
- **[05-calculator.exs](../tutorials/01-basics/05-calculator.exs)** - Math operation chaining
- **[calculator_demo.exs](../calculator_demo.exs)** - Add + multiply operations
- **[complete_tool_example.exs](../complete_tool_example.exs)** - Comprehensive tool usage

## Built-in Tool Suites

### Date & Time Tools
- **[datetime_tools_demo.exs](../datetime_tools_demo.exs)** - Date/time utilities
- Built-in functions for timestamps, formatting, timezone conversion

### String Manipulation Tools
- **[string_tools_demo.exs](../string_tools_demo.exs)** - String processing utilities
- Text analysis, formatting, transformation functions

### Todo & Task Management
- **[todo_tools_demo.exs](../todo_tools_demo.exs)** - Task tracking utilities
- Create, update, complete todo items

### Search & Web Tools
- **[brave_search_demo.exs](../brave_search_demo.exs)** - Web search integration
- **[brave_search_simple.exs](../brave_search_simple.exs)** - Basic search example

## Advanced Tool Patterns

### Custom Tool Development
- **[custom_tools_guide.exs](../custom_tools_guide.exs)** - Building your own tools
- **Tool Development Guide**: [Tool Development](../../docs/guides/tool_development.md)

### Provider-Specific Tool Examples
- **[anthropic_with_tools.exs](../anthropic_with_tools.exs)** - Claude tool calling
- **[tools_with_context.exs](../tools_with_context.exs)** - Context-aware tools

### Production Tool Patterns
- **[05-telemetry.exs](../tutorials/03-production/05-telemetry.exs)** - Tool monitoring
- Error handling and tool failure patterns
- Tool rate limiting and throttling

## Tool Creation Guide

### Basic Tool Template
```elixir
defmodule MyTools do
  @doc "Description of what this tool does"
  def my_tool(_ctx, %{"param" => value}) do
    # Your tool logic here
    result
  end
end

# Use in agent
agent = Nous.new("provider:model",
  tools: [&MyTools.my_tool/2]
)
```

### Tool Parameters
Tools receive two arguments:
1. **Context** (`_ctx`): Execution context (usually unused)
2. **Arguments**: Map of parameters from AI

### Tool Return Values
Tools should return:
- **Simple values**: Strings, numbers, booleans
- **Structured data**: Maps, lists (AI can understand JSON)
- **Avoid**: Complex Elixir structs, PIDs, functions

## Troubleshooting Tools

### Common Issues
- **Tool not called**: Check tool is in `:tools` list and instructions mention it
- **Parameter errors**: Ensure tool function signature matches AI arguments
- **Tool exceptions**: Add error handling to prevent agent crashes

### Debug Tool Calls
```elixir
# Enable debug logging to see tool executions
require Logger
Logger.configure(level: :debug)

{:ok, result} = Nous.run(agent, prompt)
IO.inspect(result.usage, label: "Usage")  # Shows tool_calls count
```

---

**Next Steps:**
- Start with [03-tool-calling.exs](../tutorials/01-basics/03-tool-calling.exs)
- Read the [Tool Development Guide](../../docs/guides/tool_development.md)
- Try building your own custom tools