defmodule Nous.Eval.Stats.BootstrapTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Stats
  alias Nous.Eval.Stats.Bootstrap

  doctest Bootstrap

  # 40 clusters of 1–4 paired cases. Built from a fixed :exsss stream so the
  # data, like the bootstrap, is identical on every run and platform.
  defp clusters(count \\ 40, seed \\ 7) do
    {clusters, _} =
      Enum.map_reduce(1..count, :rand.seed_s(:exsss, seed), fn _, st ->
        {size, st} = :rand.uniform_s(4, st)
        {shift, st} = :rand.uniform_s(st)

        Enum.map_reduce(1..size, st, fn _, st ->
          {u1, st} = :rand.uniform_s(st)
          {u2, st} = :rand.uniform_s(st)
          base = Float.round(0.5 * shift + 0.5 * u1, 4)
          {{Float.round(min(base + 0.2 * u2, 1.0), 4), base}, st}
        end)
      end)

    clusters
  end

  describe "determinism" do
    test "the same seed reproduces the result exactly" do
      data = clusters()
      opts = [seed: 2026, resamples: 2_000, keep_replicates: true]
      assert {:ok, r1} = Bootstrap.paired_cluster(data, opts)
      assert {:ok, r2} = Bootstrap.paired_cluster(data, opts)
      assert r1 == r2
      assert length(r1.replicates) == 2_000
    end

    test "a different seed gives a different replicate stream" do
      data = clusters()
      {:ok, r1} = Bootstrap.paired_cluster(data, seed: 1, resamples: 500, keep_replicates: true)
      {:ok, r2} = Bootstrap.paired_cluster(data, seed: 2, resamples: 500, keep_replicates: true)
      refute r1.replicates == r2.replicates
      assert r1.estimate == r2.estimate
    end

    test "parallel streams give results identical to serial for the same seed" do
      data = clusters()

      for streams <- [1, 3, 8], resamples <- [999, 1_000] do
        base = [seed: {1, 2, 3}, resamples: resamples, streams: streams, keep_replicates: true]
        {:ok, serial} = Bootstrap.paired_cluster(data, base)
        {:ok, parallel} = Bootstrap.paired_cluster(data, [max_concurrency: 4] ++ base)
        assert serial == parallel
      end
    end

    test "parallel == serial also for a custom statistic" do
      data = clusters()
      stat = fn items -> items |> Enum.map(fn {c, b} -> c - b end) |> Enum.max() end
      base = [seed: 99, resamples: 400, statistic: stat, keep_replicates: true]

      assert Bootstrap.paired_cluster(data, base) ==
               Bootstrap.paired_cluster(data, [max_concurrency: 8] ++ base)
    end

    test "streams start from :rand.jump/1-advanced states of the seeded :exsss state" do
      # With one cluster draw per replicate the draws are the raw uniform
      # stream, so the replicate values expose which state each stream used.
      data = [[{1.0, 0.0}], [{2.0, 0.0}], [{3.0, 0.0}], [{4.0, 0.0}], [{5.0, 0.0}]]

      {:ok, r} =
        Bootstrap.paired_cluster(data, seed: 5, resamples: 4, streams: 2, keep_replicates: true)

      s0 = :rand.seed_s(:exsss, 5)
      s1 = :rand.jump(s0)

      expected_stream = fn state ->
        {means, _} =
          Enum.map_reduce(1..2, state, fn _, st ->
            {draws, st} = Enum.map_reduce(1..5, st, fn _, s -> :rand.uniform_s(5, s) end)
            {Enum.sum(draws) / 5, st}
          end)

        means
      end

      assert r.replicates == expected_stream.(s0) ++ expected_stream.(s1)
    end

    test "pinned output guards the reproducibility contract across OTP upgrades" do
      data = [[{1.0, 0.0}, {0.0, 0.0}], [{1.0, 1.0}], [{0.5, 0.0}], [{1.0, 0.5}, {0.0, 0.5}]]

      {:ok, r} =
        Bootstrap.paired_cluster(data, seed: 42, resamples: 8, streams: 2, keep_replicates: true)

      assert r.replicates == pinned_replicates()
    end
  end

  describe "statistics" do
    test "the percentile CI is the type-7 quantile of the replicates" do
      {:ok, r} =
        Bootstrap.paired_cluster(clusters(),
          seed: 11,
          resamples: 1_001,
          keep_replicates: true,
          confidence: 0.9
        )

      {:ok, [lo, hi]} = Stats.quantiles(r.replicates, [0.05, 0.95])
      assert r.ci == {lo, hi}
      {:ok, %{sd: sd}} = Stats.describe(r.replicates)
      assert_in_delta r.se, sd, 1.0e-12
      assert r.p_le_0 == Enum.count(r.replicates, &(&1 <= 0)) / 1_001
    end

    test "the estimate is the paired mean difference over all cases" do
      data = clusters()
      {:ok, r} = Bootstrap.paired_cluster(data, seed: 3, resamples: 10)
      pairs = List.flatten(data)
      expected = Enum.sum(Enum.map(pairs, fn {c, b} -> c - b end)) / length(pairs)
      assert_in_delta r.estimate, expected, 1.0e-12
    end

    test "resampling clusters tracks the cluster-robust SE, not the per-item SE" do
      # Items inside a cluster share most of their difference, so the cluster
      # is the effective unit.
      data =
        for {cluster, i} <- Enum.with_index(clusters(80, 21)) do
          offset = if rem(i, 2) == 0, do: 0.15, else: -0.15
          Enum.map(cluster, fn {c, b} -> {c + offset, b} end)
        end

      {:ok, r} = Bootstrap.paired_cluster(data, seed: 8, resamples: 4_000)
      diffs = Enum.map(data, fn cluster -> Enum.map(cluster, fn {c, b} -> c - b end) end)
      {:ok, %{se: clustered}} = Stats.clustered_se(diffs)
      {:ok, %{se: naive}} = diffs |> List.flatten() |> Stats.describe()

      assert abs(r.se - clustered) / clustered < 0.1
      assert naive < 0.8 * r.se
    end

    test "a custom statistic sees the items of the drawn clusters" do
      data = [[{1, 1}, {1, 1}], [{0, 0}, {0, 0}], [{1, 0}, {1, 0}]]
      stat = fn items -> length(items) end
      {:ok, r} = Bootstrap.paired_cluster(data, seed: 1, resamples: 50, statistic: stat)
      assert r.estimate == 6.0
      assert r.ci == {6.0, 6.0}
    end
  end

  describe "errors" do
    test "seed is required and validated" do
      assert Bootstrap.paired_cluster(clusters(), resamples: 10) == {:error, :seed_required}
      assert Bootstrap.paired_cluster(clusters(), seed: "x") == {:error, {:invalid_option, :seed}}
    end

    test "cluster and option validation" do
      assert Bootstrap.paired_cluster([[{1, 0}]], seed: 1) == {:error, :insufficient_clusters}
      assert Bootstrap.paired_cluster([[{1, 0}], []], seed: 1) == {:error, :empty_cluster}
      assert Bootstrap.paired_cluster([[{1, 0}], [{:a, 0}]], seed: 1) == {:error, :invalid_values}

      assert Bootstrap.paired_cluster([[{1, 0}], [{1, 0}]], seed: 1, resamples: 0) ==
               {:error, {:invalid_option, :resamples}}

      assert Bootstrap.paired_cluster([[{1, 0}], [{1, 0}]], seed: 1, statistic: :median) ==
               {:error, {:invalid_option, :statistic}}
    end

    test "a statistic returning a non-number is reported" do
      assert Bootstrap.paired_cluster([[1], [2]], seed: 1, statistic: fn _ -> :nope end) ==
               {:error, {:invalid_statistic, :nope}}
    end
  end

  # Recorded once on OTP 29 / Elixir 1.20; :exsss uniform_s integer draws are
  # specified to be platform-independent, so this must never change.
  defp pinned_replicates do
    [
      0.25,
      0.08333333333333333,
      0.08333333333333333,
      0.07142857142857142,
      0.2857142857142857,
      0.3333333333333333,
      0.3333333333333333,
      0.4166666666666667
    ]
  end
end
