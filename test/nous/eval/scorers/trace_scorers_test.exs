defmodule Nous.Eval.Scorers.TraceScorersTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Score, ScorerError}
  alias Nous.Eval.Scorers
  alias Nous.Eval.TraceBuilder, as: B

  @root "aaaaaaaaaaaaaaaa"
  @child "bbbbbbbbbbbbbbbb"

  defp score(module, opts, trace, input_opts \\ []) do
    {:ok, config} = module.init(opts)
    module.score(B.input(trace, input_opts), config)
  end

  defp truncated(trace), do: %{trace | truncated?: true}

  describe "ToolArgs" do
    setup do
      trace =
        B.trajectory([
          {"search", %{"q" => "shoes", "page" => 1}},
          {"search", %{"q" => "boots", "page" => 1}},
          {"search", %{"q" => "bad"}, outcome: :invalid_arguments}
        ])

      %{trace: trace}
    end

    test "occurrence selects the calls that must match", %{trace: trace} do
      shoes = %{"q" => "shoes"}

      assert {:ok,
              %Score{
                name: "tool_args.search",
                passed?: false,
                details: %{mismatches: [%{paths: ["q"]}]}
              }} =
               score(Scorers.ToolArgs, [tool: "search", args: shoes], trace)

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.ToolArgs, [tool: "search", args: shoes, occurrence: :first], trace)

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.ToolArgs, [tool: "search", args: shoes, occurrence: "any"], trace)

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.ToolArgs, [tool: "search", args: shoes, occurrence: :last], trace)

      assert {:ok, %Score{passed?: true}} =
               score(
                 Scorers.ToolArgs,
                 [tool: "search", args: %{q: "boots"}, occurrence: 2],
                 trace
               )

      assert {:ok, %Score{passed?: false, reason: "fewer calls than occurrence 3"}} =
               score(Scorers.ToolArgs, [tool: "search", args: shoes, occurrence: 3], trace)

      assert {:ok, %Score{passed?: true}} =
               score(
                 Scorers.ToolArgs,
                 [tool: "search", args: %{"q" => "bad"}, include: :all, occurrence: :last],
                 trace
               )
    end

    test "an uncalled tool fails, or errors on a truncated trace", %{trace: trace} do
      assert {:ok, %Score{passed?: false, reason: "tool_not_called"}} =
               score(Scorers.ToolArgs, [tool: "refund", args: %{}], trace)

      assert {:error, %ScorerError{kind: :missing_trace}} =
               score(Scorers.ToolArgs, [tool: "refund", args: %{}], truncated(trace))

      assert {:ok, %Score{passed?: true}} =
               score(
                 Scorers.ToolArgs,
                 [tool: "search", args: %{"q" => "shoes"}, occurrence: :first],
                 truncated(trace)
               )

      assert {:error, %ScorerError{kind: :missing_trace}} =
               score(Scorers.ToolArgs, [tool: "search", args: %{"page" => 1}], truncated(trace))
    end

    test "a false argument value is compared, not skipped" do
      trace = B.trajectory([{"set", %{"enabled" => false}}])

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.ToolArgs, [tool: "set", args: %{enabled: false}], trace)

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.ToolArgs, [tool: "set", args: %{enabled: nil}], trace)
    end

    test "rejects bad options" do
      assert {:error, _} = Scorers.ToolArgs.init(tool: "x")
      assert {:error, _} = Scorers.ToolArgs.init(tool: "x", args: %{}, occurrence: 0)
      assert {:error, _} = Scorers.ToolArgs.init(tool: "x", args: %{}, match: :ignore)
    end
  end

  describe "ToolCount" do
    setup do
      trace =
        B.trajectory([
          {"search", %{}},
          {"search", %{}, outcome: :timeout},
          {"lookup", %{}}
        ])

      %{trace: trace}
    end

    test "counts every attempt by default, per tool or in total", %{trace: trace} do
      assert {:ok, %Score{name: "tool_count.search", passed?: true, details: %{count: 2}}} =
               score(Scorers.ToolCount, [tool: "search", max: 2], trace)

      assert {:ok, %Score{name: "tool_count", passed?: false, reason: "count 3 above 2"}} =
               score(Scorers.ToolCount, [max: 2], trace)

      assert {:ok, %Score{details: %{count: 1}}} =
               score(Scorers.ToolCount, [tool: "search", exact: 1, include: [:executed]], trace)

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.ToolCount, [tool: "lookup", min: 2], trace)
    end

    test "a truncated trace only proves lower bounds", %{trace: trace} do
      t = truncated(trace)
      assert {:ok, %Score{passed?: true}} = score(Scorers.ToolCount, [min: 2], t)
      assert {:ok, %Score{passed?: false}} = score(Scorers.ToolCount, [max: 1], t)
      assert {:error, %ScorerError{kind: :missing_trace}} = score(Scorers.ToolCount, [max: 5], t)
      assert {:error, %ScorerError{kind: :missing_trace}} = score(Scorers.ToolCount, [min: 4], t)
    end

    test "rejects missing or contradictory bounds" do
      assert {:error, _} = Scorers.ToolCount.init([])
      assert {:error, _} = Scorers.ToolCount.init(exact: 1, max: 2)
      assert {:error, _} = Scorers.ToolCount.init(min: 3, max: 2)
    end
  end

  describe "NoToolErrors" do
    test "fails on runner-level failures and stop errors, not on denials" do
      clean = B.trajectory([{"a", %{}}, {"b", %{}, outcome: :hook_denied}])

      assert {:ok, %Score{name: "no_tool_errors", passed?: true}} =
               score(Scorers.NoToolErrors, [], clean)

      broken = B.trajectory([{"a", %{}, outcome: :crashed}, {"b", %{}, error: "disk full"}])

      assert {:ok,
              %Score{
                passed?: false,
                details: %{errors: [%{outcome: :crashed}, %{name: "b", outcome: :executed}]}
              }} =
               score(Scorers.NoToolErrors, [], broken)

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.NoToolErrors, [outcomes: ["hook_denied"]], clean)

      assert {:error, %ScorerError{kind: :missing_trace}} =
               score(Scorers.NoToolErrors, [], truncated(clean))
    end
  end

  describe "GuardVerdict" do
    setup do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.decision_guard_verdict(@root, :user_input, :allow)
        |> B.decision_guard_verdict(@root, :tool_call, :allow)
        |> B.decision_guard_verdict(@root, :tool_call, :deny)
        |> B.input_guard_verdict(@root, :blocked, :block)
        |> B.run_stop(@root)
        |> B.build()

      %{trace: trace}
    end

    test "matches the expected verdict per guard and surface", %{trace: trace} do
      assert {:ok, %Score{name: "guard_verdict.decision_guard.tool_call", passed?: true}} =
               score(
                 Scorers.GuardVerdict,
                 [guard: :decision_guard, surface: :tool_call, expected: :deny],
                 trace
               )

      # :allow defaults to :all - one deny on the surface fails it.
      assert {:ok, %Score{passed?: false, details: %{verdicts: [:allow, :deny]}}} =
               score(
                 Scorers.GuardVerdict,
                 [guard: "decision_guard", surface: "tool_call", expected: "allow"],
                 trace
               )

      assert {:ok, %Score{passed?: true}} =
               score(
                 Scorers.GuardVerdict,
                 [guard: :decision_guard, surface: :user_input, expected: :allow],
                 trace
               )

      assert {:ok, %Score{name: "guard_verdict.input_guard", passed?: true}} =
               score(Scorers.GuardVerdict, [guard: :input_guard, expected: :blocked], trace)

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.GuardVerdict, [guard: :input_guard, expected: :safe], trace)
    end

    test "a guard that never ran skips; loop guard absence is a verdict", %{trace: trace} do
      assert {:skip, "guard_not_evaluated"} =
               score(
                 Scorers.GuardVerdict,
                 [guard: :decision_guard, surface: :model_output, expected: :allow],
                 trace
               )

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.GuardVerdict, [guard: :loop_guard, expected: :none], trace)

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.GuardVerdict, [guard: :loop_guard, expected: :advisory], trace)

      assert {:error, %ScorerError{kind: :missing_trace}} =
               score(
                 Scorers.GuardVerdict,
                 [guard: :loop_guard, expected: :none],
                 truncated(trace)
               )

      assert {:ok, %Score{passed?: true}} =
               score(
                 Scorers.GuardVerdict,
                 [guard: :decision_guard, expected: :deny],
                 truncated(trace)
               )
    end

    test "rejects values outside the guard's vocabulary" do
      assert {:error, _} = Scorers.GuardVerdict.init(guard: :input_guard, expected: :deny)

      assert {:error, _} =
               Scorers.GuardVerdict.init(
                 guard: :input_guard,
                 expected: :safe,
                 surface: :tool_call
               )

      assert {:error, _} = Scorers.GuardVerdict.init(guard: "firewall", expected: "deny")
    end
  end

  describe "OutputRetries" do
    test "bounds structured output retries" do
      trace = B.new() |> B.run_start(@root) |> B.output_retry(@root, 1) |> B.build()

      assert {:ok, %Score{passed?: false, details: %{retries: 1}}} =
               score(Scorers.OutputRetries, [], trace)

      assert {:ok, %Score{passed?: true}} = score(Scorers.OutputRetries, [max: 1], trace)

      assert {:error, %ScorerError{kind: :missing_trace}} =
               score(Scorers.OutputRetries, [max: 1], truncated(trace))
    end
  end

  describe "MaxCost" do
    defp priced_trace(child_model) do
      B.new()
      |> B.run_start(@root)
      |> B.model_start(@root)
      |> B.model_stop(@root, usage: %{input_tokens: 1_000_000, output_tokens: 0})
      |> B.run_start(@child, parent: @root)
      |> B.model_start(@child)
      |> B.model_stop(@child,
        model_provider: :anthropic,
        model_name: child_model,
        usage: %{input_tokens: 0, output_tokens: 1_000_000}
      )
      |> B.build()
    end

    test "prices each request at the model that answered it, across the tree" do
      trace = priced_trace("claude-haiku-4-5")

      # gpt-4o input $2.50/M + claude-haiku-4-5 output $5.00/M
      assert {:ok, %Score{passed?: true, details: %{cost_usd: cost, by_model: by_model}}} =
               score(Scorers.MaxCost, [max_usd: 8.0], trace)

      assert_in_delta cost, 7.5, 1.0e-9
      assert map_size(by_model) == 2
      assert {:ok, %Score{passed?: false}} = score(Scorers.MaxCost, [max_usd: 7.0], trace)
    end

    test "an unknown price is an error, never a pass" do
      assert {:error, %ScorerError{kind: :invalid_config, reason: reason}} =
               score(Scorers.MaxCost, [max_usd: 100.0], priced_trace("claude-from-the-future"))

      assert reason =~ "no known price"
      assert {:error, msg} = Scorers.MaxCost.init(max_usd: 1.0, model: "openai:no-such-model")
      assert msg =~ "no known price"
    end

    test "prices summed usage with an explicit model" do
      usage = %Nous.Usage{input_tokens: 1_000_000, total_tokens: 1_000_000}

      assert {:ok, %Score{details: %{cost_usd: 2.5}}} =
               score(
                 Scorers.MaxCost,
                 [max_usd: 3.0, model: "openai:gpt-4o"],
                 B.new() |> B.build(),
                 usage: usage
               )
    end

    test "missing requests make the cost unprovable" do
      assert {:error, %ScorerError{kind: :missing_trace}} =
               score(
                 Scorers.MaxCost,
                 [max_usd: 100.0],
                 truncated(priced_trace("claude-haiku-4-5"))
               )

      assert {:error, %ScorerError{kind: :missing_trace}} =
               score(Scorers.MaxCost, [max_usd: 1.0], B.new() |> B.build(),
                 usage: %Nous.Usage{total_tokens: 5}
               )
    end
  end

  describe "MaxLatency and MaxTokens" do
    test "compare against the sample's duration and usage" do
      empty = B.new() |> B.build()

      assert {:ok, %Score{name: "max_latency", passed?: true}} =
               score(Scorers.MaxLatency, [max_ms: 1_000], empty, duration_ms: 1_000)

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.MaxLatency, [max_ms: 1_000], empty, duration_ms: 1_001)

      usage = %Nous.Usage{input_tokens: 900, output_tokens: 200, total_tokens: 1_100}

      assert {:ok, %Score{name: "max_tokens", passed?: false}} =
               score(Scorers.MaxTokens, [max: 1_000], empty, usage: usage)

      assert {:ok, %Score{passed?: true, details: %{tokens: 200}}} =
               score(Scorers.MaxTokens, [max: 1_000, field: "output"], empty, usage: usage)

      assert {:error, _} = Scorers.MaxLatency.init([])
      assert {:error, _} = Scorers.MaxTokens.init(max: 10, field: "cached")
    end
  end

  test "trace scorers error rather than pass without a trace" do
    input = %{B.input(B.new() |> B.build()) | trace: nil}

    for {module, opts} <- [
          {Scorers.Trajectory, [expected: [%{name: "a"}]]},
          {Scorers.ToolArgs, [tool: "a", args: %{}]},
          {Scorers.ToolCount, [max: 1]},
          {Scorers.NoToolErrors, []},
          {Scorers.GuardVerdict, [guard: :loop_guard, expected: :none]},
          {Scorers.OutputRetries, []},
          {Scorers.MaxCost, [max_usd: 1.0]}
        ] do
      {:ok, config} = module.init(opts)

      assert {:error, %ScorerError{kind: :missing_trace}} = module.score(input, config),
             inspect(module)
    end
  end
end
