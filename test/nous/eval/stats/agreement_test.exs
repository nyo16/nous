defmodule Nous.Eval.Stats.AgreementTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Stats

  # Golden values: scikit-learn's cohen_kappa_score (see
  # test/fixtures/stats/generate.py, family "agreement").
  @fixture_path Path.expand("../../../fixtures/stats/agreement.json", __DIR__)
  @external_resource @fixture_path
  @golden @fixture_path |> File.read!() |> JSON.decode!()

  @weights %{nil => nil, "linear" => :linear, "quadratic" => :quadratic}

  test "Cohen's κ (unweighted, linear, quadratic) matches scikit-learn" do
    for %{"a" => a, "b" => b, "labels" => labels, "weights" => weights, "kappa" => expected} =
          row <- @golden["kappa"] do
      pairs = Enum.zip(a, b)

      assert {:ok, kappa} =
               Stats.cohen_kappa(pairs, labels: labels, weights: Map.fetch!(@weights, weights))

      case expected do
        nil ->
          assert kappa == nil, row["name"]

        expected ->
          assert is_float(kappa), row["name"]
          assert abs(kappa - expected) <= 1.0e-12, "#{row["name"]}: #{kappa} vs #{expected}"
      end
    end
  end

  test "weighted_kappa/3 is the quadratic κ by default" do
    row = Enum.find(@golden["kappa"], &(&1["name"] == "likert_quadratic"))
    pairs = Enum.zip(row["a"], row["b"])

    assert {:ok, kappa} = Stats.weighted_kappa(pairs, [1, 2, 3, 4, 5])
    assert abs(kappa - row["kappa"]) <= 1.0e-12

    linear = Enum.find(@golden["kappa"], &(&1["name"] == "likert_linear"))
    assert {:ok, k} = Stats.weighted_kappa(pairs, [1, 2, 3, 4, 5], weights: :linear)
    assert abs(k - linear["kappa"]) <= 1.0e-12
  end

  test "without :labels the observed labels are used, sorted" do
    row = Enum.find(@golden["kappa"], &(&1["name"] == "binary"))
    pairs = Enum.zip(row["a"], row["b"])
    assert {:ok, kappa} = Stats.cohen_kappa(pairs)
    assert abs(kappa - row["kappa"]) <= 1.0e-12
  end

  test "bad input is an error, never a crash" do
    assert Stats.cohen_kappa([]) == {:error, :empty}
    assert Stats.cohen_kappa([{"a", "b"}, :oops]) == {:error, :invalid_values}
    assert Stats.cohen_kappa([{"a", "z"}], labels: ["a", "b"]) == {:error, :invalid_values}

    assert Stats.cohen_kappa([{"a", "a"}], labels: ["a", "a"]) ==
             {:error, {:invalid_option, :labels}}

    assert Stats.cohen_kappa([{1, 2}], weights: :quadratic) ==
             {:error, {:invalid_option, :labels}}

    assert Stats.cohen_kappa([{1, 2}], labels: [1, 2], weights: :cubic) ==
             {:error, {:invalid_option, :weights}}

    assert Stats.weighted_kappa([{1, 2}], [1, 2], weights: nil) ==
             {:error, {:invalid_option, :weights}}
  end
end
