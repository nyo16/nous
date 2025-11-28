# Coderex

A code editing agent built with Yggdrasil, inspired by [Cline's](https://github.com/cline/cline) diff architecture.

## Features

- **SEARCH/REPLACE Diffs** - Apply targeted code modifications using the familiar SEARCH/REPLACE block format
- **3-Tier Fallback Matching** - Exact match → Line-trimmed → Block anchor for robust code matching
- **Pretty Diff Output** - Colorized diff display with line numbers
- **File Operations** - Read, write, edit, list, search files
- **Shell Commands** - Execute shell commands with timeout support

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

## Usage

```elixir
# Create an agent
agent = Coderex.CodeAgent.new("anthropic:claude-sonnet-4-20250514", cwd: "/path/to/project")

# Run a task
{:ok, result} = Coderex.CodeAgent.run(agent, "Add a docstring to the main function")
```

## Demo

```bash
# Run the diff formatter demo
mix run demo_diff.exs
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
├── code_agent.ex      # Main agent with Yggdrasil integration
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

## Credits

Diff algorithm ported from [Cline](https://github.com/cline/cline)'s TypeScript implementation.
