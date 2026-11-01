defmodule Nous.Eval.ScorerResolveTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Scorer, Scoring}
  alias Nous.Eval.Scorer.Spec

  # Every option of every built-in, written the way a YAML/JSONL dataset
  # would: string keys, string enum values, lists and maps.
  @file_opts %{
    "equals" => %{
      "expected" => "Paris",
      "case_sensitive" => false,
      "trim" => true,
      "collapse_whitespace" => true
    },
    "similarity" => %{
      "expected" => "Paris",
      "threshold" => 0.9,
      "max_len" => 500,
      "case_sensitive" => false,
      "trim" => false,
      "collapse_whitespace" => true
    },
    "contains" => %{"values" => ["refund"], "mode" => "any", "case_sensitive" => false},
    "not_contains" => %{"values" => ["As an AI"], "case_sensitive" => false},
    "regex" => %{"patterns" => ["order #\\d+"], "mode" => "all", "case_sensitive" => true},
    "output_schema" => %{
      "schema" => %{"type" => "object", "properties" => %{"status" => %{"type" => "string"}}},
      "values" => %{"status" => "approved"}
    },
    "trajectory" => %{
      "expected" => [
        %{"name" => "search", "args" => %{"q" => "x"}},
        %{"name" => "notify", "count" => %{"min" => 1, "max" => 2}}
      ],
      "mode" => "in_order",
      "args" => "exact",
      "args_overrides" => %{"search" => ["q"], "notify" => "ignore"},
      "ignore_args" => ["request_id", "*_cursor"],
      "arg_defaults" => %{"search" => %{"page" => 1}},
      "numbers" => %{"tolerance" => %{"abs" => 0.01, "rel" => 0.001}},
      "include" => ["executed", "hook_denied"],
      "scope" => %{"sub_agent" => "researcher"},
      "forbid" => ["delete_all"],
      "parallel" => "as_emitted",
      "score" => "f1"
    },
    "tool_args" => %{
      "tool" => "search",
      "args" => %{"q" => "x"},
      "occurrence" => "last",
      "match" => "exact",
      "ignore_args" => ["request_id"],
      "numbers" => "exact",
      "include" => "all",
      "scope" => "tree"
    },
    "tool_count" => %{
      "tool" => "search",
      "min" => 1,
      "max" => 3,
      "include" => ["executed"],
      "scope" => "root"
    },
    "no_tool_errors" => %{"outcomes" => ["crashed", "timeout"], "scope" => "tree"},
    "guard_verdict" => %{
      "guard" => "decision_guard",
      "expected" => "deny",
      "surface" => "tool_call",
      "match" => "any",
      "scope" => "tree"
    },
    "max_cost" => %{"max_usd" => 0.05, "model" => "openai:gpt-4o"},
    "max_latency" => %{"max_ms" => 5000},
    "max_tokens" => %{"max" => 10_000, "field" => "output"},
    "output_retries" => %{"max" => 1, "scope" => "tree"}
  }

  # Options that exclude ones above, initialized in their own declaration.
  @alternative_opts [{"tool_count", %{"exact" => 2}}]

  test "every file-configurable built-in resolves and initializes from file-style options" do
    for {name, opts} <- Enum.to_list(@file_opts) ++ @alternative_opts do
      assert {:ok, %Spec{module: module} = spec} =
               Scorer.resolve(name, Map.merge(opts, %{"required" => false, "weight" => 0.5})),
             name

      assert module.id() == name
      assert %Spec{required: false, weight: 0.5} = spec
      assert {:ok, [_prepared]} = Scoring.init([spec]), name
      assert is_map(module.describe(elem(module.init(spec.opts), 1)))
    end

    for {name, opts} <- @file_opts do
      {:ok, %Spec{module: module}} = Scorer.resolve(name, opts)

      covered =
        for {^name, alt} <- @alternative_opts,
            reduce: Map.keys(opts),
            do: (keys -> keys ++ Map.keys(alt))

      assert MapSet.new(module.option_keys()) == MapSet.new(covered, &String.to_existing_atom/1),
             "#{name}: the test must cover every option key"
    end
  end

  test "the built-in table is covered, except the judge (a later slice)" do
    names = Map.keys(@file_opts)

    for name <- names do
      assert {:ok, _} = Scorer.resolve(name, Map.fetch!(@file_opts, name))
    end

    assert length(names) == 15
  end

  test "file values outside an enum are rejected by init, not turned into atoms" do
    for {name, opts} <- [
          {"trajectory", %{"expected" => [%{"name" => "a"}], "mode" => "zigzag_never_an_atom"}},
          {"contains", %{"values" => ["a"], "mode" => "most"}},
          {"guard_verdict", %{"guard" => "input_guard", "expected" => "maybe"}},
          {"tool_args", %{"tool" => "a", "args" => %{}, "occurrence" => "middle"}}
        ] do
      {:ok, spec} = Scorer.resolve(name, opts)
      assert {:error, {_module, message}} = Scoring.init([spec]), name
      assert is_binary(message)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom("zigzag_never_an_atom") end
  end

  test "unknown option keys and the function scorer are rejected at resolve time" do
    assert {:error, _} = Scorer.resolve("contains", %{"values" => ["a"], "valeus" => ["b"]})
    assert {:error, _} = Scorer.resolve("function", %{})
  end
end
