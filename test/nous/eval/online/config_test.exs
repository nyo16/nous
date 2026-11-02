Code.require_file("online_helpers.exs", __DIR__)

defmodule Nous.Eval.Online.ConfigTest do
  # async: false - a successful start registers the global handler.
  use ExUnit.Case, async: false

  import Nous.Eval.OnlineHelpers

  alias Nous.Eval.Online

  @moduletag :tmp_dir

  defmodule NoRetentionStore do
    @moduledoc false
    def init(_opts), do: {:ok, nil}
    def put_run(state, _run), do: {:ok, state}
  end

  defmodule NotARedactor do
    @moduledoc false
    def scrub(content), do: content
  end

  defmodule ModelScorer do
    @moduledoc false
    # Model-graded without naming its model: its spend cannot be priced.
    @behaviour Nous.Eval.Scorer
    def id, do: "model_scorer"
    def kind, do: :model_graded
    def init(opts), do: {:ok, opts}
    def score(_input, _config), do: {:skip, "never called"}
  end

  defp refused(opts) do
    assert {:error, {:invalid_config, reason}} = Online.start_link(opts)
    refute handler_attached?()
    assert Process.whereis(Online) == nil
    reason
  end

  # F1
  test "no redactor, or an invalid one, refuses to start and attaches nothing",
       %{tmp_dir: root} do
    assert :redact_required = refused(base_opts(root) |> Keyword.delete(:redact))

    for invalid <- [
          nil,
          :none,
          fn _a, _b -> :ok end,
          "MyApp.Redactor",
          NotARedactor,
          Nous.Eval.NoSuchRedactor
        ] do
      reason = refused(base_opts(root, redact: invalid))
      assert reason in [:redact_required, {:invalid_redact, invalid}]
    end
  end

  test "sample rate, store and retention are required", %{tmp_dir: root} do
    assert :sample_rate_required = refused(base_opts(root) |> Keyword.delete(:sample_rate))
    assert :store_required = refused(base_opts(root) |> Keyword.delete(:store))
    assert :retention_required = refused(base_opts(root) |> Keyword.delete(:retention))

    for rate <- [-0.1, 1.5, "0.1", nil] do
      reason = refused(base_opts(root, sample_rate: rate))
      assert reason in [:sample_rate_required, {:invalid_rate, :sample_rate, rate}]
    end

    assert {:invalid_retention, _} = refused(base_opts(root, retention: [max_age: {0, :day}]))

    assert {:invalid_retention, _} =
             refused(base_opts(root, retention: [max_age: {1, :fortnight}]))
  end

  test "a finite retention needs a store that can delete", %{tmp_dir: root} do
    assert {:store_lacks_retention, NoRetentionStore} =
             refused(base_opts(root, store: {NoRetentionStore, []}))

    assert {:ok, pid} =
             Online.start_link(
               base_opts(root, store: {NoRetentionStore, []}, retention: :infinity)
             )

    Supervisor.stop(pid)
    refute handler_attached?()
  end

  # F15 (config)
  test "a rule may not sample above the capture rate", %{tmp_dir: root} do
    rule = [
      name: "r",
      sample_rate: 0.5,
      scorers: [Nous.Eval.Scorers.MaxLatency |> then(&{&1, max_ms: 1})]
    ]

    assert {:rule_rate_exceeds_sample_rate, "r"} =
             refused(base_opts(root, sample_rate: 0.1, rules: [rule]))
  end

  # F16
  test "a content scorer under :drop_content refuses to start", %{tmp_dir: root} do
    for scorer <- [
          {Nous.Eval.Scorers.Contains, values: ["x"]},
          {Nous.Eval.Scorers.Judge, judge: "openai:gpt-4o-mini"}
        ] do
      assert {:content_scorer_under_drop_content, "r", _id} =
               refused(
                 base_opts(root,
                   rules: [[name: "r", scorers: [scorer]]],
                   budget: [max_cost: 1.0, per: :hour]
                 )
               )
    end
  end

  test "a model-calling scorer needs a budget and a priced, named model", %{tmp_dir: root} do
    judge = [name: "q", scorers: [{Nous.Eval.Scorers.Judge, judge: "openai:gpt-4o-mini"}]]
    redact = &Function.identity/1

    assert :budget_required = refused(base_opts(root, redact: redact, rules: [judge]))

    # F12
    unpriced = [name: "q", scorers: [{Nous.Eval.Scorers.Judge, judge: "openai:no-such-model"}]]

    assert {:unknown_price, "openai:no-such-model"} =
             refused(
               base_opts(root,
                 redact: redact,
                 rules: [unpriced],
                 budget: [max_cost: 1.0, per: :hour]
               )
             )

    assert {:unpriced_scorer, "q", "model_scorer"} =
             refused(
               base_opts(root,
                 redact: redact,
                 rules: [[name: "q", scorers: [ModelScorer]]],
                 budget: [max_cost: 1.0, per: :hour]
               )
             )

    # A budget smaller than one reserved call could never run the judge.
    assert {:reserve_exceeds_budget, "q", "judge", _usd} =
             refused(
               base_opts(root,
                 redact: redact,
                 rules: [judge],
                 budget: [max_cost: 0.0001, per: :hour]
               )
             )

    assert {:invalid_budget, {:per, :week}} =
             refused(
               base_opts(root,
                 redact: redact,
                 rules: [judge],
                 budget: [max_cost: 1.0, per: :week]
               )
             )
  end

  test "unknown options and invalid bounds refuse to start", %{tmp_dir: root} do
    assert {:unknown_options, [:sampel_rate]} = refused(base_opts(root, sampel_rate: 0.1))
    assert {:invalid_option, :max_queue, 0} = refused(base_opts(root, max_queue: 0))
    assert {:invalid_option, :instance, "Prod/1"} = refused(base_opts(root, instance: "Prod/1"))
    assert {:invalid_option, :sample_by, :user} = refused(base_opts(root, sample_by: :user))

    assert {:duplicate_rule_names, ["r"]} =
             refused(
               base_opts(root,
                 rules: [
                   [name: "r", scorers: [Nous.Eval.Scorers.MaxLatency |> then(&{&1, max_ms: 1})]],
                   [name: "r", scorers: [Nous.Eval.Scorers.MaxLatency |> then(&{&1, max_ms: 1})]]
                 ]
               )
             )

    assert {:scorer_init_failed, "r", Nous.Eval.Scorers.MaxLatency, _} =
             refused(
               base_opts(root,
                 rules: [[name: "r", scorers: [{Nous.Eval.Scorers.MaxLatency, bogus: 1}]]]
               )
             )
  end

  test "one instance per name", %{tmp_dir: root} do
    start_online!(base_opts(root))
    assert {:error, {:already_started, _}} = Online.start_link(base_opts(root))
  end
end
