defmodule Nous.Tool.Behaviour do
  @moduledoc """
  Behaviour for tool implementations.

  Allows tools to be defined as modules for better testability and organization.
  Module-based tools can inject dependencies via the context, making them
  easy to test with mocks.

  ## Example

      defmodule MyApp.Tools.Search do
        @behaviour Nous.Tool.Behaviour

        @impl true
        def metadata do
          %{
            name: "search",
            description: "Search the web for information",
            parameters: %{
              "type" => "object",
              "properties" => %{
                "query" => %{
                  "type" => "string",
                  "description" => "The search query"
                }
              },
              "required" => ["query"]
            }
          }
        end

        @impl true
        def execute(ctx, %{"query" => query}) do
          # Inject http_client via deps for testing
          http_client = ctx.deps[:http_client] || Nous.HTTP
          api_key = ctx.deps[:search_api_key]

          case http_client.get("https://api.search.com", query: query, key: api_key) do
            {:ok, results} -> {:ok, format_results(results)}
            {:error, _} = err -> err
          end
        end

        defp format_results(results), do: Enum.map(results, & &1["title"])
      end

  ## Testing

      defmodule MyApp.Tools.SearchTest do
        use ExUnit.Case

        test "search returns formatted results" do
          mock_http = %{
            get: fn _url, _opts ->
              {:ok, [%{"title" => "Result 1"}, %{"title" => "Result 2"}]}
            end
          }

          ctx = Nous.RunContext.new(%{http_client: mock_http, search_api_key: "test"})

          assert {:ok, ["Result 1", "Result 2"]} =
            MyApp.Tools.Search.execute(ctx, %{"query" => "elixir"})
        end
      end

  ## Usage with Agent

      agent = Nous.Agent.new("openai:gpt-4",
        tools: [Nous.Tool.from_module(MyApp.Tools.Search)]
      )

  """

  @doc """
  Execute the tool with context and arguments.

  The context provides access to dependencies and execution metadata.
  Arguments are a map of the parameters passed by the LLM.

  ## Return Values

  - `{:ok, result}` - Success with the result to return to the LLM
  - `{:ok, result, context_update}` - Success with context updates (see `Nous.Tool.ContextUpdate`)
  - `{:error, reason}` - Failure with error reason

  """
  @callback execute(ctx :: Nous.RunContext.t(), args :: map()) ::
              {:ok, any()}
              | {:ok, any(), Nous.Tool.ContextUpdate.t()}
              | {:error, term()}

  @doc """
  Return tool metadata (name, description, parameters).

  This callback is optional. If not implemented, the tool name will be
  derived from the module name.

  ## Return Value

      %{
        name: "tool_name",
        description: "What the tool does",
        parameters: %{
          "type" => "object",
          "properties" => %{...},
          "required" => [...]
        }
      }

  """
  @callback metadata() :: %{
              name: String.t(),
              description: String.t(),
              parameters: map()
            }

  @optional_callbacks [metadata: 0]

  @doc """
  Check if a module implements the Tool.Behaviour.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) when is_atom(module) do
    function_exported?(module, :execute, 2)
  end

  @doc """
  Get metadata from a module, using defaults if metadata/0 is not implemented.
  """
  @spec get_metadata(module()) :: map()
  def get_metadata(module) when is_atom(module) do
    if function_exported?(module, :metadata, 0) do
      module.metadata()
    else
      %{
        name: module_to_name(module),
        description: "",
        parameters: default_schema()
      }
    end
  end

  @doc """
  Convert a module name to a tool name.

  ## Examples

      iex> Nous.Tool.Behaviour.module_to_name(MyApp.Tools.SearchDatabase)
      "search_database"

  """
  @spec module_to_name(module()) :: String.t()
  def module_to_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp default_schema do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end
end
