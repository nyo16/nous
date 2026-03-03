defmodule Nous.Teams.Role do
  @moduledoc """
  Role definitions for team agents.

  A role configures an agent's system prompt, tool access, and iteration limits.
  Roles are plain structs with helper functions — no process needed.

  ## Architecture

  Roles are applied when spawning agents into a team. The `system_prompt` is
  prepended to the agent's instructions, and `allowed_tools`/`denied_tools`
  filter the available tool set.

  ## Quick Start

      # Use a built-in role
      role = Role.researcher()

      # Create a custom role
      role = Role.new(name: :reviewer, system_prompt: "Review code carefully", denied_tools: ["execute_code"])

      # Filter tools based on role
      filtered = Role.apply_tool_filter(role, all_tools)
  """

  @type t :: %__MODULE__{
          name: atom(),
          system_prompt: String.t() | nil,
          allowed_tools: [String.t()] | nil,
          denied_tools: [String.t()] | nil,
          max_iterations: pos_integer()
        }

  defstruct [:name, :system_prompt, allowed_tools: nil, denied_tools: nil, max_iterations: 15]

  @doc """
  Create a new role from keyword attributes.

  ## Options

  - `:name` — atom identifying the role (required)
  - `:system_prompt` — system prompt prepended to agent instructions
  - `:allowed_tools` — whitelist of tool names (nil means all allowed)
  - `:denied_tools` — blacklist of tool names (nil means none denied)
  - `:max_iterations` — max agent loop iterations (default: 15)

  ## Examples

      iex> role = Nous.Teams.Role.new(name: :researcher, system_prompt: "Research topics thoroughly")
      iex> role.name
      :researcher
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Filter a list of tools based on the role's allowed/denied lists.

  - If `allowed_tools` is set, only tools in that list are kept.
  - If `denied_tools` is set, tools in that list are removed.
  - If neither is set, all tools are returned.
  - `allowed_tools` takes precedence over `denied_tools`.

  ## Examples

      iex> role = Nous.Teams.Role.new(name: :restricted, allowed_tools: ["search", "read_file"])
      iex> tools = [%Nous.Tool{name: "search", function: &Function.identity/1}, %Nous.Tool{name: "execute", function: &Function.identity/1}]
      iex> filtered = Nous.Teams.Role.apply_tool_filter(role, tools)
      iex> length(filtered)
      1
  """
  @spec apply_tool_filter(t(), [Nous.Tool.t()]) :: [Nous.Tool.t()]
  def apply_tool_filter(%__MODULE__{allowed_tools: allowed} = _role, tools)
      when is_list(allowed) do
    Enum.filter(tools, &(&1.name in allowed))
  end

  def apply_tool_filter(%__MODULE__{denied_tools: denied} = _role, tools)
      when is_list(denied) do
    Enum.reject(tools, &(&1.name in denied))
  end

  def apply_tool_filter(%__MODULE__{}, tools), do: tools

  # Built-in roles

  @doc """
  Default researcher role.

  Focused on information gathering with read-only tool access.

  ## Examples

      iex> role = Nous.Teams.Role.researcher()
      iex> role.name
      :researcher
  """
  @spec researcher() :: t()
  def researcher do
    %__MODULE__{
      name: :researcher,
      system_prompt: """
      You are a research specialist on this team. Your job is to:
      - Gather information from available sources
      - Analyze findings and share discoveries with the team
      - Focus on accuracy and thoroughness
      - Share important findings via share_discovery tool
      """,
      allowed_tools: [
        "search",
        "read_file",
        "web_fetch",
        "recall",
        "share_discovery",
        "peer_message",
        "broadcast_message",
        "list_team"
      ],
      max_iterations: 15
    }
  end

  @doc """
  Default coder role.

  Has access to code editing tools but restricted from destructive operations.

  ## Examples

      iex> role = Nous.Teams.Role.coder()
      iex> role.name
      :coder
  """
  @spec coder() :: t()
  def coder do
    %__MODULE__{
      name: :coder,
      system_prompt: """
      You are a coding specialist on this team. Your job is to:
      - Write clean, well-tested code
      - Claim file regions before editing to prevent conflicts
      - Release regions when done editing
      - Share discoveries about code patterns or issues
      """,
      denied_tools: ["delete_file", "drop_table"],
      max_iterations: 15
    }
  end

  @doc """
  Default lead role.

  Has unrestricted tool access and coordinates the team.

  ## Examples

      iex> role = Nous.Teams.Role.lead()
      iex> role.name
      :lead
  """
  @spec lead() :: t()
  def lead do
    %__MODULE__{
      name: :lead,
      system_prompt: """
      You are the team lead. Your job is to:
      - Coordinate work across team members
      - Delegate tasks to appropriate specialists
      - Synthesize findings from the team
      - Make final decisions when agents disagree
      """,
      max_iterations: 20
    }
  end
end
