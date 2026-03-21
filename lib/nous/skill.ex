defmodule Nous.Skill do
  @moduledoc """
  Reusable instruction/capability packages for agents.

  Skills inject domain knowledge, tools, and prompt fragments into an agent's
  context. They can be defined as Elixir modules, markdown files, or inline structs.

  ## Skill Groups

  Built-in categories for organizing skills:

  | Group | Purpose |
  |-------|---------|
  | `:coding` | Code generation, implementation, refactoring |
  | `:review` | Code quality, security scanning |
  | `:testing` | Test creation and validation |
  | `:debug` | Bug finding and systematic debugging |
  | `:git` | Version control operations |
  | `:docs` | Documentation generation |
  | `:planning` | Architecture and task decomposition |

  ## Activation Modes

  - `:manual` — only activated explicitly by name
  - `:auto` — activated at agent init, always on
  - `{:on_match, fn}` — activated when user input matches predicate
  - `{:on_tag, tags}` — activated when agent has matching tags
  - `{:on_glob, patterns}` — activated when working with matching file patterns

  ## Module-Based Skills

      defmodule MyApp.Skills.CodeReview do
        use Nous.Skill, tags: [:code, :quality], group: :review

        @impl true
        def name, do: "code_review"

        @impl true
        def description, do: "Reviews code for bugs, style, and quality"

        @impl true
        def instructions(_agent, _ctx) do
          "You are a code review specialist..."
        end

        @impl true
        def match?(input), do: String.contains?(input, "review")
      end

  ## File-Based Skills

  Markdown files with YAML frontmatter in a skills directory:

      ---
      name: code_review
      description: Reviews code for quality and bugs
      tags: [code, review]
      group: review
      activation: auto
      ---

      You are a code review specialist...

  ## Usage

      agent = Agent.new("openai:gpt-4",
        skills: [
          MyApp.Skills.CodeReview,        # module
          "priv/skills/",                 # directory
          {:group, :testing}              # built-in group
        ]
      )
  """

  @type activation ::
          :manual
          | :auto
          | {:on_match, (String.t() -> boolean())}
          | {:on_tag, [atom()]}
          | {:on_glob, [String.t()]}

  @type scope :: :builtin | :project | :personal | :plugin

  @type status :: :discovered | :loaded | :active | :inactive

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          tags: [atom()],
          group: atom() | nil,
          instructions: String.t() | nil,
          tools: [Nous.Tool.t()],
          activation: activation(),
          scope: scope(),
          source: :module | :file | :inline,
          source_ref: module() | String.t() | nil,
          model_override: String.t() | nil,
          allowed_tools: [String.t()] | nil,
          status: status(),
          priority: integer()
        }

  defstruct name: "",
            description: "",
            tags: [],
            group: nil,
            instructions: nil,
            tools: [],
            activation: :manual,
            scope: :project,
            source: :inline,
            source_ref: nil,
            model_override: nil,
            allowed_tools: nil,
            status: :discovered,
            priority: 100

  @doc """
  Called to return the skill name.
  """
  @callback name() :: String.t()

  @doc """
  Called to return the skill description (used for matching).
  """
  @callback description() :: String.t()

  @doc """
  Called to return the skill instructions injected into the system prompt.
  """
  @callback instructions(agent :: Nous.Agent.t(), ctx :: Nous.Agent.Context.t()) :: String.t()

  @doc """
  Called to return tools provided by this skill.
  """
  @callback tools(agent :: Nous.Agent.t(), ctx :: Nous.Agent.Context.t()) :: [Nous.Tool.t()]

  @doc """
  Return tags for categorization and filtering.
  """
  @callback tags() :: [atom()]

  @doc """
  Return the skill group (`:coding`, `:review`, `:testing`, etc.).
  """
  @callback group() :: atom() | nil

  @doc """
  Check if this skill should activate for the given user input.
  """
  @callback match?(input :: String.t()) :: boolean()

  @optional_callbacks [tools: 2, tags: 0, group: 0, match?: 1]

  @doc false
  defmacro __using__(opts) do
    quote do
      @behaviour Nous.Skill
      @skill_opts unquote(opts)

      @impl true
      def tags, do: Keyword.get(@skill_opts, :tags, [])

      @impl true
      def group, do: Keyword.get(@skill_opts, :group)

      defoverridable tags: 0, group: 0
    end
  end

  @doc """
  Build a `Skill.t()` struct from a module implementing the `Nous.Skill` behaviour.
  """
  @spec from_module(module()) :: t()
  def from_module(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    %__MODULE__{
      name: module.name(),
      description: module.description(),
      tags: if(function_exported?(module, :tags, 0), do: module.tags(), else: []),
      group: if(function_exported?(module, :group, 0), do: module.group(), else: nil),
      activation:
        if function_exported?(module, :match?, 1) do
          {:on_match, &module.match?/1}
        else
          :manual
        end,
      source: :module,
      source_ref: module,
      scope: :project,
      status: :loaded
    }
  end
end
