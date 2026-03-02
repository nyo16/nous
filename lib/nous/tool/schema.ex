defmodule Nous.Tool.Schema do
  @moduledoc """
  Declarative DSL for defining tool schemas.

  Provides a macro-based approach to defining tool metadata, parameters,
  and JSON Schema in a single, readable block. Automatically implements
  `Nous.Tool.Behaviour` callbacks.

  ## Architecture

  When you `use Nous.Tool.Schema`, the module:

  1. Adds `@behaviour Nous.Tool.Behaviour`
  2. Imports the `tool` and `param` macros
  3. Registers a `@before_compile` hook to generate `metadata/0` and `__tool_schema__/0`

  The `tool` macro captures the tool name, description, category, and tags.
  Inside its block, `param` declarations accumulate into `@tool_params`.
  At compile time, these are transformed into JSON Schema and behaviour callbacks.

  ## Quick Start

      defmodule MyApp.Tools.FileRead do
        use Nous.Tool.Schema

        tool "file_read",
          description: "Read a file from the filesystem",
          category: :read,
          tags: [:file] do
            param :path, :string, required: true, doc: "Absolute file path"
            param :offset, :integer, doc: "Line offset to start reading from"
            param :limit, :integer, doc: "Number of lines to read"
        end

        @impl Nous.Tool.Behaviour
        def execute(_ctx, %{"path" => path} = _args) do
          {:ok, File.read!(path)}
        end
      end

  ## Supported Param Types

  | Elixir type | JSON Schema type |
  |-------------|-----------------|
  | `:string`   | `"string"`      |
  | `:integer`  | `"integer"`     |
  | `:number`   | `"number"`      |
  | `:boolean`  | `"boolean"`     |
  | `:array`    | `"array"`       |
  | `:object`   | `"object"`      |
  """

  @type param_def :: %{
          name: atom(),
          type: atom(),
          required: boolean(),
          doc: String.t() | nil
        }

  @doc """
  Set up the Schema DSL in the calling module.

  Injects `@behaviour Nous.Tool.Behaviour`, imports macros, and
  registers a `@before_compile` hook to generate callbacks.

  ## Example

      defmodule MyTool do
        use Nous.Tool.Schema
        # ...
      end

  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Nous.Tool.Behaviour

      import Nous.Tool.Schema, only: [tool: 3, param: 2, param: 3]

      Module.register_attribute(__MODULE__, :tool_params, accumulate: true)
      Module.register_attribute(__MODULE__, :tool_name, [])
      Module.register_attribute(__MODULE__, :tool_description, [])
      Module.register_attribute(__MODULE__, :tool_category, [])
      Module.register_attribute(__MODULE__, :tool_tags, [])

      @before_compile Nous.Tool.Schema
    end
  end

  @doc """
  Define a tool with its name, options, and parameter block.

  ## Options

    * `:description` - Human-readable description of the tool (required)
    * `:category` - Tool category: `:read`, `:write`, `:execute`, `:communicate`, `:search`
    * `:tags` - List of atom tags for filtering (default: `[]`)

  ## Example

      tool "search_web",
        description: "Search the web for information",
        category: :search,
        tags: [:web, :research] do
          param :query, :string, required: true, doc: "Search query"
          param :limit, :integer, doc: "Maximum number of results"
      end

  """
  defmacro tool(name, opts, do: block) do
    description = Keyword.get(opts, :description, "")
    category = Keyword.get(opts, :category)
    tags = Keyword.get(opts, :tags, [])

    quote do
      @tool_name unquote(name)
      @tool_description unquote(description)
      @tool_category unquote(category)
      @tool_tags unquote(tags)

      unquote(block)
    end
  end

  @doc """
  Declare a parameter within a `tool` block.

  ## Arguments

    * `name` - Parameter name as an atom
    * `type` - One of `:string`, `:integer`, `:number`, `:boolean`, `:array`, `:object`
    * `opts` - Keyword options

  ## Options

    * `:required` - Whether the parameter is required (default: `false`)
    * `:doc` - Human-readable description of the parameter

  ## Examples

      param :query, :string, required: true, doc: "The search query"
      param :limit, :integer, doc: "Maximum results to return"
      param :verbose, :boolean

  """
  defmacro param(name, type, opts \\ []) do
    quote do
      @tool_params %{
        name: unquote(name),
        type: unquote(type),
        required: unquote(Keyword.get(opts, :required, false)),
        doc: unquote(Keyword.get(opts, :doc))
      }
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # Params are accumulated in reverse order
    params = Module.get_attribute(env.module, :tool_params) |> Enum.reverse()
    name = Module.get_attribute(env.module, :tool_name)
    description = Module.get_attribute(env.module, :tool_description)
    category = Module.get_attribute(env.module, :tool_category)
    tags = Module.get_attribute(env.module, :tool_tags)

    json_schema = build_json_schema(params)

    metadata = %{
      name: name,
      description: description,
      parameters: json_schema,
      category: category,
      tags: tags
    }

    tool_schema = %{
      name: name,
      description: description,
      category: category,
      tags: tags,
      params: params
    }

    quote do
      @impl Nous.Tool.Behaviour
      @doc false
      def metadata, do: unquote(Macro.escape(metadata))

      @impl Nous.Tool.Behaviour
      @doc false
      def schema, do: unquote(Macro.escape(tool_schema))

      @doc """
      Return the full tool schema definition for introspection.

      Includes parameter declarations, category, and tags.
      """
      @spec __tool_schema__() :: map()
      def __tool_schema__, do: unquote(Macro.escape(tool_schema))
    end
  end

  @doc """
  Convert an Elixir type atom to a JSON Schema type string.

  ## Examples

      iex> Nous.Tool.Schema.type_to_json_type(:string)
      "string"

      iex> Nous.Tool.Schema.type_to_json_type(:integer)
      "integer"

  """
  @spec type_to_json_type(atom()) :: String.t()
  def type_to_json_type(:string), do: "string"
  def type_to_json_type(:integer), do: "integer"
  def type_to_json_type(:number), do: "number"
  def type_to_json_type(:boolean), do: "boolean"
  def type_to_json_type(:array), do: "array"
  def type_to_json_type(:object), do: "object"

  @doc """
  Build a JSON Schema map from a list of param definitions.

  ## Examples

      iex> Nous.Tool.Schema.build_json_schema([
      ...>   %{name: :query, type: :string, required: true, doc: "Search query"},
      ...>   %{name: :limit, type: :integer, required: false, doc: nil}
      ...> ])
      %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"},
          "limit" => %{"type" => "integer"}
        },
        "required" => ["query"]
      }

  """
  @spec build_json_schema([param_def()]) :: map()
  def build_json_schema(params) do
    properties =
      Map.new(params, fn param ->
        prop = %{"type" => type_to_json_type(param.type)}

        prop =
          if param.doc do
            Map.put(prop, "description", param.doc)
          else
            prop
          end

        {Atom.to_string(param.name), prop}
      end)

    required =
      params
      |> Enum.filter(& &1.required)
      |> Enum.map(&Atom.to_string(&1.name))

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
  end
end
