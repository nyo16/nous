defmodule Nous.Teams.Role do
  @moduledoc """
  Role definitions for team agents.

  A role configures an agent's system prompt, tool access, and iteration limits.
  Roles are plain structs with helper functions — no process needed.

  ## Enforcement

  `Nous.Teams.Coordinator.spawn_agent/4` (and `Nous.Teams.spawn_agent/4`)
  apply the `:role` option to the agent config through `apply_to_config/2`
  before the `Nous.AgentServer` is started:

    * **Tool access** — `allowed_tools`/`denied_tools` become a
      `Nous.Permissions.Policy` (see `to_policy/1`), combined with any
      `:permissions` already in the agent config via
      `Nous.Permissions.Policy.strictest/2`, so a role can only narrow an
      existing policy. Because it is the agent's policy, the runner enforces it
      on every path: blocked tools are removed from the tool list sent to the
      model (plugin tools included), a call to one is refused without running
      it, Code Mode bindings only expose granted tools, and sub-agents inherit
      it. Tool names match case-insensitively. When both lists are set, a tool
      must be allowed AND not denied. An empty `allowed_tools` list allows
      nothing.
    * **System prompt** — `system_prompt` is **prepended** to the agent's
      `:instructions`, separated by a blank line.
    * **Iterations** — `max_iterations` becomes the agent's per-run iteration
      ceiling; if the agent config already sets `:max_iterations`, the lower of
      the two wins. `nil` leaves the agent's own ceiling in place.

  ## Quick Start

      # Use a built-in role
      role = Role.researcher()

      # Create a custom role
      role = Role.new(name: :reviewer, system_prompt: "Review code carefully", denied_tools: ["execute_code"])

      # Spawn an agent under it
      Nous.Teams.spawn_agent(team_id, "rita", %{model: "openai:gpt-4o"}, role: role)

      # Filter a tool list the same way the policy would
      filtered = Role.apply_tool_filter(role, all_tools)
  """

  alias __MODULE__
  alias Nous.Permissions
  alias Nous.Permissions.Policy

  @type t :: %Role{
          name: atom(),
          system_prompt: String.t() | nil,
          allowed_tools: [String.t()] | nil,
          denied_tools: [String.t()] | nil,
          max_iterations: pos_integer() | nil
        }

  defstruct [:name, :system_prompt, allowed_tools: nil, denied_tools: nil, max_iterations: 15]

  @doc """
  Create a new role from keyword attributes.

  ## Options

  - `:name` — atom identifying the role (required)
  - `:system_prompt` — system prompt prepended to agent instructions
  - `:allowed_tools` — whitelist of tool names (nil means all allowed)
  - `:denied_tools` — blacklist of tool names (nil means none denied)
  - `:max_iterations` — max agent loop iterations (default: 15; `nil` keeps
    the agent's own ceiling)

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
  Check that a role is well formed before it is enforced.

  `Role.new/1` builds the struct without checking field values;
  `Nous.Teams.Coordinator.spawn_agent/4` calls this and refuses an invalid
  role rather than spawning an agent it cannot restrict.

  ## Examples

      iex> Nous.Teams.Role.validate(Nous.Teams.Role.researcher())
      :ok

      iex> Nous.Teams.Role.validate(Nous.Teams.Role.new(name: :x, max_iterations: 0))
      {:error, {:max_iterations, 0}}
  """
  @spec validate(t()) :: :ok | {:error, {atom(), term()}}
  def validate(%Role{} = role) do
    cond do
      not tool_names?(role.allowed_tools) -> {:error, {:allowed_tools, role.allowed_tools}}
      not tool_names?(role.denied_tools) -> {:error, {:denied_tools, role.denied_tools}}
      not prompt?(role.system_prompt) -> {:error, {:system_prompt, role.system_prompt}}
      not iterations?(role.max_iterations) -> {:error, {:max_iterations, role.max_iterations}}
      true -> :ok
    end
  end

  defp tool_names?(nil), do: true
  defp tool_names?(names) when is_list(names), do: Enum.all?(names, &is_binary/1)
  defp tool_names?(_), do: false

  defp prompt?(prompt), do: is_nil(prompt) or is_binary(prompt)

  defp iterations?(max), do: is_nil(max) or (is_integer(max) and max > 0)

  @doc """
  Translate the role's tool restrictions into a `Nous.Permissions.Policy`.

  Returns `nil` when the role restricts nothing (`allowed_tools` is `nil` and
  `denied_tools` is `nil` or empty).

  - `allowed_tools` becomes the policy allowlist (deny-by-default). An empty
    list yields a `:strict` policy with no allowlist, which blocks every tool.
  - `denied_tools` becomes the policy denylist; it applies even when
    `allowed_tools` is set.

  ## Examples

      iex> policy = Nous.Teams.Role.to_policy(Nous.Teams.Role.coder())
      iex> Nous.Permissions.blocked?(policy, "delete_file")
      true
      iex> Nous.Permissions.blocked?(policy, "read_file")
      false

      iex> Nous.Teams.Role.to_policy(Nous.Teams.Role.lead())
      nil
  """
  @spec to_policy(t()) :: Policy.t() | nil
  def to_policy(%Role{allowed_tools: nil, denied_tools: denied}) when denied in [nil, []],
    do: nil

  def to_policy(%Role{allowed_tools: [], denied_tools: denied}) do
    # An empty allowlist on a :default policy reads as "no allowlist" and would
    # fail open; :strict with no allowlist is the deny-everything form.
    %{Permissions.build_policy(deny: denied || []) | mode: :strict}
  end

  def to_policy(%Role{allowed_tools: allowed, denied_tools: denied}) do
    Permissions.build_policy(allow: allowed || [], deny: denied || [])
  end

  @doc """
  Apply the role to an `Nous.AgentServer` agent config map.

  This is what `Nous.Teams.Coordinator.spawn_agent/4` does with its `:role`
  option. It sets:

  - `:permissions` — `Nous.Permissions.Policy.strictest/2` of the config's
    existing policy and `to_policy/1`
  - `:instructions` — `system_prompt` prepended to the existing instructions
  - `:max_iterations` — the lower of the config's value (if any) and the role's

  ## Examples

      iex> config = Nous.Teams.Role.apply_to_config(Nous.Teams.Role.coder(), %{instructions: "Be brief"})
      iex> config.max_iterations
      15
      iex> String.ends_with?(config.instructions, "\\n\\nBe brief")
      true
      iex> Nous.Permissions.blocked?(config.permissions, "drop_table")
      true
  """
  @spec apply_to_config(t(), map()) :: map()
  def apply_to_config(%Role{} = role, agent_config) when is_map(agent_config) do
    agent_config
    |> put_permissions(to_policy(role))
    |> put_instructions(role.system_prompt)
    |> put_max_iterations(role.max_iterations)
  end

  defp put_permissions(config, nil), do: config

  defp put_permissions(config, %Policy{} = role_policy) do
    Map.put(config, :permissions, Policy.strictest(Map.get(config, :permissions), role_policy))
  end

  defp put_instructions(config, prompt) when prompt in [nil, ""], do: config

  defp put_instructions(config, prompt) when is_binary(prompt) do
    Map.update(config, :instructions, prompt, &prepend_prompt(prompt, &1))
  end

  defp prepend_prompt(prompt, nil), do: prompt
  defp prepend_prompt(prompt, ""), do: prompt

  defp prepend_prompt(prompt, instructions) when is_binary(instructions),
    do: String.trim_trailing(prompt) <> "\n\n" <> instructions

  defp prepend_prompt(prompt, instructions) when is_function(instructions, 1),
    do: fn run_ctx -> prepend_prompt(prompt, instructions.(run_ctx)) end

  defp put_max_iterations(config, nil), do: config

  defp put_max_iterations(config, max) when is_integer(max) and max > 0 do
    Map.update(config, :max_iterations, max, fn
      existing when is_integer(existing) and existing > 0 -> min(existing, max)
      _ -> max
    end)
  end

  @doc """
  Filter a list of tools based on the role's allowed/denied lists.

  Uses the same rules as the policy from `to_policy/1`:

  - If `allowed_tools` is set, only tools in that list are kept.
  - If `denied_tools` is set, tools in that list are removed (also when
    `allowed_tools` is set).
  - If neither is set, all tools are returned.

  ## Examples

      iex> role = Nous.Teams.Role.new(name: :restricted, allowed_tools: ["search", "read_file"])
      iex> tools = [%Nous.Tool{name: "search", function: &Function.identity/1}, %Nous.Tool{name: "execute", function: &Function.identity/1}]
      iex> filtered = Nous.Teams.Role.apply_tool_filter(role, tools)
      iex> length(filtered)
      1
  """
  @spec apply_tool_filter(t(), [Nous.Tool.t()]) :: [Nous.Tool.t()]
  def apply_tool_filter(%Role{} = role, tools) when is_list(tools) do
    Permissions.filter_tools(to_policy(role), tools)
  end

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
    %Role{
      name: :researcher,
      system_prompt: """
      You are a research specialist on this team. Your job is to:
      - Gather information from available sources
      - Analyze findings and share discoveries with the team
      - Focus on accuracy and thoroughness
      - Share important findings via share_discovery tool
      """,
      # Real tool names (enforced since 0.18.2): read-only file, web and
      # knowledge-base tools plus memory recall and the team tools.
      allowed_tools: [
        "file_read",
        "file_glob",
        "file_grep",
        "search",
        "web_search",
        "news_search",
        "fetch_page",
        "scrape_results",
        "kb_search",
        "kb_read",
        "kb_list",
        "kb_backlinks",
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
    %Role{
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
    %Role{
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
