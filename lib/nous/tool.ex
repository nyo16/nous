defmodule Nous.Tool do
  @moduledoc """
  Tool definition for agent function calling.

  A tool represents a function that an AI agent can call to retrieve
  information or perform actions. Tools are automatically converted to
  OpenAI function calling schemas.

  ## Example

      defmodule MyTools do
        @doc "Search the database for users"
        def search_users(ctx, query) do
          ctx.deps.database
          |> Database.search(query)
          |> format_results()
        end
      end

      # Create tool from function
      tool = Tool.from_function(&MyTools.search_users/2,
        name: "search_users",
        description: "Search for users in the database"
      )

      # Convert to OpenAI schema
      schema = Tool.to_openai_schema(tool)

  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          function: function(),
          takes_ctx: boolean(),
          retries: non_neg_integer(),
          timeout: non_neg_integer() | nil,
          validate_args: boolean(),
          module: module() | nil,
          requires_approval: boolean()
        }

  @enforce_keys [:name, :function]
  defstruct [
    :name,
    :description,
    :parameters,
    :function,
    :module,
    takes_ctx: true,
    retries: 1,
    timeout: 30_000,
    validate_args: true,
    requires_approval: false
  ]

  @doc """
  Create a tool from a function.

  Automatically extracts function metadata including documentation
  and generates a JSON schema for the parameters.

  ## Options

    * `:name` - Custom tool name (default: function name)
    * `:description` - Custom description (default: from @doc)
    * `:parameters` - Custom parameter schema (default: auto-generated)
    * `:retries` - Number of retries on failure (default: 1)
    * `:timeout` - Timeout in milliseconds (default: 30000)
    * `:validate_args` - Whether to validate arguments against schema (default: true)
    * `:requires_approval` - Whether tool needs human approval before execution (default: false)

  ## Examples

      # Simple tool
      tool = Tool.from_function(&MyTools.calculate/2)

      # With custom options
      tool = Tool.from_function(&MyTools.search/2,
        name: "search_database",
        description: "Search for records",
        retries: 3,
        timeout: 60_000
      )

  """
  @spec from_function(function(), keyword()) :: t()
  def from_function(fun, opts \\ []) when is_function(fun) do
    # Get function info
    info = Function.info(fun)
    arity = info[:arity]

    # Determine if function takes context (2 args) or just arguments (1 arg)
    takes_ctx = arity == 2

    # Extract function name
    function_name = get_function_name(fun)

    # Try to extract documentation
    {description, param_schema} =
      extract_function_docs(fun) ||
        {Keyword.get(opts, :description, ""), default_schema()}

    %__MODULE__{
      name: Keyword.get(opts, :name, function_name),
      description: Keyword.get(opts, :description, description),
      parameters: Keyword.get(opts, :parameters, param_schema),
      function: fun,
      takes_ctx: takes_ctx,
      retries: Keyword.get(opts, :retries, 1),
      timeout: Keyword.get(opts, :timeout, 30_000),
      validate_args: Keyword.get(opts, :validate_args, true),
      requires_approval: Keyword.get(opts, :requires_approval, false),
      module: nil
    }
  end

  @doc """
  Create a tool from a module implementing `Nous.Tool.Behaviour`.

  Module-based tools are easier to test because dependencies can be
  injected through the context.

  ## Options

    * `:name` - Override tool name from metadata
    * `:description` - Override description from metadata
    * `:parameters` - Override parameters from metadata
    * `:retries` - Number of retries on failure (default: 1)
    * `:timeout` - Timeout in milliseconds (default: 30000)
    * `:validate_args` - Whether to validate arguments (default: true)
    * `:requires_approval` - Whether tool needs human approval before execution (default: false)

  ## Example

      defmodule MyApp.Tools.Search do
        @behaviour Nous.Tool.Behaviour

        @impl true
        def metadata do
          %{
            name: "search",
            description: "Search the web",
            parameters: %{
              "type" => "object",
              "properties" => %{
                "query" => %{"type" => "string"}
              },
              "required" => ["query"]
            }
          }
        end

        @impl true
        def execute(ctx, %{"query" => query}) do
          http = ctx.deps[:http_client] || MyApp.HTTP
          {:ok, http.search(query)}
        end
      end

      # Create tool from module
      tool = Tool.from_module(MyApp.Tools.Search)

      # Override options
      tool = Tool.from_module(MyApp.Tools.Search, timeout: 60_000, retries: 3)

  """
  @spec from_module(module(), keyword()) :: t()
  def from_module(module, opts \\ []) when is_atom(module) do
    alias Nous.Tool.Behaviour

    unless Behaviour.implements?(module) do
      raise ArgumentError, """
      Module #{inspect(module)} does not implement Nous.Tool.Behaviour.

      Ensure the module has:
        @behaviour Nous.Tool.Behaviour

        @impl true
        def execute(ctx, args) do
          # ...
        end
      """
    end

    metadata = Behaviour.get_metadata(module)

    %__MODULE__{
      name: Keyword.get(opts, :name, metadata.name),
      description: Keyword.get(opts, :description, metadata.description),
      parameters: Keyword.get(opts, :parameters, metadata.parameters),
      function: &module.execute/2,
      takes_ctx: true,
      retries: Keyword.get(opts, :retries, 1),
      timeout: Keyword.get(opts, :timeout, 30_000),
      validate_args: Keyword.get(opts, :validate_args, true),
      requires_approval: Keyword.get(opts, :requires_approval, false),
      module: module
    }
  end

  @doc """
  Convert tool to OpenAI function calling schema.

  ## Example

      schema = Tool.to_openai_schema(tool)
      # %{
      #   "type" => "function",
      #   "function" => %{
      #     "name" => "search_users",
      #     "description" => "Search for users",
      #     "parameters" => %{...}
      #   }
      # }

  """
  @spec to_openai_schema(t()) :: map()
  def to_openai_schema(%__MODULE__{} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description || "No description provided",
        "parameters" => tool.parameters || default_schema()
      }
    }
  end

  # Private functions

  @spec get_function_name(fun()) :: String.t()
  defp get_function_name(fun) do
    info = Function.info(fun)

    case info[:name] do
      name when is_atom(name) ->
        Atom.to_string(name)

      _ ->
        "anonymous_function"
    end
  end

  @spec extract_function_docs(fun()) :: String.t() | nil
  defp extract_function_docs(fun) do
    info = Function.info(fun)

    case info do
      [module: module, name: name, arity: arity] when not is_nil(module) ->
        case Code.fetch_docs(module) do
          {:docs_v1, _, _, _, _, _, docs} ->
            find_function_doc(docs, name, arity)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @spec find_function_doc(list(), atom(), non_neg_integer()) :: String.t() | nil
  defp find_function_doc(docs, function_name, arity) do
    Enum.find_value(docs, fn
      {{:function, ^function_name, ^arity}, _, _, doc, _} when is_map(doc) ->
        # Extract description from doc
        description = Map.get(doc, "en", "")
        # Parse simple parameter schema from description
        param_schema = parse_param_schema(description)
        {description, param_schema}

      _ ->
        nil
    end)
  end

  defp parse_param_schema(doc_string) when is_binary(doc_string) do
    # Simple parsing - look for parameter patterns
    # This is a simplified version; a full implementation would parse markdown
    # and extract parameter types and descriptions

    # For now, return a generic schema
    # In a full implementation, parse lines like:
    # - `query` (string) - The search query
    # - `limit` (integer) - Maximum results

    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Input parameter"
        }
      },
      "required" => []
    }
  end

  defp default_schema do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end
end
