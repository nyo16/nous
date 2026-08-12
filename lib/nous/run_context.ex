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

  The struct itself is plain data — build one directly to call a tool
  outside the agent loop, or to assert on what a tool would see:

      iex> ctx = RunContext.new(%{database: MyApp.Database, api_key: "secret"})
      iex> ctx.deps.api_key
      "secret"
      iex> {ctx.retry, ctx.approval_gated?, ctx.usage.total_tokens}
      {0, false, 0}

  """

  alias __MODULE__
  alias Nous.Usage

  @typedoc """
  Decision returned by an approval handler for a single tool call.
  """
  @type approval_decision :: :approve | :reject | {:edit, map()}

  @typedoc """
  Called before an approval-gated tool runs. Receives the same
  `%{name:, id:, arguments:, tool:}` shape the agent runner passes its handler,
  so one handler works for both entry points (`id` is nil outside the runner,
  which is the only place a provider tool-call id exists).
  """
  @type approval_handler :: (map() -> approval_decision())

  @type t(deps) :: %RunContext{
          deps: deps,
          retry: non_neg_integer(),
          usage: Usage.t(),
          approval_handler: approval_handler() | nil,
          approval_gated?: boolean()
        }

  @type t :: t(any())

  @enforce_keys [:deps]
  defstruct [:deps, retry: 0, usage: %Usage{}, approval_handler: nil, approval_gated?: false]

  @doc """
  Create a new run context with dependencies.

  ## Options

    * `:retry` - Current retry count (default: 0)
    * `:usage` - Current usage information (default: empty Usage)
    * `:approval_handler` - Called before a tool with `requires_approval: true`
      runs. Without one, such tools are rejected (see `Nous.ToolExecutor`).
    * `:approval_gated?` - Set by a caller that has ALREADY run its own
      approval pipeline (the agent runner does), so `Nous.ToolExecutor` does
      not prompt a second time. Defaults to `false` — i.e. ungated.

  ## Examples

      iex> ctx = RunContext.new(%{database: MyApp.Database, api_key: "secret"})
      iex> ctx.deps.database
      MyApp.Database

  An approval-gated context carries the handler the tool executor consults
  before running a `requires_approval: true` tool:

      iex> handler = fn %{name: name} -> if name == "delete_all", do: :reject, else: :approve end
      iex> ctx = RunContext.new(%{}, retry: 2, approval_handler: handler)
      iex> {ctx.retry, ctx.approval_handler.(%{name: "delete_all"}), ctx.approval_gated?}
      {2, :reject, false}

  """
  @spec new(deps :: any(), opts :: keyword()) :: t(any())
  def new(deps, opts \\ []) do
    %RunContext{
      deps: deps,
      retry: Keyword.get(opts, :retry, 0),
      usage: Keyword.get(opts, :usage, Usage.new()),
      approval_handler: Keyword.get(opts, :approval_handler),
      approval_gated?: Keyword.get(opts, :approval_gated?, false)
    }
  end
end
