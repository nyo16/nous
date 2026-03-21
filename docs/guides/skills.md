# 🎯 Skills Guide

Skills are reusable instruction and capability packages that inject domain knowledge, tools, and prompt fragments into agents.

## Quick Start

```elixir
# Use built-in skills by group
agent = Nous.new("openai:gpt-4",
  skills: [{:group, :review}]
)

# Use specific skill modules
agent = Nous.new("openai:gpt-4",
  skills: [Nous.Skills.CodeReview, Nous.Skills.Debug]
)

# Load skills from markdown files
agent = Nous.new("openai:gpt-4",
  skill_dirs: ["priv/skills/"]
)
```

## Creating Module-Based Skills

Use the `use Nous.Skill` macro for ergonomic skill definition:

```elixir
defmodule MyApp.Skills.ElixirExpert do
  use Nous.Skill, tags: [:elixir, :functional], group: :coding

  @impl true
  def name, do: "elixir_expert"

  @impl true
  def description, do: "Provides Elixir-specific coding guidance"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are an Elixir expert. When writing Elixir code:
    - Prefer pattern matching over conditionals
    - Use the pipe operator for data transformations
    - Leverage OTP for concurrent and fault-tolerant systems
    """
  end

  # Optional: auto-activate when user input matches
  @impl true
  def match?(input) do
    input = String.downcase(input)
    String.contains?(input, ["elixir", "genserver", "phoenix"])
  end

  # Optional: provide tools
  @impl true
  def tools(_agent, _ctx) do
    [Nous.Tool.from_function(&MyTools.read_file/2)]
  end
end
```

### Required Callbacks

| Callback | Returns | Purpose |
|----------|---------|---------|
| `name/0` | `String.t()` | Unique skill identifier |
| `description/0` | `String.t()` | Used for matching and display |
| `instructions/2` | `String.t()` | Injected into agent system prompt |

### Optional Callbacks

| Callback | Returns | Purpose |
|----------|---------|---------|
| `tools/2` | `[Tool.t()]` | Additional tools when skill is active |
| `tags/0` | `[atom()]` | Categorization (auto-set by `use` opts) |
| `group/0` | `atom()` | Skill group (auto-set by `use` opts) |
| `match?/1` | `boolean()` | Auto-activation predicate |

## Creating File-Based Skills

Markdown files with YAML frontmatter:

```markdown
---
name: api_design
description: RESTful API design best practices
tags: [api, rest, design]
group: planning
activation: auto
allowed_tools: [read_file, grep]
priority: 50
---

When designing APIs:
1. Use nouns for resources, verbs for actions
2. Version your API (v1, v2)
3. Use proper HTTP status codes
4. Paginate list endpoints
```

### Frontmatter Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | filename | Skill identifier |
| `description` | string | `""` | Used for matching |
| `tags` | list | `[]` | Categorization tags |
| `group` | string | `nil` | Skill group |
| `activation` | string | `"manual"` | `"manual"` or `"auto"` |
| `allowed_tools` | list | `nil` | Restrict available tools |
| `priority` | integer | `100` | Lower = higher priority |
| `model_override` | string | `nil` | Override model for this skill |

## Skill Groups

Organize skills by domain:

| Group | Purpose | Built-in Skills |
|-------|---------|-----------------|
| `:coding` | Code generation, implementation | Refactor, ExplainCode, ElixirIdioms, EctoPatterns, OtpPatterns, PhoenixLiveView, PythonFastAPI, PythonTyping, PythonDataScience, PythonUv |
| `:review` | Code quality analysis | CodeReview, SecurityScan, PythonSecurity |
| `:testing` | Test creation and validation | TestGen, ElixirTesting, PythonTesting |
| `:debug` | Bug finding and fixing | Debug |
| `:git` | Version control operations | CommitMessage |
| `:docs` | Documentation generation | DocGen |
| `:planning` | Architecture and design | Architect, TaskBreakdown |

Activate entire groups:

```elixir
agent = Nous.new("openai:gpt-4",
  skills: [{:group, :review}, {:group, :testing}]
)
```

## Activation Modes

| Mode | Description | Example |
|------|-------------|---------|
| `:manual` | Only activated explicitly | Default for most skills |
| `:auto` | Activated at agent init | Always-on skills |
| `{:on_match, fn}` | Activated when user input matches | `{:on_match, &String.contains?(&1, "review")}` |
| `{:on_tag, tags}` | Activated when agent has matching tags | `{:on_tag, [:elixir]}` |
| `{:on_glob, patterns}` | Activated for matching file patterns | `{:on_glob, ["**/*.test.ts"]}` |

## Loading Skills from Directories

```elixir
# Via Agent option
agent = Nous.new("openai:gpt-4",
  skill_dirs: ["priv/skills/", "~/.nous/skills/"]
)

# Via Registry API
registry = Nous.Skill.Registry.new()
|> Nous.Skill.Registry.register_directory("priv/skills/")
|> Nous.Skill.Registry.register_directories(["~/.nous/skills/", ".nous/skills/"])
```

Directories are scanned recursively for `.md` files. Supports nested organization:

```
priv/skills/
├── review/
│   ├── code_review.md
│   └── security_scan.md
├── testing/
│   └── tdd.md
└── deployment.md
```

## Mixing Skill Sources

```elixir
agent = Nous.new("openai:gpt-4",
  skills: [
    MyApp.Skills.Custom,              # Module-based
    {:group, :testing},               # Built-in group
    %Nous.Skill{                      # Inline struct
      name: "quick_tip",
      instructions: "Always suggest tests",
      activation: :auto,
      source: :inline,
      status: :loaded
    }
  ],
  skill_dirs: ["priv/skills/"]        # Directory scan
)
```

## Runtime Skill Management

Access the registry during a run via `ctx.deps[:skill_registry]`:

```elixir
alias Nous.Skill.Registry

# Activate/deactivate by name
{instructions, tools, registry} = Registry.activate(registry, "code_review", agent, ctx)
registry = Registry.deactivate(registry, "code_review")

# Group operations
{results, registry} = Registry.activate_group(registry, :review, agent, ctx)
registry = Registry.deactivate_group(registry, :review)

# Query
active = Registry.active_skills(registry)
matched = Registry.match(registry, "review this code")
skills = Registry.by_group(registry, :coding)
skills = Registry.by_tag(registry, :elixir)
```

## Related Resources

- [Examples: 17_skills.exs](../../examples/17_skills.exs)
- [Hooks Guide](hooks.md) — lifecycle interceptors
- [Tool Development Guide](tool_development.md) — creating tools for skills
