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

### Walkthrough: Creating a Module-Based Skill

Build a "SQL Expert" skill from scratch that provides database query guidance and a schema-inspection tool.

**Step 1: Define the module**

```elixir
defmodule MyApp.Skills.SqlExpert do
  use Nous.Skill, tags: [:sql, :database], group: :coding

  @impl true
  def name, do: "sql_expert"

  @impl true
  def description, do: "SQL query optimization and schema design guidance"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a SQL and database expert. When helping with database tasks:

    - Prefer indexed lookups over full table scans
    - Use CTEs for complex queries instead of nested subqueries
    - Always suggest adding appropriate indexes for new queries
    - Warn about N+1 query patterns
    - Recommend EXPLAIN ANALYZE for performance investigation
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "sql", "query", "database", "table", "index",
      "join", "schema", "migration"
    ])
  end

  @impl true
  def tools(_agent, _ctx) do
    [Nous.Tool.from_function(&MyApp.Tools.describe_table/2)]
  end
end
```

**Step 2: Register with an agent**

```elixir
agent = Nous.new("openai:gpt-4",
  skills: [MyApp.Skills.SqlExpert]
)
```

Because `match?/1` is implemented, the skill auto-activates when user input contains keywords like "sql" or "query". The `instructions/2` text is injected into the system prompt and the `describe_table` tool becomes available.

**Step 3: Verify activation**

```elixir
# The skill activates automatically for matching input
{:ok, result} = Nous.run(agent, "Help me optimize this SQL query")

# Or activate manually via the registry
registry = Nous.Skill.Registry.resolve([MyApp.Skills.SqlExpert])
{instructions, tools, registry} = Nous.Skill.Registry.activate(registry, "sql_expert", agent, ctx)
```

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

### Walkthrough: Creating a File-Based Skill

Build a "REST API Design" skill as a markdown file.

**Step 1: Create the skill file**

Create `priv/skills/api_design.md`:

```markdown
---
name: api_design
description: RESTful API design conventions and best practices
tags: [api, rest, http]
group: planning
activation: auto
priority: 80
---

When designing or reviewing REST APIs, follow these conventions:

## Resource Naming
- Use plural nouns for collections: `/users`, `/orders`
- Use nested routes for relationships: `/users/:id/orders`
- Avoid verbs in URLs; use HTTP methods instead

## HTTP Methods
- GET for retrieval (idempotent, cacheable)
- POST for creation (returns 201 with Location header)
- PUT for full replacement, PATCH for partial updates
- DELETE for removal (idempotent, returns 204)

## Response Patterns
- Paginate list endpoints with `?page=1&per_page=25`
- Return consistent error shapes: `{"error": {"code": "...", "message": "..."}}`
- Use 422 for validation errors, 409 for conflicts
```

**Step 2: Load the skill**

Load it individually or from a directory:

```elixir
# Single file
{:ok, skill} = Nous.Skill.Loader.load_file("priv/skills/api_design.md")
skill.name        #=> "api_design"
skill.tags        #=> [:api, :rest, :http]
skill.activation  #=> :auto
skill.source      #=> :file

# Or load an entire directory
agent = Nous.new("openai:gpt-4",
  skills: ["priv/skills/"]
)
```

**Step 3: Verify in the registry**

```elixir
registry = Nous.Skill.Registry.resolve(["priv/skills/"])

Nous.Skill.Registry.list(registry)
#=> ["api_design"]

skill = Nous.Skill.Registry.get(registry, "api_design")
skill.group       #=> :planning
skill.status      #=> :loaded
```

Because `activation: auto` is set, this skill activates automatically at agent init. Its instructions are injected into the system prompt for every request.

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

### Walkthrough: Skill Groups

Organize your own skills into groups by setting the `group` option, then activate or deactivate the entire group at once.

**Step 1: Tag your skills with a group**

