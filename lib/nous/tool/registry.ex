defmodule Nous.Tool.Registry do
  @moduledoc """
  Stateless helpers for building and querying tool collections.

  Provides functions to create `Nous.Tool` structs from behaviour modules,
  filter by category or tags, and look up tools by name.

  ## Architecture

  The registry is a pure-functional module operating on plain lists of
  `Nous.Tool.t()` structs. No GenServer or ETS — just pass a list in,
  get a list out.

  ## Quick Start

      tools = Nous.Tool.Registry.from_modules([
        MyApp.Tools.FileRead,
        MyApp.Tools.FileWrite,
        MyApp.Tools.GitStatus
      ])

      # Filter to read-only tools
      read_tools = Nous.Tool.Registry.filter(tools, category: :read)

      # Filter by tag
      git_tools = Nous.Tool.Registry.filter(tools, tags: [:git])

      # Look up by name
      {:ok, tool} = Nous.Tool.Registry.lookup(tools, "file_read")

  """

  alias Nous.Tool

  @doc """
  Build a list of tools from behaviour modules.

  Each module must implement `Nous.Tool.Behaviour`. Options are passed
  through to `Nous.Tool.from_module/2` for each module.

  ## Options

    * Any option accepted by `Nous.Tool.from_module/2` (applied to all modules)

  ## Examples

      tools = Registry.from_modules([MyApp.Tools.Search, MyApp.Tools.FileRead])

      tools = Registry.from_modules([MyApp.Tools.Search], timeout: 60_000)

  """
  @spec from_modules([module()], keyword()) :: [Tool.t()]
  def from_modules(modules, opts \\ []) when is_list(modules) do
    Enum.map(modules, &Tool.from_module(&1, opts))
  end

  @doc """
  Filter tools by category and/or tags.

  When both `:category` and `:tags` are given, a tool must match the
  category AND have at least one of the specified tags.

  ## Options

    * `:category` - Filter to tools with this category
    * `:tags` - Filter to tools having at least one of these tags

  ## Examples

      # By category
      Registry.filter(tools, category: :read)

      # By tags (tool must have at least one matching tag)
      Registry.filter(tools, tags: [:file, :git])

      # Both (must match category AND have at least one tag)
      Registry.filter(tools, category: :read, tags: [:file])

  """
  @spec filter([Tool.t()], keyword()) :: [Tool.t()]
  def filter(tools, opts) when is_list(tools) and is_list(opts) do
    category = Keyword.get(opts, :category)
    tags = Keyword.get(opts, :tags)

    tools
    |> filter_by_category(category)
    |> filter_by_tags(tags)
  end

  @doc """
  Look up a tool by name.

  Returns `{:ok, tool}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      {:ok, tool} = Registry.lookup(tools, "file_read")
      {:error, :not_found} = Registry.lookup(tools, "nonexistent")

  """
  @spec lookup([Tool.t()], String.t()) :: {:ok, Tool.t()} | {:error, :not_found}
  def lookup(tools, name) when is_list(tools) and is_binary(name) do
    case Enum.find(tools, &(&1.name == name)) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  # Private helpers

  defp filter_by_category(tools, nil), do: tools
  defp filter_by_category(tools, category), do: Enum.filter(tools, &(&1.category == category))

  defp filter_by_tags(tools, nil), do: tools
  defp filter_by_tags(tools, []), do: tools

  defp filter_by_tags(tools, tags) when is_list(tags) do
    tag_set = MapSet.new(tags)

    Enum.filter(tools, fn tool ->
      tool.tags |> MapSet.new() |> MapSet.disjoint?(tag_set) |> Kernel.not()
    end)
  end
end
