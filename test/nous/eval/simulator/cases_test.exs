defmodule Nous.Eval.Simulator.CasesTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Case, Dataset}
  alias Nous.Eval.Scorer.Spec
  alias Nous.Eval.Scorers.NoToolErrors
  alias Nous.Eval.Simulator
  alias Nous.Eval.Simulator.Scenario
  alias Nous.Eval.Simulator.Scorers.{Breach, Rubric, Said, State}

  @moduletag :tmp_dir

  @yaml """
  schema: nous.sim_case/1
  name: refunds
  cases:
    - id: refund-1
      split: test
      tags: [refund]
      fixture: orders
      max_turns: 6
      user:
        persona: Terse.
        goal: Get a refund for W1.
        known: {order_id: W1, total: 54.04}
        unknown: [zip code]
        constraints: [No replacements.]
        opener: Hi.
        done_when: The refund is issued.
      expected:
        reward_basis: [state]
        state:
          - {path: [orders, W1, status], equals: refunded}
        said: ["54.04"]
      scorers: [no_tool_errors]
  """

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp elixir_case do
    Simulator.sim_case!(%{
      id: "refund-1",
      split: "test",
      tags: ["refund"],
      fixture: "orders",
      max_turns: 6,
      user: %{
        persona: "Terse.",
        goal: "Get a refund for W1.",
        known: %{order_id: "W1", total: 54.04},
        unknown: ["zip code"],
        constraints: ["No replacements."],
        opener: "Hi.",
        done_when: "The refund is issued."
      },
      expected: %{
        reward_basis: [:state],
        state: [%{path: ["orders", "W1", "status"], equals: "refunded"}],
        said: ["54.04"]
      },
      scorers: [NoToolErrors]
    })
  end

  describe "loading nous.sim_case/1" do
    test "YAML, JSONL and Elixir build the same case and the same hash", %{tmp_dir: dir} do
      assert {:ok, yaml} = Dataset.load(write(dir, "sims.yaml", @yaml))

      line =
        JSON.encode!(%{
          "schema" => "nous.sim_case/1",
          "id" => "refund-1",
          "split" => "test",
          "tags" => ["refund"],
          "fixture" => "orders",
          "max_turns" => 6,
          "user" => %{
            "persona" => "Terse.",
            "goal" => "Get a refund for W1.",
            "known" => %{"order_id" => "W1", "total" => 54.04},
            "unknown" => ["zip code"],
            "constraints" => ["No replacements."],
            "opener" => "Hi.",
            "done_when" => "The refund is issued."
          },
          "expected" => %{
            "reward_basis" => ["state"],
            "state" => [%{"path" => ["orders", "W1", "status"], "equals" => "refunded"}],
            "said" => ["54.04"]
          },
          "scorers" => ["no_tool_errors"]
        })

      assert {:ok, jsonl} = Dataset.load(write(dir, "sims.jsonl", line <> "\n"))
      assert {:ok, elixir} = Dataset.new([elixir_case()])

      assert yaml.hash == jsonl.hash
      assert yaml.hash == elixir.hash

      [%Case{} = c] = yaml.cases
      assert %Scenario{kind: :task, max_turns: 6, fixture: "orders", opener: "Hi."} = c.input
      assert c.input.known == %{"order_id" => "W1", "total" => 54.04}

      # reward_basis [state]: state gates; said is tracked at weight 0; the
      # case's own scorers come after.
      assert [
               %Spec{module: State, required: true},
               %Spec{module: Said, required: false, weight: 0},
               %Spec{module: NoToolErrors}
             ] = c.scorers

      assert c.expected["terminations"] == ["stop", "transfer", "out_of_scope"]
    end

    test "editing the scenario changes the dataset hash", %{tmp_dir: dir} do
      {:ok, a} = Dataset.load(write(dir, "a.yaml", @yaml))

      {:ok, b} =
        Dataset.load(
          write(dir, "b.yaml", String.replace(@yaml, "persona: Terse.", "persona: Chatty."))
        )

      refute a.hash == b.hash
    end

    test "a nous.case/1 line and a nous.sim_case/1 line share a JSONL file", %{tmp_dir: dir} do
      lines = [
        JSON.encode!(%{"id" => "plain", "input" => "hi"}),
        JSON.encode!(%{
          "schema" => "nous.sim_case/1",
          "id" => "sim",
          "max_turns" => 2,
          "user" => %{"goal" => "g"},
          "expected" => %{"said" => ["x"]}
        })
      ]

      assert {:ok, %Dataset{cases: cases}} =
               Dataset.load(write(dir, "mixed.jsonl", Enum.join(lines, "\n")))

      assert [%Case{id: "plain", input: "hi"}, %Case{id: "sim", input: %Scenario{}}] = cases
    end

    test "an adversarial case attaches the breach scorer only" do
      c =
        Simulator.sim_case!(%{
          "id" => "attack",
          "kind" => "adversarial",
          "max_turns" => 4,
          "attack" => %{"objective" => "o", "strategy" => "roleplay"},
          "expected" => %{"breach_when" => %{"tools" => ["issue_refund"]}}
        })

      assert %Scenario{kind: :adversarial, attack: %{objective: "o", strategy: :roleplay}} =
               c.input

      assert [%Spec{module: Breach, required: true}] = c.scorers
    end

    test "a rubric is a diagnostic judge unless it gates" do
      base = %{
        "id" => "r",
        "max_turns" => 2,
        "user" => %{"goal" => "g"},
        "expected" => %{
          "said" => ["x"],
          "rubric" => %{"judge" => "openai:gpt-4o-2024-08-06", "criteria" => "Polite."}
        }
      }

      assert [_said, %Spec{module: Rubric, required: false, weight: 0, opts: opts}] =
               Simulator.sim_case!(base).scorers

      assert opts[:gate] == false

      gated = put_in(base, ["expected", "rubric", "gate"], true)

      assert [_said, %Spec{module: Rubric, required: true, weight: 1}] =
               Simulator.sim_case!(gated).scorers
    end
  end

  describe "validation fails closed" do
    @base %{
      "id" => "c",
      "max_turns" => 3,
      "user" => %{"goal" => "g"},
      "expected" => %{"said" => ["x"]}
    }

    for {name, change, message} <- [
          {"missing max_turns", {:delete, ["max_turns"]}, "max_turns is required"},
          {"max_turns out of range", {:put, ["max_turns"], 51},
           "max_turns must be an integer in 1..50"},
          {"an input key", {:put, ["input"], "hi"}, ~s(unknown key "input")},
          {"an unknown user key", {:put, ["user", "mood"], "x"}, ~s(user: unknown key "mood")},
          {"a task without a goal", {:put, ["user"], %{"persona" => "p"}},
           "user.goal is required"},
          {"a task without a component", {:put, ["expected"], %{"terminations" => ["stop"]}},
           "at least one of state, said, tools"},
          {"a reward basis naming a missing component",
           {:put, ["expected", "reward_basis"], ["state"]}, "which expected does not give"},
          {"an unknown kind", {:put, ["kind"], "chat"}, "kind must be task or adversarial"},
          {"an unknown termination", {:put, ["expected", "terminations"], ["hangup"]},
           "expected.terminations"},
          {"a non-scalar known fact", {:put, ["user", "known"], %{"a" => [1]}}, "user.known"},
          {"attack on a task case", {:put, ["attack"], %{"objective" => "o"}},
           "attack is only allowed on kind: adversarial"}
        ] do
      test "rejects #{name}" do
        assert {:error, message} =
                 Simulator.sim_case(apply_change(@base, unquote(Macro.escape(change))))

        assert message =~ unquote(message)
        assert message =~ ~s(case "c")
      end
    end

    test "rejects an adversarial case without breach_when or with an unknown strategy" do
      attack = %{
        "id" => "a",
        "kind" => "adversarial",
        "max_turns" => 2,
        "attack" => %{"objective" => "o"},
        "expected" => %{}
      }

      assert {:error, message} = Simulator.sim_case(attack)
      assert message =~ "breach_when"

      assert {:error, message} =
               Simulator.sim_case(%{
                 attack
                 | "attack" => %{"objective" => "o", "strategy" => "bribery"},
                   "expected" => %{"breach_when" => %{"tools" => ["t"]}}
               })

      assert message =~ "attack.strategy must be one of"
    end

    test "file errors name the file and the case", %{tmp_dir: dir} do
      yaml = String.replace(@yaml, ~r/ *max_turns: 6\n/, "")
      assert {:error, message} = Dataset.load(write(dir, "bad.yaml", yaml))
      assert message =~ "bad.yaml"
      assert message =~ ~s[case 1 ("refund-1")]
      assert message =~ "max_turns is required"
    end
  end

  defp apply_change(map, {:delete, path}), do: pop_in(map, path) |> elem(1)
  defp apply_change(map, {:put, path, value}), do: put_in(map, path, value)
end
