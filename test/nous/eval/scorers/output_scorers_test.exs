defmodule Nous.Eval.Scorers.OutputScorersTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Case, Score, ScorerError}
  alias Nous.Eval.Scorers
  alias Nous.Eval.TraceBuilder, as: B

  defmodule Refund do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field(:status, :string)
      field(:amount, :integer)
    end
  end

  defp score(module, opts, input_opts) do
    {:ok, config} = module.init(opts)
    module.score(B.input(B.new() |> B.build(), input_opts), config)
  end

  defp failed_run, do: [run_outcome: {:error, :max_iterations_exceeded}, output: nil]

  # Every output scorer fails a failed run with "run_failed" instead of
  # erroring or scoring the nil output.
  @failed_run_cases [
    {Scorers.Equals, [expected: "x"]},
    {Scorers.Similarity, [expected: "x"]},
    {Scorers.Contains, [values: ["x"]]},
    {Scorers.NotContains, [values: ["x"]]},
    {Scorers.Regex, [patterns: ["x"]]},
    {Scorers.OutputSchema, [schema: {:choice, ["x"]}]}
  ]

  test "output scorers fail a failed run with reason run_failed" do
    for {module, opts} <- @failed_run_cases do
      assert {:ok, %Score{value: :fail, passed?: false, reason: "run_failed"}} =
               score(module, opts, failed_run()),
             inspect(module)
    end
  end

  describe "Equals" do
    test "normalizes text per options" do
      assert {:ok, %Score{name: "equals", passed?: true}} =
               score(Scorers.Equals, [expected: "Paris"], output: " Paris\n")

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.Equals, [expected: "Paris"], output: "paris")

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.Equals, [expected: "Paris", case_sensitive: false], output: "PARIS")

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.Equals, [expected: "a b", collapse_whitespace: true],
                 output: "a \n  b"
               )
    end

    test "reads expected.output from the case when no option is given" do
      kase = %Case{id: "c", input: "q", expected: %{"output" => "42"}}
      assert {:ok, %Score{passed?: true}} = score(Scorers.Equals, [], case: kase, output: "42")

      assert {:error, %ScorerError{kind: :invalid_config}} =
               score(Scorers.Equals, [], case: %Case{id: "c", input: "q"}, output: "42")
    end

    test "compares structured values deeply, never via empty strings" do
      expected = %{name: "Al", tags: ["a"], age: 3}

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.Equals, [expected: expected],
                 output: %{"name" => "Al", "tags" => ["a"], "age" => 3.0}
               )

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.Equals, [expected: expected],
                 output: ~s({"name":"Al","tags":["a"],"age":3})
               )

      assert {:ok, %Score{passed?: false, details: %{paths: ["extra"]}}} =
               score(Scorers.Equals, [expected: expected],
                 output: %{"name" => "Al", "tags" => ["a"], "age" => 3, "extra" => 1}
               )

      assert {:error, %ScorerError{kind: :invalid_config}} =
               score(Scorers.Equals, [expected: "Al"], output: %{"name" => "Al"})
    end
  end

  describe "Similarity" do
    test "scores the Levenshtein ratio" do
      assert {:ok, %Score{name: "similarity", value: 1.0, passed?: true}} =
               score(Scorers.Similarity, [expected: "kitten"], output: "kitten")

      # kitten -> sitting: distance 3 over 7 graphemes
      assert {:ok, %Score{value: value, passed?: false}} =
               score(Scorers.Similarity, [expected: "sitting"], output: "kitten")

      assert_in_delta value, 1 - 3 / 7, 1.0e-9

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.Similarity, [expected: "sitting", threshold: 0.5], output: "kitten")

      assert {:ok, %Score{value: 1.0}} = score(Scorers.Similarity, [expected: ""], output: "  ")
    end

    test "refuses texts above max_len instead of running a quadratic comparison" do
      assert {:error, %ScorerError{kind: :invalid_config}} =
               score(Scorers.Similarity, [expected: "short", max_len: 10],
                 output: String.duplicate("x", 11)
               )
    end

    test "rejects bad options" do
      assert {:error, _} = Scorers.Similarity.init(threshold: 1.5)
      assert {:error, _} = Scorers.Similarity.init(max_len: 0)
      assert {:error, _} = Scorers.Similarity.init(expected: %{})
    end
  end

  describe "Contains / NotContains / Regex" do
    test "Contains all vs any, case option" do
      assert {:ok, %Score{name: "contains", passed?: true}} =
               score(Scorers.Contains, [values: ["refund", "order"]],
                 output: "order refund issued"
               )

      assert {:ok, %Score{passed?: false, details: %{missing: [1]}}} =
               score(Scorers.Contains, [values: ["refund", "Order"]],
                 output: "order refund issued"
               )

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.Contains, [values: ["refund", "Order"], case_sensitive: false],
                 output: "order refund"
               )

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.Contains, [values: ["nope", "refund"], mode: "any"],
                 output: "refund"
               )
    end

    test "NotContains" do
      assert {:ok, %Score{name: "not_contains", passed?: true}} =
               score(Scorers.NotContains, [values: ["As an AI"]], output: "Sure.")

      assert {:ok, %Score{passed?: false, details: %{found: [0]}}} =
               score(Scorers.NotContains, [values: ["as an ai"], case_sensitive: false],
                 output: "As an AI, no"
               )
    end

    test "Regex" do
      assert {:ok, %Score{name: "regex", passed?: true}} =
               score(Scorers.Regex, [patterns: ["order #\\d+"]], output: "see order #123")

      assert {:ok, %Score{passed?: false, details: %{unmatched: [1]}}} =
               score(Scorers.Regex, [patterns: ["order", "^refund"]], output: "order refund")

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.Regex, [patterns: ["^REFUND"], case_sensitive: false],
                 output: "refund now"
               )
    end

    test "empty lists, empty strings and invalid patterns are configuration errors" do
      assert {:error, _} = Scorers.Contains.init(values: [])
      assert {:error, _} = Scorers.Contains.init([])
      assert {:error, _} = Scorers.Contains.init(values: [""])
      assert {:error, _} = Scorers.NotContains.init(values: [])
      assert {:error, _} = Scorers.Regex.init(patterns: [])
      assert {:error, msg} = Scorers.Regex.init(patterns: ["ok", "(unclosed"])
      assert msg =~ "patterns[1]"
    end

    test "structured output is a configuration error, not an empty-string match" do
      for {module, opts} <- [
            {Scorers.Contains, [values: ["x"]]},
            {Scorers.NotContains, [values: ["x"]]},
            {Scorers.Regex, [patterns: ["x"]]}
          ] do
        assert {:error, %ScorerError{kind: :invalid_config}} =
                 score(module, opts, output: %{"x" => 1})
      end
    end
  end

  describe "OutputSchema" do
    test "validates text output with the agent's validator" do
      schema = %{name: :string, age: :integer}

      assert {:ok, %Score{name: "output_schema", passed?: true}} =
               score(Scorers.OutputSchema, [schema: schema], output: ~s({"name":"Al","age":3}))

      assert {:ok,
              %Score{
                passed?: false,
                reason: "schema_validation_failed",
                details: %{errors: errors}
              }} =
               score(Scorers.OutputSchema, [schema: schema], output: ~s({"name":"Al","age":"x"}))

      assert errors =~ "age"

      assert {:ok, %Score{passed?: false}} =
               score(Scorers.OutputSchema, [schema: schema], output: "not json")

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.OutputSchema, [schema: {:choice, ["yes", "no"]}], output: "yes")
    end

    test "accepts structured output and checks field values, keeping false values" do
      assert {:ok, %Score{passed?: true}} =
               score(Scorers.OutputSchema, [schema: Refund, values: %{status: "approved"}],
                 output: %Refund{status: "approved", amount: 5}
               )

      assert {:ok,
              %Score{
                passed?: false,
                reason: "field_values_mismatch",
                details: %{paths: ["status"]}
              }} =
               score(Scorers.OutputSchema, [schema: Refund, values: %{"status" => "approved"}],
                 output: %Refund{status: "denied", amount: 5}
               )

      assert {:ok, %Score{passed?: true}} =
               score(Scorers.OutputSchema, [schema: %{ok: :boolean}, values: %{"ok" => false}],
                 output: %{"ok" => false}
               )
    end

    test "an unknown schema module is a configuration error" do
      assert {:error, _} = Scorers.OutputSchema.init(schema: NoSuchSchema)
      assert {:error, _} = Scorers.OutputSchema.init(schema: :string)
      assert {:error, _} = Scorers.OutputSchema.init([])
    end
  end

  describe "Function" do
    test "wraps booleans, numbers and scores" do
      assert {:ok, %Score{name: "mine", value: :pass}} =
               score(Scorers.Function, [name: "mine", fun: fn i -> i.output == "hi" end],
                 output: "hi"
               )

      assert {:ok, %Score{value: 1.0, passed?: true}} =
               score(Scorers.Function, [fun: fn _ -> 1 end], [])

      assert {:ok, %Score{value: 0.3, passed?: false}} =
               score(Scorers.Function, [fun: fn _ -> 0.3 end], [])

      assert {:skip, "n/a"} = score(Scorers.Function, [fun: fn _ -> {:skip, "n/a"} end], [])
    end

    test "requires a 1-arity function and is not file-configurable" do
      assert {:error, _} = Scorers.Function.init(fun: fn -> true end)
      refute function_exported?(Scorers.Function, :option_keys, 0)
    end

    test "describe fingerprints named captures, not anonymous functions" do
      {:ok, named} = Scorers.Function.init(fun: &String.valid?/1)
      {:ok, anon} = Scorers.Function.init(fun: fn _ -> true end)
      assert %{fun: %{module: String, name: :valid?, arity: 1}} = Scorers.Function.describe(named)
      assert %{fun: :anonymous} = Scorers.Function.describe(anon)
    end
  end
end
