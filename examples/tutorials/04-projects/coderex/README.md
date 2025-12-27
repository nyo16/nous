# 🔧 Coderex - AI Code Editor Agent

**Advanced code manipulation pattern** demonstrating precise SEARCH/REPLACE operations with robust diff matching, inspired by [Cline's](https://github.com/cline/cline) architecture.

## 🎯 What is Coderex?

Coderex showcases **intelligent code editing** capabilities with:

- **SEARCH/REPLACE diff format** for precise code modifications
- **3-tier fallback matching** ensuring robust pattern recognition
- **Pretty diff visualization** with colorized output and line numbers
- **Comprehensive file operations** for complete project manipulation
- **Shell command integration** for build and test workflows
- **Preview mode** for safe change validation

## 🚀 Key Features

### Intelligent Code Matching
- **Exact match** → **Line-trimmed** → **Block anchor** fallback system
- **Whitespace tolerance** for real-world code editing scenarios
- **Context-aware matching** to prevent incorrect replacements

### Visual Diff System
- **Colorized output** with syntax highlighting
- **Line number tracking** showing before/after changes
- **File statistics** displaying lines added/removed/modified

### Comprehensive Tool Set
- **File Operations**: Read, write, edit, list, search, create, delete
- **Shell Integration**: Execute commands with timeout and error handling
- **Preview Mode**: Validate changes before applying them

## Diff Format

```
------- SEARCH
[exact content to find]
=======
[replacement content]
+++++++ REPLACE
```

Also supports legacy markers (`<<<<<<< SEARCH` / `>>>>>>> REPLACE`).

## Tools

| Tool | Description |
|------|-------------|
| `read_file` | Read file contents |
| `write_file` | Write/create files |
| `edit_file` | Apply SEARCH/REPLACE diffs with pretty output |
| `preview_edit` | Preview changes without applying |
| `list_files` | List directory contents with glob patterns |
| `search_files` | Search for patterns in files |
| `file_info` | Get file metadata |
| `create_directory` | Create directories |
| `delete_file` | Delete files |
| `execute_command` | Run shell commands |

## Setup

1. Set your API key:
```bash
export ANTHROPIC_API_KEY=your_key_here
```

2. Start IEx:
```bash
iex -S mix
```

## Usage

```elixir
# Create an agent
agent = Coderex.CodeAgent.new("anthropic:claude-haiku-4-5-20251001", cwd: "/path/to/project")

# Run a task
{:ok, result} = Coderex.CodeAgent.run(agent, "Add a docstring to the main function")

# Access the response
result.response
```

## Demo

```bash
# Run the diff formatter demo (no API key needed)
mix run demo_diff.exs

# Run the full agent demo (requires API key)
ANTHROPIC_API_KEY=your_key mix run examples/demo.exs
```

Example output:
```
━━━ calculator.ex ━━━
@@ -4,6 +4,13 @@
   4 -   def add(a, b) do
   5 -     a + b
   6 -   end
   4 +   @doc "Adds two numbers together"
   5 +   def add(a, b) do
   6 +     a + b
   7 +   end

Lines: 12 → 19 (+7)
```

## Architecture

```
lib/coderex/
├── code_agent.ex      # Main agent with Nous integration
├── diff.ex            # SEARCH/REPLACE parsing (ported from Cline)
├── diff_formatter.ex  # Pretty diff output with colors
└── tools/
    ├── file_tools.ex  # File operations
    └── shell_tools.ex # Shell command execution
```

## Tests

```bash
mix test
```

## 🔗 Learning Path Integration

### Prerequisites
- ✅ Basic agent usage → [basic_hello_world.exs](../basic_hello_world.exs)
- ✅ Tool calling → [tools_simple.exs](../tools_simple.exs)
- ✅ File operations → [by_feature/tools/file_operations.exs](../by_feature/tools/file_operations.exs)
- ✅ Error handling → [error_handling_example.exs](../error_handling_example.exs)

### Next Steps
After mastering Coderex, explore:
- 🏦 **[Trading Desk](../trading_desk/)** - Multi-agent coordination with specialized tools
- 🏛️ **[Council](../council/)** - Multi-LLM deliberation for code review scenarios
- 📊 **Custom Tools** → [custom_tools_guide.exs](../custom_tools_guide.exs)
- 🔧 **Tool Development** → [guides/tool_development.md](../guides/tool_development.md)

## 🎓 What You'll Learn

This example demonstrates:

- ✅ **Advanced Tool Design** - Building sophisticated, robust tools with fallback mechanisms
- ✅ **String Manipulation** - Complex pattern matching and text processing
- ✅ **Error Recovery** - Multi-tier matching strategies for reliability
- ✅ **Visual Output** - Creating user-friendly diff displays
- ✅ **File System Operations** - Comprehensive file management patterns
- ✅ **Shell Integration** - Safe command execution with proper error handling
- ✅ **Preview Patterns** - Non-destructive change validation
- ✅ **Production Tool Architecture** - Building tools that work reliably in real codebases

## 💡 Real-World Applications

Coderex patterns are perfect for:

- **Automated Refactoring** - Large-scale code transformations
- **Code Review Automation** - Applying suggested improvements
- **Documentation Updates** - Syncing code changes with documentation
- **Migration Scripts** - Converting between different APIs or patterns
- **Code Generation** - Template-based code creation with precise placement

## Credits

Diff algorithm ported from [Cline](https://github.com/cline/cline)'s TypeScript implementation.

---

**Built with Nous AI** - AI agent framework for Elixir
