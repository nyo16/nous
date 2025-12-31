defmodule Nous.Tool.Testing do
  @moduledoc """
  Test helpers for tools.

  Provides utilities for creating mock tools, spy tools, and test contexts
  to make tool testing easier.

  ## Mock Tools

  Create tools that return fixed results:

      test "agent handles search results" do
        mock_search = Tool.Testing.mock_tool("search", %{results: ["a", "b"]})

        agent = Agent.new("test:model", tools: [mock_search])
        # Agent will receive mock results when it calls the search tool
      end

  ## Spy Tools

  Create tools that record all calls for verification:

      test "agent uses search tool correctly" do
        {spy_tool, calls} = Tool.Testing.spy_tool("search", result: %{found: true})

        agent = Agent.new("test:model", tools: [spy_tool])
        Agent.run(agent, "Search for elixir")

        recorded = Tool.Testing.get_calls(calls)
        assert length(recorded) == 1
        assert {_ctx, %{"query" => "elixir"}} = hd(recorded)
      end

  ## Test Contexts

  Create contexts with test dependencies:

      test "database tool queries correctly" do
        mock_db = %{query: fn sql -> [%{id: 1}] end}
        ctx = Tool.Testing.test_context(%{database: mock_db})

        assert {:ok, [%{id: 1}]} = MyTools.DatabaseTool.execute(ctx, %{"sql" => "SELECT *"})
      end

  """

  alias Nous.{Tool, RunContext}

  @doc """
  Create a mock tool that returns a fixed result.

  ## Options

  - `:description` - Tool description (default: "Mock tool for testing")
  - `:parameters` - Tool parameters schema (default: empty object)

  ## Example

      mock = Tool.Testing.mock_tool("search", %{results: []})

  """
  @spec mock_tool(String.t(), any(), keyword()) :: Tool.t()
  def mock_tool(name, result, opts \\ []) do
    description = Keyword.get(opts, :description, "Mock tool for testing")
    parameters = Keyword.get(opts, :parameters, default_schema())

    Tool.from_function(
      fn _ctx, _args -> result end,
      name: name,
      description: description,
      parameters: parameters
    )
  end

  @doc """
  Create a mock tool that returns different results based on a function.

  The function receives (ctx, args) and should return the result.

  ## Example

      mock = Tool.Testing.mock_tool_fn("calculate", fn _ctx, %{"op" => "add", "a" => a, "b" => b} ->
        a + b
      end)

  """
  @spec mock_tool_fn(String.t(), (RunContext.t(), map() -> any()), keyword()) :: Tool.t()
  def mock_tool_fn(name, result_fn, opts \\ []) when is_function(result_fn, 2) do
    description = Keyword.get(opts, :description, "Mock tool for testing")
    parameters = Keyword.get(opts, :parameters, default_schema())

    Tool.from_function(
      result_fn,
      name: name,
      description: description,
      parameters: parameters
    )
  end

  @doc """
  Create a spy tool that records all calls.

  Returns a tuple of {tool, calls_agent} where calls_agent is an Agent process
  that stores all calls. Use `get_calls/1` to retrieve recorded calls.

  ## Options

  - `:result` - Result to return from the tool (default: %{success: true})
  - `:description` - Tool description
  - `:parameters` - Tool parameters schema

  ## Example

      {spy, calls} = Tool.Testing.spy_tool("search")
      # ... use spy in agent ...
      recorded = Tool.Testing.get_calls(calls)

  """
  @spec spy_tool(String.t(), keyword()) :: {Tool.t(), pid()}
  def spy_tool(name, opts \\ []) do
    result = Keyword.get(opts, :result, %{success: true})
    description = Keyword.get(opts, :description, "Spy tool for testing")
    parameters = Keyword.get(opts, :parameters, default_schema())

    {:ok, agent} = Agent.start_link(fn -> [] end)

    tool = Tool.from_function(
      fn ctx, args ->
        Agent.update(agent, fn calls -> [{ctx, args} | calls] end)
        result
      end,
      name: name,
      description: description,
      parameters: parameters
    )

    {tool, agent}
  end

  @doc """
  Create a spy tool that can return different results and track calls.

  Similar to `spy_tool/2` but accepts a function to determine the result.

  ## Example

      {spy, calls} = Tool.Testing.spy_tool_fn("search", fn ctx, args ->
        # Custom logic to determine result
        %{query: args["query"], found: true}
      end)

  """
  @spec spy_tool_fn(String.t(), (RunContext.t(), map() -> any()), keyword()) :: {Tool.t(), pid()}
  def spy_tool_fn(name, result_fn, opts \\ []) when is_function(result_fn, 2) do
    description = Keyword.get(opts, :description, "Spy tool for testing")
    parameters = Keyword.get(opts, :parameters, default_schema())

    {:ok, agent} = Agent.start_link(fn -> [] end)

    tool = Tool.from_function(
      fn ctx, args ->
        Agent.update(agent, fn calls -> [{ctx, args} | calls] end)
        result_fn.(ctx, args)
      end,
      name: name,
      description: description,
      parameters: parameters
    )

    {tool, agent}
  end

  @doc """
  Get recorded calls from a spy tool.

  Returns calls in chronological order (oldest first).

  ## Example

      {spy, calls} = Tool.Testing.spy_tool("search")
      # ... use spy ...
      recorded = Tool.Testing.get_calls(calls)
      assert [{ctx1, args1}, {ctx2, args2}] = recorded

  """
  @spec get_calls(pid()) :: [{RunContext.t(), map()}]
  def get_calls(agent) when is_pid(agent) do
    Agent.get(agent, & &1) |> Enum.reverse()
  end

  @doc """
  Clear recorded calls from a spy tool.

  ## Example

      Tool.Testing.clear_calls(calls)

  """
  @spec clear_calls(pid()) :: :ok
  def clear_calls(agent) when is_pid(agent) do
    Agent.update(agent, fn _ -> [] end)
    :ok
  end

  @doc """
  Get the count of recorded calls.

  ## Example

      assert Tool.Testing.call_count(calls) == 3

  """
  @spec call_count(pid()) :: non_neg_integer()
  def call_count(agent) when is_pid(agent) do
    Agent.get(agent, &length/1)
  end

  @doc """
  Create a RunContext with test dependencies.

  ## Options

  - `:retry` - Retry count (default: 0)
  - `:usage` - Usage struct (default: empty)

  ## Example

      ctx = Tool.Testing.test_context(%{
        database: mock_db,
        http_client: mock_http
      })

  """
  @spec test_context(map(), keyword()) :: RunContext.t()
  def test_context(deps \\ %{}, opts \\ []) do
    RunContext.new(deps, opts)
  end

  @doc """
  Create an Agent.Context with test configuration.

  ## Options

  - `:messages` - Initial messages
  - `:system_prompt` - System prompt
  - `:max_iterations` - Max iterations (default: 10)

  ## Example

      ctx = Tool.Testing.test_agent_context(%{database: mock_db},
        system_prompt: "Be helpful"
      )

  """
  @spec test_agent_context(map(), keyword()) :: Nous.Agent.Context.t()
  def test_agent_context(deps \\ %{}, opts \\ []) do
    Nous.Agent.Context.new(
      deps: deps,
      messages: Keyword.get(opts, :messages, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_iterations: Keyword.get(opts, :max_iterations, 10),
      agent_name: Keyword.get(opts, :agent_name, "test_agent")
    )
  end

  @doc """
  Create a failing tool that raises an error.

  Useful for testing error handling.

  ## Options

  - `:error` - The error to raise (default: RuntimeError)
  - `:message` - Error message (default: "Tool failed")

  ## Example

      failing = Tool.Testing.failing_tool("broken", message: "Connection timeout")

  """
  @spec failing_tool(String.t(), keyword()) :: Tool.t()
  def failing_tool(name, opts \\ []) do
    error_type = Keyword.get(opts, :error, RuntimeError)
    message = Keyword.get(opts, :message, "Tool failed")

    Tool.from_function(
      fn _ctx, _args ->
        raise error_type, message
      end,
      name: name,
      description: "Failing tool for testing error handling"
    )
  end

  @doc """
  Create a tool that returns an error tuple.

  ## Example

      error_tool = Tool.Testing.error_tool("api", :connection_refused)

  """
  @spec error_tool(String.t(), term(), keyword()) :: Tool.t()
  def error_tool(name, error_reason, opts \\ []) do
    description = Keyword.get(opts, :description, "Error tool for testing")

    Tool.from_function(
      fn _ctx, _args ->
        {:error, error_reason}
      end,
      name: name,
      description: description
    )
  end

  @doc """
  Create a tool that sleeps for a duration before returning.

  Useful for testing timeouts.

  ## Example

      slow_tool = Tool.Testing.slow_tool("api_call", 5000, %{result: "ok"})

  """
  @spec slow_tool(String.t(), non_neg_integer(), any(), keyword()) :: Tool.t()
  def slow_tool(name, sleep_ms, result, opts \\ []) do
    description = Keyword.get(opts, :description, "Slow tool for testing timeouts")

    Tool.from_function(
      fn _ctx, _args ->
        Process.sleep(sleep_ms)
        result
      end,
      name: name,
      description: description
    )
  end

  @doc """
  Assert that a spy tool was called with specific arguments.

  ## Example

      Tool.Testing.assert_called(calls, %{"query" => "elixir"})

  """
  @spec assert_called(pid(), map()) :: :ok
  def assert_called(agent, expected_args) when is_pid(agent) and is_map(expected_args) do
    calls = get_calls(agent)

    found = Enum.any?(calls, fn {_ctx, args} ->
      args_match?(args, expected_args)
    end)

    unless found do
      actual_args = Enum.map(calls, fn {_ctx, args} -> args end)
      raise ExUnit.AssertionError,
        message: """
        Expected tool to be called with arguments:
          #{inspect(expected_args)}

        Actual calls:
          #{inspect(actual_args)}
        """
    end

    :ok
  end

  @doc """
  Assert that a spy tool was NOT called.

  ## Example

      Tool.Testing.assert_not_called(calls)

  """
  @spec assert_not_called(pid()) :: :ok
  def assert_not_called(agent) when is_pid(agent) do
    calls = get_calls(agent)

    if calls != [] do
      raise ExUnit.AssertionError,
        message: """
        Expected tool to not be called, but it was called #{length(calls)} time(s):
          #{inspect(calls)}
        """
    end

    :ok
  end

  # Private

  defp default_schema do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end

  defp args_match?(actual, expected) do
    Enum.all?(expected, fn {key, value} ->
      Map.get(actual, key) == value
    end)
  end
end