```elixir
defmodule MyApp.Skills.InputValidation do
  use Nous.Skill, tags: [:validation], group: :quality

  @impl true
  def name, do: "input_validation"
  @impl true
  def description, do: "Input validation patterns and sanitization"
  @impl true
  def instructions(_agent, _ctx), do: "Validate all user inputs. Sanitize strings..."
end

defmodule MyApp.Skills.ErrorHandling do
  use Nous.Skill, tags: [:errors], group: :quality

  @impl true
  def name, do: "error_handling"
  @impl true
  def description, do: "Consistent error handling and reporting"
  @impl true
  def instructions(_agent, _ctx), do: "Use tagged tuples {:ok, result} | {:error, reason}..."
end
```

For file-based skills, set `group` in the frontmatter:

```markdown
---
name: logging_standards
group: quality
activation: manual
---
Always use structured logging with Logger metadata...
```

**Step 2: Register a group directory**

If your skills live in a directory organized by group, register the whole tree:

```
priv/skills/
├── quality/
│   ├── input_validation.md
│   ├── error_handling.md
│   └── logging_standards.md
└── deployment/
    └── docker_best_practices.md
```

```elixir
registry = Nous.Skill.Registry.new()
|> Nous.Skill.Registry.register_directory("priv/skills/")

# Query by group
quality_skills = Nous.Skill.Registry.by_group(registry, :quality)
length(quality_skills)  #=> 3
```

**Step 3: Activate/deactivate a group at runtime**

```elixir
# Activate all :quality skills at once
{results, registry} = Nous.Skill.Registry.activate_group(registry, :quality, agent, ctx)
# results is a list of {instructions, tools} tuples, one per skill

# Deactivate the whole group
registry = Nous.Skill.Registry.deactivate_group(registry, :quality)
```

You can also use `{:group, :quality}` in the agent's skills list to register built-in skills for that group:

```elixir
agent = Nous.new("openai:gpt-4",
  skills: [
    {:group, :quality},           # built-in group (if any)
    "priv/skills/quality/"        # your custom group directory
  ]
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

### `:manual`

The default mode. The skill is registered but only activates when you explicitly activate it:

```elixir
# Define with manual activation (the default)
%Nous.Skill{
  name: "advanced_debugging",
  activation: :manual,
  instructions: "Use systematic binary search to isolate bugs..."
}

# Must activate explicitly
{instructions, tools, registry} =
  Nous.Skill.Registry.activate(registry, "advanced_debugging", agent, ctx)
```

Use `:manual` for specialized skills that should only engage when the user or your application logic requests them.

### `:auto`

The skill activates automatically when the agent initializes. Its instructions and tools are available from the first request:

```elixir
defmodule MyApp.Skills.CodeStyle do
  use Nous.Skill, tags: [:style], group: :coding

  @impl true
  def name, do: "code_style"
  @impl true
  def description, do: "Enforces project code style"
  @impl true
  def instructions(_agent, _ctx), do: "Follow the project style guide..."
end
```

For file-based skills, set `activation: auto` in frontmatter:

```markdown
---
name: code_style
activation: auto
---
Follow the project style guide...
```

Use `:auto` for skills that should always be active -- style guides, project conventions, safety rules.

### `{:on_match, fn}`

The skill activates dynamically when user input matches a predicate function. The Skills plugin checks this on every request via `before_request`:

```elixir
# Module-based: implement match?/1
defmodule MyApp.Skills.DatabaseExpert do
  use Nous.Skill, tags: [:database], group: :coding

  @impl true
  def name, do: "database_expert"
  @impl true
  def description, do: "Database query and schema guidance"
  @impl true
  def instructions(_agent, _ctx), do: "When working with databases..."

  @impl true
  def match?(input) do
    input = String.downcase(input)
    String.contains?(input, ["sql", "query", "migration", "schema", "ecto"])
  end
