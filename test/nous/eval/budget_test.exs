defmodule Nous.Eval.BudgetTest do
  # async: true - every ledger attaches its own handler id and charges only
  # the trace ids it tracks, so concurrent tests never see each other's
  # events.
  use ExUnit.Case, async: true

  alias Nous.Eval.Budget
  alias Nous.Usage

  @model_stop [:nous, :agent, :model, :stop]

  defp start(limits) do
    {:ok, limits} = Budget.limits(limits)
    budget = Budget.start(limits)
    on_exit(fn -> :telemetry.detach(budget.handler_id) end)
    budget
  end

  defp trace_id, do: "trace-" <> Integer.to_string(System.unique_integer([:positive]))

  defp model_stop(trace_id, tokens, meta \\ %{}) do
    :telemetry.execute(
      @model_stop,
      %{input_tokens: tokens - 2, output_tokens: 2, total_tokens: tokens},
      Map.merge(
        %{
          trace_id: trace_id,
          model_provider: :openai,
          model_name: "gpt-4o-mini",
          active_model_provider: :openai,
          active_model_name: "gpt-4o-mini"
        },
        meta
      )
    )
  end

  test "limits are validated" do
    assert {:ok, %{max_tokens: nil, max_cost: nil, max_samples: nil}} = Budget.limits(nil)
    assert {:ok, %{max_cost: 0.5}} = Budget.limits(max_cost: 0.5)

    assert Budget.limits(max_tokens: 0) ==
             {:error, {:invalid_option, :budget, [max_tokens: 0]}}

    assert Budget.limits(max_cost: -1) == {:error, {:invalid_option, :budget, [max_cost: -1]}}
    assert Budget.limits(max_usd: 1) == {:error, {:invalid_option, :budget, [:max_usd]}}

    assert Budget.limits(%{max_tokens: 1}) ==
             {:error, {:invalid_option, :budget, %{max_tokens: 1}}}
  end

  test "pre-flight refuses an unpriced model only under a cost limit" do
    {:ok, cost} = Budget.limits(max_cost: 1.0)
    {:ok, tokens} = Budget.limits(max_tokens: 100)

    assert Budget.preflight(cost, [Nous.Model.parse("openai:gpt-4o-mini"), "ollama:llama3.3"]) ==
             :ok

    assert Budget.preflight(cost, ["openai:gpt-4o-mini", "openai:no-such-model-xyz"]) ==
             {:error, {:unknown_price, "openai:no-such-model-xyz"}}

    assert Budget.preflight(tokens, ["openai:no-such-model-xyz"]) == :ok
  end

  test "charges the model stops of tracked traces only, priced at the answering model" do
    budget = start([])
    tracked = trace_id()
    :ok = Budget.track(budget, tracked)

    model_stop(tracked, 1_000)
    model_stop(trace_id(), 5_000)
    # A fallback answered: priced at the active model, not the configured one.
    model_stop(tracked, 1_000, %{model_name: "no-such-model-xyz"})

    usage = %Usage{input_tokens: 1_996, output_tokens: 4, total_tokens: 2_000}
    {:ok, %{total: expected}} = Usage.cost(usage, "openai:gpt-4o-mini")

    report = Budget.report(budget)
    assert report.spent.tokens == 2_000
    assert_in_delta report.spent.cost, expected, 1.0e-12
    assert report.spent.unpriced_requests == 0
    assert report.exhausted == nil
  end

  test "the ledger is exact under parallel emitters" do
    budget = start([])
    ids = for _ <- 1..20, do: trace_id()
    Enum.each(ids, &Budget.track(budget, &1))

    ids
    |> Task.async_stream(fn id -> for _ <- 1..50, do: model_stop(id, 7) end, max_concurrency: 20)
    |> Stream.run()

    assert Budget.report(budget).spent.tokens == 20 * 50 * 7
  end

  test "a token limit exhausts the budget and cancels at the next step" do
    budget = start(max_tokens: 100)
    id = trace_id()
    :ok = Budget.track(budget, id)
    check = Budget.cancellation_check(budget)

    model_stop(id, 60)
    assert check.() == :ok
    assert Budget.admit(budget) == :ok

    model_stop(id, 40)
    assert Budget.exhausted(budget) == :max_tokens
    assert catch_throw(check.()) == {:cancelled, :budget_exhausted}
    assert Budget.admit(budget) == :exhausted
  end

  test "a cost limit exhausts on spend, and on a request it cannot price" do
    budget = start(max_cost: 0.000_001)
    id = trace_id()
    :ok = Budget.track(budget, id)

    model_stop(id, 10_000)
    assert Budget.exhausted(budget) == :max_cost

    unpriced = start(max_cost: 10.0)
    other = trace_id()
    :ok = Budget.track(unpriced, other)
    model_stop(other, 10, %{active_model_name: "no-such-model-xyz"})

    assert Budget.exhausted(unpriced) == :unknown_price
    assert Budget.spend_exhausted?(unpriced)
    assert Budget.report(unpriced).spent.cost == nil
  end

  test "without a cost limit an unpriced request is counted, not fatal" do
    budget = start([])
    id = trace_id()
    :ok = Budget.track(budget, id)

    model_stop(id, 10, %{active_model_name: "no-such-model-xyz"})

    assert Budget.exhausted(budget) == nil

    assert Budget.report(budget).spent == %{
             tokens: 10,
             cost: nil,
             samples: 0,
             unpriced_requests: 1
           }
  end

  test "max_samples refuses admission without cancelling admitted work" do
    budget = start(max_samples: 2)
    check = Budget.cancellation_check(budget)

    assert Budget.admit(budget) == :ok
    assert Budget.admit(budget) == :ok
    assert Budget.admit(budget) == :exhausted
    assert Budget.exhausted(budget) == :max_samples
    assert check.() == :ok
    assert Budget.report(budget).spent.samples == 2
  end

  test "a spend limit reached after max_samples still stops spending" do
    budget = start(max_samples: 1, max_cost: 0.000_001)
    id = trace_id()
    :ok = Budget.track(budget, id)
    check = Budget.cancellation_check(budget)

    assert Budget.admit(budget) == :ok
    assert Budget.admit(budget) == :exhausted
    assert Budget.exhausted(budget) == :max_samples
    refute Budget.spend_exhausted?(budget)

    # The admitted sample is still running and overspends.
    model_stop(id, 10_000)

    assert Budget.spend_exhausted?(budget)
    assert catch_throw(check.()) == {:cancelled, :budget_exhausted}
    assert Budget.exhausted(budget) == :max_cost
    assert Budget.report(budget).exhausted == :max_cost
  end

  test "charge/3 adds usage and enforces the limits" do
    budget = start(max_tokens: 50)

    Budget.charge(
      budget,
      %Usage{input_tokens: 40, output_tokens: 10, total_tokens: 50},
      "openai:gpt-4o-mini"
    )

    assert Budget.report(budget).spent.tokens == 50
    assert Budget.exhausted(budget) == :max_tokens
  end

  test "stop/1 detaches the handler" do
    {:ok, limits} = Budget.limits([])
    budget = Budget.start(limits)
    assert Enum.any?(:telemetry.list_handlers(@model_stop), &(&1.id == budget.handler_id))

    :ok = Budget.stop(budget)
    refute Enum.any?(:telemetry.list_handlers(@model_stop), &(&1.id == budget.handler_id))
  end
end
