defmodule Nous.Eval.Runner do
  @moduledoc """
  Executes evaluation suites against agents.

  The runner handles:
  - Running individual test cases
  - Parallel execution
  - Metrics collection
  - A/B testing
  - Error handling and retries
  """

  require Logger

  alias Nous.Eval.{Suite, TestCase, Result, SuiteResult, Metrics, Evaluator, Config}

  @doc """
  Run an evaluation suite.
  """
  @spec run(Suite.t(), keyword()) :: {:ok, SuiteResult.t()} | {:error, term()}
  def run(%Suite{} = suite, opts \\ []) do
    # Validate suite first
    case Suite.validate(suite) do
      :ok ->
        do_run(suite, opts)

      {:error, reason} ->
        {:error, {:validation_error, reason}}
    end
  end

  @doc """
  Run a single test case.
  """
  @spec run_case(TestCase.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run_case(%TestCase{} = test_case, opts \\ []) do
    # Validate test case
    case TestCase.validate(test_case) do
      :ok ->
        result = execute_test_case(test_case, nil, opts)
        {:ok, result}

      {:error, reason} ->
        {:error, {:validation_error, reason}}
    end
  end

  @doc """
  Run A/B comparison between two configurations.
  """
  @spec run_ab(Suite.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_ab(%Suite{} = suite, opts \\ []) do
    config_a = Keyword.get(opts, :config_a, [])
    config_b = Keyword.get(opts, :config_b, [])

    base_opts = Keyword.drop(opts, [:config_a, :config_b])

    with {:ok, result_a} <- run(suite, Keyword.merge(base_opts, config_a)),
         {:ok, result_b} <- run(suite, Keyword.merge(base_opts, config_b)) do
      comparison =
        if result_a.metrics_summary && result_b.metrics_summary do
          Metrics.Summary.compare(result_a.metrics_summary, result_b.metrics_summary)
        else
          %{winner: determine_winner(result_a, result_b)}
        end

      {:ok,
       %{
         a: result_a,
         b: result_b,
         comparison: comparison
       }}
    end
  end

  # Private implementation

  defp do_run(%Suite{} = suite, opts) do
    started_at = DateTime.utc_now()

    # Apply tag filters
    suite = apply_tag_filters(suite, opts)

    # Run setup if present
    setup_result = run_setup(suite)

    # Get parallelism
    parallelism = opts[:parallelism] || suite.parallelism || 1

    # Execute test cases
    results =
      if parallelism > 1 do
        run_parallel(suite, opts, parallelism, setup_result)
      else
        run_sequential(suite, opts, setup_result)
      end

    # Run teardown if present
    run_teardown(suite, setup_result)

    completed_at = DateTime.utc_now()

    suite_result = SuiteResult.from_results(suite.name, results, started_at, completed_at)

    {:ok, suite_result}
  end

  defp apply_tag_filters(suite, opts) do
    suite =
      case Keyword.get(opts, :tags) do
        nil -> suite
        tags when is_list(tags) -> Suite.filter_by_tags(suite, tags)
        tag when is_atom(tag) -> Suite.filter_by_tags(suite, [tag])
      end

    case Keyword.get(opts, :exclude_tags) do
      nil -> suite
      tags when is_list(tags) -> Suite.exclude_tags(suite, tags)
      tag when is_atom(tag) -> Suite.exclude_tags(suite, [tag])
    end
  end

  defp run_setup(%Suite{setup: nil}), do: %{}

  defp run_setup(%Suite{setup: setup}) when is_function(setup, 0) do
    try do
      setup.()
    rescue
      e ->
        Logger.warning("[Nous.Eval] Setup failed: #{inspect(e)}")
        %{}
    end
  end

  defp run_teardown(%Suite{teardown: nil}, _), do: :ok

  defp run_teardown(%Suite{teardown: teardown}, setup_result) when is_function(teardown, 1) do
    try do
      teardown.(setup_result)
    rescue
      e ->
        Logger.warning("[Nous.Eval] Teardown failed: #{inspect(e)}")
        :ok
    end
  end

  defp run_sequential(%Suite{} = suite, opts, setup_result) do
    Enum.map(suite.test_cases, fn test_case ->
      execute_test_case(test_case, suite, Keyword.put(opts, :setup_result, setup_result))
    end)
  end

  defp run_parallel(%Suite{} = suite, opts, parallelism, setup_result) do
    opts = Keyword.put(opts, :setup_result, setup_result)

    suite.test_cases
    |> Task.async_stream(
      fn test_case ->
        execute_test_case(test_case, suite, opts)
      end,
      max_concurrency: parallelism,
      timeout: (opts[:timeout] || suite.default_timeout || 60_000) + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> timeout_result("parallel_task", "Task timeout")
    end)
  end

  defp execute_test_case(%TestCase{} = test_case, suite, opts) do
    start_time = System.monotonic_time(:millisecond)

    # Get configuration
    model = Config.get_model(test_case, suite, opts)
    timeout = test_case.timeout || (suite && suite.default_timeout) || opts[:timeout] || 60_000
    retry_count = opts[:retry_failed] || (suite && suite.retry_failed) || 0

    # Build agent configuration
    agent_config = build_agent_config(test_case, suite, opts)

    # Run with retries
    result = run_with_retries(test_case, model, agent_config, timeout, retry_count)

    # Calculate duration
    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    # Build final result
    finalize_result(test_case, result, duration_ms, model)
  end

  defp build_agent_config(test_case, suite, opts) do
    base_config = []

    # Add instructions
    base_config =
      cond do
        test_case.agent_config[:instructions] ->
          Keyword.put(base_config, :instructions, test_case.agent_config[:instructions])

        suite && suite.default_instructions ->
          Keyword.put(base_config, :instructions, suite.default_instructions)

        true ->
          base_config
      end

    # Add tools
    base_config =
      if test_case.tools do
        Keyword.put(base_config, :tools, test_case.tools)
      else
        base_config
      end

    # Merge with test case config and options
    # Handle both keyword lists and maps for agent_config
    test_config = to_keyword_list(test_case.agent_config)
    opts_config = to_keyword_list(opts[:agent_config])

    base_config
    |> Keyword.merge(test_config)
    |> Keyword.merge(opts_config)
  end

  defp to_keyword_list(nil), do: []
  defp to_keyword_list(list) when is_list(list), do: list

  defp to_keyword_list(map) when is_map(map) do
    Enum.map(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  defp run_with_retries(test_case, model, agent_config, timeout, retry_count) do
    run_with_retries(test_case, model, agent_config, timeout, retry_count, 0)
  end

  defp run_with_retries(test_case, model, agent_config, timeout, max_retries, attempt) do
    case run_agent(test_case, model, agent_config, timeout) do
      {:ok, agent_result} ->
        {:ok, agent_result}

      {:error, _reason} = error ->
        if attempt < max_retries do
          Logger.debug(
            "[Nous.Eval] Test case #{test_case.id} failed (attempt #{attempt + 1}), retrying..."
          )

          # Brief delay before retry
          Process.sleep(100 * (attempt + 1))
          run_with_retries(test_case, model, agent_config, timeout, max_retries, attempt + 1)
        else
          error
        end
    end
  end

  defp run_agent(test_case, model, agent_config, timeout) do
    if is_nil(model) do
      {:error, :no_model_configured}
    else
      # Create agent
      agent = Nous.new(model, agent_config)

      # Build run options
      run_opts = [
        deps: test_case.deps,
        timeout: timeout
      ]

      # Run with timeout protection
      task =
        Task.async(fn ->
          Nous.run(agent, test_case.input, run_opts)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        nil ->
          {:error, :timeout}
      end
    end
  end

  defp finalize_result(test_case, {:ok, agent_result}, duration_ms, model) do
    # Extract output
    output = Map.get(agent_result, :output)

    # Run evaluation
    eval_result =
      Evaluator.run(
        test_case.eval_type,
        %{output: output, agent_result: agent_result},
        test_case.expected,
        test_case.eval_config
      )

    # Build metrics
    metrics =
      Metrics.from_agent_result(agent_result, duration_ms)
      |> Metrics.with_cost(model || "unknown")

    if eval_result.passed do
      Result.success(
        test_case_id: test_case.id,
        test_case_name: TestCase.display_name(test_case),
        score: eval_result.score,
        actual_output: output,
        expected_output: test_case.expected,
        evaluation_details: eval_result.details,
        metrics: metrics,
        duration_ms: duration_ms,
        agent_result: agent_result
      )
    else
      Result.failure(
        test_case_id: test_case.id,
        test_case_name: TestCase.display_name(test_case),
        score: eval_result.score,
        actual_output: output,
        expected_output: test_case.expected,
        evaluation_details: Map.put(eval_result.details, :reason, eval_result.reason),
        metrics: metrics,
        duration_ms: duration_ms,
        agent_result: agent_result
      )
    end
  end

  defp finalize_result(test_case, {:error, reason}, duration_ms, _model) do
    Result.error(
      test_case_id: test_case.id,
      test_case_name: TestCase.display_name(test_case),
      error: reason,
      duration_ms: duration_ms
    )
  end

  defp timeout_result(id, message) do
    Result.error(
      test_case_id: id,
      test_case_name: id,
      error: {:timeout, message},
      duration_ms: 0
    )
  end

  defp determine_winner(result_a, result_b) do
    cond do
      result_b.aggregate_score > result_a.aggregate_score + 0.05 -> :b
      result_a.aggregate_score > result_b.aggregate_score + 0.05 -> :a
      true -> :tie
    end
  end
end
