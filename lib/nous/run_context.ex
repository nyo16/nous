defmodule Nous.RunContext do
  @moduledoc """
  Context passed to tools and dynamic prompts during agent execution.

  The RunContext provides access to:
  - Dependencies (deps) - User-provided data like database connections
  - Retry count - Number of times this tool has been retried
  - Usage information - Token and request counts so far

  ## Example with Tool

      defmodule MyTools do
        def search_database(ctx, query) do
          # Access database from dependencies
          ctx.deps.database
          |> Database.search(query)
          |> format_results()
        end
      end

      # Pass deps when running agent
      deps = %{database: MyApp.Database}
      {:ok, result} = Agent.run(agent, "Search for users", deps: deps)

  """

  alias Nous.Usage

  @type t(deps) :: %__MODULE__{
          deps: deps,
          retry: non_neg_integer(),
          usage: Usage.t()
        }

  @type t :: t(any())

  @enforce_keys [:deps]
  defstruct [:deps, retry: 0, usage: %Usage{}]

  @doc """
  Create a new run context with dependencies.

  ## Options

    * `:retry` - Current retry count (default: 0)
    * `:usage` - Current usage information (default: empty Usage)

  ## Example

      deps = %{database: MyApp.Database, api_key: "secret"}
      ctx = RunContext.new(deps)
      # Access in tools: ctx.deps.database

  """
  @spec new(deps :: any(), opts :: keyword()) :: t(any())
  def new(deps, opts \\ []) do
    %__MODULE__{
      deps: deps,
      retry: Keyword.get(opts, :retry, 0),
      usage: Keyword.get(opts, :usage, Usage.new())
    }
  end
end
