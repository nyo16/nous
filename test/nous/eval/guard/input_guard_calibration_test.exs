defmodule Nous.Eval.Guard.InputGuardCalibrationTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Guard
  alias Nous.Eval.Guard.{Case, Recording, Subject}
  alias Nous.Plugins.InputGuard.{Engine, Result}
  alias Nous.Plugins.InputGuard.Strategies.{Pattern, Semantic}

  @moduletag :capture_log

  # The text carries the cosine similarity to the single attack vector [1, 0]
  # as `sim=0.62`; `DOWN` makes the provider fail.
  defmodule Embedding do
    @moduledoc false
    @behaviour Nous.Memory.Embedding

    @impl true
    def embed(text, _opts) do
      if text =~ "DOWN" do
        {:error, :down}
      else
        [s] = Regex.run(~r/sim=([0-9.]+)/, text, capture: :all_but_first)
        s = String.to_float(s)
        {:ok, [s, :math.sqrt(1 - s * s)]}
      end
    end

    @impl true
    def embed_batch(texts, opts), do: {:ok, Enum.map(texts, &elem(embed(&1, opts), 1))}

    @impl true
    def dimension, do: 2
  end

  @semantic {Semantic,
             embedding_provider: Embedding,
             attack_embeddings: [{"attack", [1.0, 0.0]}],
             threshold: 0.85}

  defp guard, do: {:input_guard, %{strategies: [{Pattern, []}, @semantic], aggregation: :any}}

  defp user(id, label, split, sim) do
    {:ok, c} =
      Case.from_map(%{
        "schema" => "nous.guard_case/1",
        "id" => id,
        "surface" => "user_input",
        "label" => label,
        "split" => split,
        "input" => %{"text" => "case #{id} sim=#{sim}"},
        "provenance" => %{"source" => "t", "license" => "MIT"}
      })

    c
  end

  test "Semantic records the top similarity on safe verdicts too" do
    assert {:ok,
            %Result{
              severity: :safe,
              metadata: %{top_similarity: sim, top_match: "attack", matches: []}
            }} =
             Semantic.check("x sim=0.5", elem(@semantic, 1), nil)

    assert_in_delta sim, 0.5, 1.0e-9
  end

  test "Engine.aggregate/3 is the run's aggregation" do
    safe = %Result{severity: :safe}
    sus = %Result{severity: :suspicious}
    blocked = %Result{severity: :blocked}

    assert Engine.aggregate([safe, sus], 2, %{aggregation: :any}) == sus

    assert Engine.aggregate([safe, sus, blocked], 3, %{aggregation: :majority}).severity ==
             :blocked

    assert Engine.aggregate([sus], 2, %{aggregation: :all}).severity == :safe
    assert Engine.aggregate([], 2, %{}).severity == :safe
  end

  test "the Semantic threshold is swept on tune and patched" do
    cases =
      for(
        {s, i} <- Enum.with_index([0.6, 0.65, 0.7, 0.9]),
        do: user("tb#{i}", "block", "tune", s)
      ) ++
        for(
          {s, i} <- Enum.with_index([0.1, 0.2, 0.3, 0.4]),
          do: user("ta#{i}", "allow", "tune", s)
        ) ++
        for({s, i} <- Enum.with_index([0.62, 0.95]), do: user("hb#{i}", "block", "holdout", s)) ++
        for({s, i} <- Enum.with_index([0.15, 0.35]), do: user("ha#{i}", "allow", "holdout", s))

    {:ok, report} = Guard.calibrate(cases, guard: guard())

    assert [{{:threshold, 1}, 0.85, threshold}] = report.changes
    assert threshold > 0.4 and threshold <= 0.6
    assert report.patch.data == %{strategies: %{1 => [threshold: threshold]}}
    assert report.splits.holdout.baseline.far_eb.successes == 1
    assert report.splits.holdout.tuned.far_eb.successes == 0
    assert report.splits.holdout.tuned.threshold_free.roc_auc == 1.0

    {:input_guard, patched} = Guard.apply_patch(guard(), report.patch.data)
    assert [{Pattern, []}, {Semantic, opts}] = patched.strategies
    assert opts[:threshold] == threshold
  end

  test "a dropped strategy is an error that fails closed" do
    {:ok, recording} = Guard.record([user("down", "allow", "holdout", "DOWN")], guard())
    {:ok, subject} = Subject.new(guard(), :user_input)
    assert [%{verdict: :deny, error?: true}] = Recording.outcomes(recording, subject)

    {:ok, open} =
      Subject.new(
        {:input_guard, %{strategies: [{Pattern, []}, @semantic], fail_closed: false}},
        :user_input
      )

    assert [%{verdict: :allow, error?: true}] = Recording.outcomes(recording, open)
  end

  test "an InputGuard guards user input only" do
    assert {:error, message} = Subject.new(guard(), :tool_call)
    assert message =~ ":user_input only"
  end
end
