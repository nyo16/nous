defmodule Nous.Eval.Evaluators.FuzzyMatchTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Evaluators.FuzzyMatch

  # Reference corpus for the invariant tests below. Deliberately mixes lengths,
  # empties, shared prefixes and non-ASCII graphemes.
  @corpus [
    "",
    "a",
    "abc",
    "xyz",
    "kitten",
    "sitting",
    "saturday",
    "sunday",
    "the quick brown fox",
    "the quick brown cat",
    "café",
    "cafe",
    "👍"
  ]

  describe "levenshtein_distance/2" do
    test "identical strings have distance 0" do
      assert FuzzyMatch.levenshtein_distance("abc", "abc") == 0
      assert FuzzyMatch.levenshtein_distance("saturday", "saturday") == 0
    end

    test "the textbook pairs" do
      assert FuzzyMatch.levenshtein_distance("kitten", "sitting") == 3
      assert FuzzyMatch.levenshtein_distance("saturday", "sunday") == 3
      assert FuzzyMatch.levenshtein_distance("flaw", "lawn") == 2
      assert FuzzyMatch.levenshtein_distance("gumbo", "gambol") == 2
    end

    test "fully disjoint strings of equal length cost one substitution each" do
      assert FuzzyMatch.levenshtein_distance("abc", "xyz") == 3
    end

    test "empty on either side is the length of the other" do
      assert FuzzyMatch.levenshtein_distance("", "") == 0
      assert FuzzyMatch.levenshtein_distance("", "abc") == 3
      assert FuzzyMatch.levenshtein_distance("abc", "") == 3
      assert FuzzyMatch.levenshtein_distance("", "a") == 1
      assert FuzzyMatch.levenshtein_distance("a", "") == 1
    end

    test "counts graphemes, not bytes" do
      # One emoji is 4 bytes but a single grapheme: a byte-wise DP would say 4.
      assert byte_size("👍") == 4
      assert FuzzyMatch.levenshtein_distance("👍", "") == 1

      # A ZWJ sequence is 11 codepoints / 18 bytes and still one grapheme.
      family = "👨‍👩‍👧"
      assert byte_size(family) > 4
      assert String.length(family) == 1
      assert FuzzyMatch.levenshtein_distance(family, "") == 1

      # A combining accent (NFD) adds 2 bytes but only 1 grapheme.
      nfd = "noe\u0301l"
      assert byte_size(nfd) == byte_size("noel") + 2
      assert FuzzyMatch.levenshtein_distance(nfd, "noel") == 1

      # Precomposed vs decomposed are distinct graphemes, one edit apart.
      assert FuzzyMatch.levenshtein_distance("é", "e\u0301") == 1
      assert FuzzyMatch.levenshtein_distance("café", "cafe") == 1
    end

    test "is symmetric: d(a, b) == d(b, a)" do
      for a <- @corpus, b <- @corpus do
        assert FuzzyMatch.levenshtein_distance(a, b) == FuzzyMatch.levenshtein_distance(b, a),
               "asymmetric distance for #{inspect(a)} / #{inspect(b)}"
      end
    end

    test "never exceeds the length of the longer string" do
      # The bound the old implementation broke, which is what drove similarity
      # negative.
      for a <- @corpus, b <- @corpus do
        max_len = max(String.length(a), String.length(b))

        assert FuzzyMatch.levenshtein_distance(a, b) <= max_len,
               "distance exceeded max_len for #{inspect(a)} / #{inspect(b)}"
      end
    end

    test "distance 0 implies the strings are equal" do
      for a <- @corpus, b <- @corpus, a != b do
        assert FuzzyMatch.levenshtein_distance(a, b) > 0
      end
    end
  end

  describe "calculate_similarity/2" do
    test "identical strings score exactly 1.0" do
      assert FuzzyMatch.calculate_similarity("abc", "abc") == 1.0
      assert FuzzyMatch.calculate_similarity("", "") == 1.0

      sentence = "Paris is the capital of France"
      assert FuzzyMatch.calculate_similarity(sentence, sentence) == 1.0
    end

    test "fully disjoint strings score 0.0, never negative" do
      assert FuzzyMatch.calculate_similarity("abc", "xyz") == 0.0
    end

    test "partial matches land strictly between 0.0 and 1.0" do
      similarity = FuzzyMatch.calculate_similarity("kitten", "sitting")
      assert_in_delta similarity, 4 / 7, 1.0e-9
    end

    test "always lands in [0.0, 1.0] for every pair in the corpus" do
      for a <- @corpus, b <- @corpus do
        similarity = FuzzyMatch.calculate_similarity(a, b)

        assert is_float(similarity)

        assert similarity >= 0.0 and similarity <= 1.0,
               "similarity #{similarity} out of range for #{inspect(a)} / #{inspect(b)}"
      end
    end
  end

  describe "evaluate/3" do
    test "an exact match scores 1.0 and passes the default 0.8 threshold" do
      # The user-visible bug: exact matches scored 0.333 and failed every
      # :fuzzy_match case configured with the default threshold.
      sentence = "Paris is the capital of France"
      result = FuzzyMatch.evaluate(sentence, sentence, %{})

      assert result.score == 1.0
      assert result.passed == true
      assert result.reason == nil
      assert result.details.similarity == 1.0
      assert result.details.threshold == 0.8
    end

    test "an exact match passes when handed the runner's %{output: _} shape" do
      result = FuzzyMatch.evaluate(%{output: "the capital is Paris"}, "the capital is Paris", %{})

      assert result.score == 1.0
      assert result.passed == true
    end

    test "a near match above the threshold passes" do
      expected = "Paris is the capital of France"
      result = FuzzyMatch.evaluate(expected <> ".", expected, %{})

      assert result.passed == true
      assert result.score > 0.8
    end

    test "an unrelated answer fails and reports a non-negative score" do
      result = FuzzyMatch.evaluate("abc", "xyz", %{})

      assert result.passed == false
      assert result.score == 0.0
      assert result.reason =~ "below threshold"
    end

    test "a missing output fails without crashing" do
      result = FuzzyMatch.evaluate(%{output: nil}, "anything", %{})

      assert result.passed == false
      assert result.score == 0.0
    end

    test "case and whitespace normalisation still applies by default" do
      result = FuzzyMatch.evaluate("  PARIS   is\tthe capital  ", "paris is the capital", %{})

      assert result.score == 1.0
      assert result.passed == true
    end

    test "case sensitivity can be re-enabled" do
      result = FuzzyMatch.evaluate("PARIS", "paris", %{case_insensitive: false})

      assert result.score < 1.0
    end

    test "a custom threshold is honoured" do
      result = FuzzyMatch.evaluate("kitten", "sitting", %{threshold: 0.5})

      assert result.passed == true
      assert_in_delta result.score, 4 / 7, 1.0e-9
    end
  end

  describe "behaviour conformance" do
    test "implements the Nous.Eval.Evaluator callbacks" do
      assert FuzzyMatch.name() == "Fuzzy Match"
      assert function_exported?(FuzzyMatch, :evaluate, 3)
    end

    test "is reachable through the evaluator dispatch table" do
      assert Nous.Eval.Evaluator.get_evaluator(:fuzzy_match) == FuzzyMatch

      result = Nous.Eval.Evaluator.run(:fuzzy_match, "hello world", "hello world", %{})

      assert result.score == 1.0
      assert result.passed == true
    end
  end
end