end
```

When `match?/1` is defined on a module, `Skill.from_module/1` sets the activation to `{:on_match, &module.match?/1}`.

For inline skills, pass the function directly:

```elixir
%Nous.Skill{
  name: "docker_expert",
  activation: {:on_match, fn input ->
    input |> String.downcase() |> String.contains?(["docker", "container", "dockerfile"])
  end},
  instructions: "When working with Docker..."
}
```

### `{:on_tag, tags}`

Activates when the agent has matching tags. Useful for skills that should only apply to certain types of agents:

```elixir
%Nous.Skill{
  name: "phoenix_patterns",
  activation: {:on_tag, [:elixir, :phoenix]},
  instructions: "Use Phoenix conventions..."
}
```

### `{:on_glob, patterns}`

Activates when the working context involves files matching the given glob patterns:

```elixir
%Nous.Skill{
  name: "react_testing",
  activation: {:on_glob, ["**/*.test.tsx", "**/*.spec.tsx"]},
  instructions: "When writing React tests, use React Testing Library..."
}
```

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

## Skills Plugin Configuration

The `Nous.Plugins.Skills` plugin bridges skill definitions into the agent lifecycle. It is automatically added when you pass `skills: [...]` to `Nous.Agent.new/2`.

### Lifecycle

The plugin hooks into four stages:

| Stage | What happens |
|-------|-------------|
| `init` | Resolves all skill specs into a registry, auto-activates `:auto` skills |
| `system_prompt` | Collects instructions from all active skills, injects them into the system prompt |
| `tools` | Collects tools from all active skills, adds them to the tool list |
| `before_request` | Matches the latest user message against skills with `{:on_match, fn}` activation, auto-activates matches |

### How the registry is stored

The Skills plugin stores the registry in `ctx.deps[:skill_registry]`. This means you can access and modify it from tools or hooks:

```elixir
# In a tool: read the registry
def list_active_skills(ctx, _args) do
  registry = ctx.deps[:skill_registry]

  if registry do
    active = Nous.Skill.Registry.active_skills(registry)
    Enum.map(active, & &1.name)
  else
    []
  end
end
```

### Activate/deactivate skills at runtime

Since the registry lives in deps, you can modify it from a tool using `ContextUpdate`:

```elixir
alias Nous.Tool.ContextUpdate

def activate_skill(ctx, %{"skill_name" => name}) do
  registry = ctx.deps[:skill_registry]
  agent = ctx.deps[:agent]  # if you stored the agent in deps

  case registry do
    nil ->
      {:error, "No skill registry found"}

    registry ->
      {instructions, tools, updated_registry} =
        Nous.Skill.Registry.activate(registry, name, agent, ctx)

      {:ok, %{activated: name, has_instructions: instructions != nil},
       ContextUpdate.new() |> ContextUpdate.set(:skill_registry, updated_registry)}
  end
end

def deactivate_skill(ctx, %{"skill_name" => name}) do
  registry = ctx.deps[:skill_registry]

  case registry do
    nil ->
      {:error, "No skill registry found"}

    registry ->
      updated = Nous.Skill.Registry.deactivate(registry, name)

      {:ok, %{deactivated: name},
       ContextUpdate.new() |> ContextUpdate.set(:skill_registry, updated)}
  end
end
```

### Skill injection into the system prompt

When multiple skills are active, their instructions are joined with `---` separators and each is labeled with a `## Skill: <name>` header:

```
## Skill: code_review

You are a code review specialist...

---

## Skill: security_scan

Check for common security vulnerabilities...
```

Skills are sorted by priority (lower number = higher priority, default is 100). Use the `priority` field to control ordering when instruction order matters.

## Related Resources

- [Examples: 17_skills.exs](../../examples/17_skills.exs)
- [Context Guide](context.md) -- state management and dependencies
- [Hooks Guide](hooks.md) -- lifecycle interceptors
- [Tool Development Guide](tool_development.md) -- creating tools for skills
