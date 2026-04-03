defmodule Nous.Permissions do
  @moduledoc """
  Tool-level permission policy engine.

  Controls which tools can be used, which require user approval,
  and which are denied entirely. This operates at the tool level —
  for message-level input filtering, see `Nous.Plugins.InputGuard`.

  ## Quick Start

      # Use a preset policy
      policy = Nous.Permissions.default_policy()

      # Check tool access
      Nous.Permissions.blocked?(policy, "bash")
      #=> false

      Nous.Permissions.requires_approval?(policy, "bash")
      #=> true

      Nous.Permissions.requires_approval?(policy, "file_read")
      #=> false

      # Filter a tool list
      tools = [bash_tool, read_tool, write_tool]
      allowed = Nous.Permissions.filter_tools(policy, tools)

  ## Custom Policies

      policy = %Nous.Permissions.Policy{
        mode: :default,
        deny_names: MapSet.new(["bash"]),
        deny_prefixes: ["web_"],
        approval_required: MapSet.new(["file_write", "file_edit"])
      }

  """

  alias Nous.Permissions.Policy

  @doc """
  Returns the default permission policy.

  Read and search tools are open. Write and execute tools require approval.
  """
  @spec default_policy() :: Policy.t()
  def default_policy do
    %Policy{
      mode: :default,
      approval_required: MapSet.new(["bash", "file_write", "file_edit"]),
      deny_names: MapSet.new(),
      deny_prefixes: []
    }
  end

  @doc """
  Returns a permissive policy where all tools are open.
  """
  @spec permissive_policy() :: Policy.t()
  def permissive_policy do
    %Policy{mode: :permissive}
  end

  @doc """
  Returns a strict policy where all tools require approval.
  """
  @spec strict_policy() :: Policy.t()
  def strict_policy do
    %Policy{mode: :strict}
  end

  @doc """
  Creates a policy from keyword options.

  ## Options

    * `:mode` — `:default`, `:permissive`, or `:strict`
    * `:deny` — list of tool names to block
    * `:deny_prefixes` — list of prefixes to block (e.g. `["web_"]`)
    * `:approval_required` — list of tool names requiring approval

  ## Examples

      policy = Nous.Permissions.build_policy(
        mode: :default,
        deny: ["bash"],
        deny_prefixes: ["web_"],
        approval_required: ["file_write"]
      )

  """
  @spec build_policy(keyword()) :: Policy.t()
  def build_policy(opts \\ []) do
    %Policy{
      mode: Keyword.get(opts, :mode, :default),
      deny_names: opts |> Keyword.get(:deny, []) |> Enum.map(&String.downcase/1) |> MapSet.new(),
      deny_prefixes: opts |> Keyword.get(:deny_prefixes, []) |> Enum.map(&String.downcase/1),
      approval_required:
        opts
        |> Keyword.get(:approval_required, [])
        |> Enum.map(&String.downcase/1)
        |> MapSet.new()
    }
  end

  @doc """
  Checks if a tool name is blocked by the policy.

  Matches against deny_names (exact, case-insensitive) and
  deny_prefixes (prefix match, case-insensitive).

  ## Examples

      iex> policy = %Nous.Permissions.Policy{deny_names: MapSet.new(["bash"]), deny_prefixes: ["web_"]}
      iex> Nous.Permissions.blocked?(policy, "bash")
      true
      iex> Nous.Permissions.blocked?(policy, "web_fetch")
      true
      iex> Nous.Permissions.blocked?(policy, "file_read")
      false

  """
  @spec blocked?(Policy.t(), String.t()) :: boolean()
  def blocked?(%Policy{deny_names: deny_names, deny_prefixes: deny_prefixes}, tool_name) do
    name = String.downcase(tool_name)

    MapSet.member?(deny_names, name) or
      Enum.any?(deny_prefixes, &String.starts_with?(name, String.downcase(&1)))
  end

  @doc """
  Checks if a tool requires approval under the policy.

  ## Examples

      iex> policy = Nous.Permissions.strict_policy()
      iex> Nous.Permissions.requires_approval?(policy, "file_read")
      true

      iex> policy = Nous.Permissions.permissive_policy()
      iex> Nous.Permissions.requires_approval?(policy, "bash")
      false

  """
  @spec requires_approval?(Policy.t(), String.t()) :: boolean()
  def requires_approval?(%Policy{mode: :permissive}, _tool_name), do: false
  def requires_approval?(%Policy{mode: :strict}, _tool_name), do: true

  def requires_approval?(%Policy{mode: :default, approval_required: required}, tool_name) do
    MapSet.member?(required, String.downcase(tool_name))
  end

  @doc """
  Filters a list of `Nous.Tool` structs, removing blocked tools.

  ## Examples

      tools = [bash_tool, read_tool, write_tool]
      policy = Nous.Permissions.build_policy(deny: ["bash"])
      filtered = Nous.Permissions.filter_tools(policy, tools)
      # Returns [read_tool, write_tool]

  """
  @spec filter_tools(Policy.t(), [Nous.Tool.t()]) :: [Nous.Tool.t()]
  def filter_tools(%Policy{} = policy, tools) when is_list(tools) do
    Enum.reject(tools, fn tool ->
      blocked?(policy, tool.name)
    end)
  end

  @doc """
  Partitions tools into {allowed, blocked} based on the policy.

  ## Examples

      {allowed, denied} = Nous.Permissions.partition_tools(policy, tools)

  """
  @spec partition_tools(Policy.t(), [Nous.Tool.t()]) :: {[Nous.Tool.t()], [Nous.Tool.t()]}
  def partition_tools(%Policy{} = policy, tools) when is_list(tools) do
    Enum.split_with(tools, fn tool ->
      not blocked?(policy, tool.name)
    end)
  end
end
