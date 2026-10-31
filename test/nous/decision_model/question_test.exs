defmodule Nous.DecisionModel.QuestionTest do
  use ExUnit.Case, async: true

  alias Nous.DecisionModel.Question

  describe "normalize!/1" do
    test "keeps declaration order of questions and options, ids as declared" do
      questions =
        Question.normalize!([
          {:zeta, [type: :noul, instructions: "z?"]},
          {:alpha,
           [
             type: :choice,
             instructions: "a?",
             criteria: [safe: "ok", suspicious: nil, blocked: "attack"]
           ]},
          {"mid", [type: :score, instructions: "m?", criteria: ["low", "high"]]}
        ])

      assert Enum.map(questions, & &1.id) == [:zeta, :alpha, "mid"]
      assert Enum.map(questions, & &1.type) == [:noul, :choice, :score]

      assert Enum.at(questions, 1).criteria == [
               {:safe, "ok"},
               {:suspicious, nil},
               {:blocked, "attack"}
             ]
    end

    test "accepts %Question{} structs and string types" do
      [q] = Question.normalize!([%Question{id: "x", type: "noul", instructions: "?"}])
      assert q.type == :noul
    end

    test "a single-question map is accepted" do
      assert [%Question{id: :only}] = Question.normalize!(%{only: [type: :noul]})
    end

    test "a map with more than one question is rejected (order would be lost)" do
      assert_raise ArgumentError, ~r/ordered list/, fn ->
        Question.normalize!(%{a: [type: :noul], b: [type: :noul]})
      end
    end

    test "noul criteria are normalised to string keys; a map is put true-first" do
      [kw, map] =
        Question.normalize!(
          kw: [type: :noul, criteria: [true: "yes", false: "no"]],
          map: [type: :noul, criteria: %{"false" => "no", "true" => "yes"}]
        )

      assert kw.criteria == [{"true", "yes"}, {"false", "no"}]
      assert map.criteria == [{"true", "yes"}, {"false", "no"}]
    end

    test "a multi-option choice map is rejected" do
      assert_raise ArgumentError, ~r/not a map/, fn ->
        Question.normalize!(c: [type: :choice, criteria: %{a: "1", b: "2"}])
      end
    end

    test "rejects ids that collide on the wire" do
      assert_raise ArgumentError, ~r/duplicate question id/, fn ->
        Question.normalize!([{:a, [type: :noul]}, {"a", [type: :noul]}])
      end
    end

    test "rejects duplicate option keys" do
      assert_raise ArgumentError, ~r/duplicate option key/, fn ->
        Question.normalize!(c: [type: :choice, criteria: [{:a, nil}, {"a", nil}]])
      end
    end

    test "rejects invalid ids, types and criteria" do
      assert_raise ArgumentError, ~r/must match/, fn ->
        Question.normalize!([{"has space", [type: :noul]}])
      end

      assert_raise ArgumentError, ~r/:type must be/, fn ->
        Question.normalize!(q: [type: :yesno])
      end

      assert_raise ArgumentError, ~r/2 to 10/, fn ->
        Question.normalize!(q: [type: :score, criteria: ["only one"]])
      end

      assert_raise ArgumentError, ~r/at least one option/, fn ->
        Question.normalize!(q: [type: :choice, criteria: []])
      end

      assert_raise ArgumentError, ~r/"true" or "false"/, fn ->
        Question.normalize!(q: [type: :noul, criteria: [{"maybe", "?"}]])
      end

      assert_raise ArgumentError, ~r/non-empty list/, fn -> Question.normalize!([]) end
    end
  end
end
