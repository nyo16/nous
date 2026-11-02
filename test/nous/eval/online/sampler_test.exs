defmodule Nous.Eval.Online.SamplerTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Online.Sampler
  alias Nous.Telemetry.RunScope

  doctest Sampler

  defp ids(n, seed) do
    for i <- 1..n do
      :crypto.hash(:md5, "#{seed}-#{i}") |> Base.encode16(case: :lower)
    end
  end

  # F15
  test "a lower rate samples a subset of a higher one" do
    rates = [0.0, 0.001, 0.01, 0.05, 0.1, 0.25, 0.5, 0.9, 1.0]

    for id <- ids(5_000, "nested") ++ for(_ <- 1..1_000, do: RunScope.new_trace_id()) do
      decisions = Enum.map(rates, &Sampler.sampled?(id, &1))
      # Once sampled at some rate, sampled at every higher one.
      assert decisions == Enum.sort(decisions)
    end
  end

  test "the empirical rate lies within the 99.9% Wilson interval over 100k ids" do
    n = 100_000
    ids = ids(n, "rate")

    for rate <- [0.01, 0.1, 0.5] do
      k = Enum.count(ids, &Sampler.sampled?(&1, rate))
      {lo, hi} = wilson(k, n, 3.29)
      assert lo <= rate and rate <= hi, "rate #{rate}: #{k}/#{n} outside [#{lo}, #{hi}]"
    end
  end

  test "the decision is a function of the trace id: the low 56 bits, compared to rate * 2^56" do
    id = "4bf92f3577b34da6a3ce929d0e0e4736"
    r = String.to_integer("a3ce929d0e0e4736" |> binary_part(2, 14), 16)
    assert Sampler.randomness(id) == r
    assert Sampler.randomness(String.upcase(id)) == r
    # Floats near 2^56 lose a few low bits; 64 ulps of margin either way.
    assert Sampler.sampled?(id, (r + 64) / Bitwise.bsl(1, 56))
    refute Sampler.sampled?(id, r / Bitwise.bsl(1, 56) * 0.999999)
  end

  test "keys that are not Nous trace ids are hashed, never parsed as atoms or crash" do
    for key <- ["", "session-42", String.duplicate("z", 32), "ä" <> String.duplicate("0", 30)] do
      r = Sampler.randomness(key)
      assert r >= 0 and r < Bitwise.bsl(1, 56)
      assert Sampler.randomness(key) == r
    end
  end

  test "rate 0.0 samples nothing and 1.0 everything" do
    for id <- ids(1_000, "edges") do
      refute Sampler.sampled?(id, 0.0)
      assert Sampler.sampled?(id, 1.0)
    end
  end

  describe "with a salt" do
    test "the same session id gets a different decision under a different salt" do
      # HMAC-SHA-256 gives "session-42" r < 2^55 under "salt-a" and r >= 2^55
      # under "salt-b".
      assert Sampler.sampled?("session-42", 0.5, "salt-a")
      refute Sampler.sampled?("session-42", 0.5, "salt-b")
    end

    test "the decision is not the unsalted one a client can compute" do
      ids = ids(256, "salted")
      unsalted = Enum.map(ids, &Sampler.sampled?(&1, 0.5))
      salted = Enum.map(ids, &Sampler.sampled?(&1, 0.5, "secret"))

      refute salted == unsalted
    end

    test "keeps the nesting and the rate edges" do
      rates = [0.0, 0.01, 0.1, 0.5, 0.9, 1.0]

      for id <- ids(1_000, "salted-nested") do
        decisions = Enum.map(rates, &Sampler.sampled?(id, &1, "secret"))
        assert decisions == Enum.sort(decisions)
        assert hd(decisions) == false and List.last(decisions) == true
      end
    end
  end

  defp wilson(k, n, z) do
    p = k / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = z * :math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    {center - half, center + half}
  end
end
