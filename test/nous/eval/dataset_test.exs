defmodule Nous.Eval.DatasetTest do
  # async: false - file scorer names resolve through the :eval_scorers app env,
  # and the atom-table assertion needs no concurrently running tests.
  use ExUnit.Case, async: false

  alias Nous.Eval.{Case, Dataset}
  alias Nous.Eval.Scorer.Spec

  @fixtures "test/fixtures/eval/datasets"

  defmodule FixtureScorer do
    @behaviour Nous.Eval.Scorer

    @impl true
    def id, do: "fixture_contains"
    @impl true
    def init(opts), do: {:ok, opts}
    @impl true
    def score(_input, _config), do: {:skip, "fixture"}
    @impl true
    def option_keys, do: [:values]
  end

  defmodule NotAScorer do
    def hello, do: :world
  end

  setup do
    previous = Application.fetch_env(:nous, :eval_scorers)
    Application.put_env(:nous, :eval_scorers, %{"fixture_contains" => FixtureScorer})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:nous, :eval_scorers, value)
        :error -> Application.delete_env(:nous, :eval_scorers)
      end
    end)
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp tmp_file(context, name, content) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nous_dataset_test_#{context}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp by_id(dataset), do: Map.new(dataset.cases, &{&1.id, &1})

  describe "load/2 YAML" do
    test "parses every field into cases" do
      assert {:ok, %Dataset{} = dataset} = Dataset.load(fixture("valid.yaml"))

      assert dataset.name == "refunds"
      assert dataset.source == fixture("valid.yaml")
      assert Enum.map(dataset.cases, & &1.id) == ["refund-1", "refund-2", "refund-2b", "greet-1"]

      cases = by_id(dataset)
      refund = cases["refund-1"]

      assert refund.input == "Refund order 42"

      assert refund.expected == %{
               "tool" => "refund_order",
               "args" => %{"order_id" => 42, "reason" => "damaged"}
             }

      assert refund.tags == ["refund", "smoke"]
      assert refund.threshold === 0.5
      assert refund.group == "refund-1"

      assert [
               %Spec{module: FixtureScorer, opts: [], required: true, weight: 1},
               %Spec{
                 module: FixtureScorer,
                 opts: [values: ["refund issued"]],
                 required: false,
                 weight: 2
               }
             ] = refund.scorers

      assert [system, user] = cases["refund-2"].input
      assert {system.role, system.content} == {:system, "You are terse."}
      assert {user.role, user.content} == {:user, "Refund order 43"}
      assert cases["refund-2"].metadata == %{"source" => "support-ticket", "ticket" => 991}
      assert dataset.hash =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "requires the schema marker" do
      path = tmp_file("schema", "cases.yaml", "cases:\n  - id: a\n    input: hi\n")
      assert {:error, message} = Dataset.load(path)
      assert message =~ "missing schema marker"
    end

    test "rejects an unknown schema version" do
      path = tmp_file("schema2", "cases.yaml", "schema: nous.case/2\ncases: []\n")
      assert {:error, message} = Dataset.load(path)
      assert message =~ ~s(unsupported schema "nous.case/2")
    end

    test "rejects non-string keys at any depth" do
      yaml =
        "schema: nous.case/1\ncases:\n  - id: a\n    input: hi\n    expected:\n      1: one\n"

      path = tmp_file("keys", "cases.yaml", yaml)
      assert {:error, message} = Dataset.load(path)
      assert message =~ "object keys must be strings"
    end

    test "rejects a non-string id" do
      path =
        tmp_file("id", "cases.yaml", "schema: nous.case/1\ncases:\n  - id: 7\n    input: hi\n")

      assert {:error, message} = Dataset.load(path)
      assert message =~ "id must be a non-empty string, got 7"
    end
  end

  describe "load/2 errors name the problem and its place" do
    test "unknown case key" do
      assert {:error, message} = Dataset.load(fixture("unknown_key.yaml"))
      assert message =~ "unknown_key.yaml"
      assert message =~ ~s|case 2 ("b"): unknown key "expect"|
    end

    test "duplicate ids" do
      assert {:error, message} = Dataset.load(fixture("duplicate_id.jsonl"))
      assert message =~ ~s(duplicate case ids: "a")
    end

    test "role outside the whitelist" do
      assert {:error, message} = Dataset.load(fixture("bad_role.yaml"))
      assert message =~ "input: message 2: role must be one of system, user, assistant"
      assert message =~ ~s("developer")
    end

    test "unknown split, with the JSONL line number" do
      assert {:error, message} = Dataset.load(fixture("bad_split.jsonl"))
      assert message =~ ~s(line 2: case "b": split must be one of train, val, test, got "holdout")
    end

    test "unknown scorer" do
      assert {:error, message} = Dataset.load(fixture("unknown_scorer.yaml"))
      assert message =~ ~s(unknown scorer "no_such_scorer")
    end

    test "unknown scorer option" do
      assert {:error, message} = Dataset.load(fixture("unknown_scorer_option.jsonl"))
      assert message =~ ~s(line 1)
      assert message =~ ~s(unknown option "ignore_case")
    end

    test "invalid JSON line" do
      path = tmp_file("json", "cases.jsonl", ~s({"id":"a","input":"x"}\n{"id": \n))
      assert {:error, message} = Dataset.load(path)
      assert message =~ "line 2: invalid JSON"
    end

    test "unsupported extension and missing file" do
      assert {:error, message} = Dataset.load("cases.csv")
      assert message =~ "unsupported dataset file type"

      assert {:error, message} = Dataset.load(Path.join(@fixtures, "missing.jsonl"))
      assert message =~ "cannot read"
    end
  end

  describe "content hash" do
    test "is equal for the same cases in YAML and JSONL, whatever the key and case order" do
      assert {:ok, yaml} = Dataset.load(fixture("valid.yaml"))
      assert {:ok, jsonl} = Dataset.load(fixture("valid.jsonl"))

      assert jsonl.name == "valid"
      assert yaml.hash == jsonl.hash
      # YAML says `weight: 2`, JSONL `2.0`: the same number in JSON.
      assert [_, %{weight: 2}] = by_id(yaml)["refund-1"].scorers
      assert [_, %{weight: 2.0}] = by_id(jsonl)["refund-1"].scorers
    end

    test "is equal for Elixir cases with the same content" do
      assert {:ok, yaml} = Dataset.load(fixture("valid.yaml"))

      elixir = [
        [id: "greet-1", input: "Hi!", tags: ["smoke"]],
        %{
          id: "refund-1",
          input: "Refund order 42",
          expected: %{tool: :refund_order, args: %{"order_id" => 42, reason: "damaged"}},
          tags: ["refund", "smoke"],
          threshold: 0.5,
          scorers: [
            FixtureScorer,
            {FixtureScorer, values: ["refund issued"], required: false, weight: 2}
          ]
        },
        %{
          id: "refund-2",
          input: [Nous.Message.system("You are terse."), Nous.Message.user("Refund order 43")],
          group: "refund-paraphrase",
          split: "test",
          metadata: %{source: "support-ticket", ticket: 991}
        },
        %Case{id: "refund-2b", input: "Please refund order 43", group: "refund-paraphrase"}
      ]

      assert {:ok, dataset} = Dataset.new(elixir)
      assert dataset.hash == yaml.hash
    end

    test "changes when any case content changes" do
      {:ok, base} = Dataset.new([%{id: "a", input: "x", expected: %{"k" => 1}}])

      for changed <- [
            %{id: "a", input: "y", expected: %{"k" => 1}},
            %{id: "a", input: "x", expected: %{"k" => 2}},
            %{id: "a", input: "x", expected: %{"k" => 1}, tags: ["t"]},
            %{id: "a", input: "x", expected: %{"k" => 1}, threshold: 0.7}
          ] do
        {:ok, other} = Dataset.new([changed])
        refute other.hash == base.hash, "expected a different hash for #{inspect(changed)}"
      end
    end
  end

  describe "split assignment" do
    defp cases(range), do: Enum.map(range, &%{id: "case-#{&1}", input: "q#{&1}"})

    test "adding or removing cases never moves the others" do
      {:ok, base} = Dataset.new(cases(1..200))
      {:ok, grown} = Dataset.new(cases(1..201))
      {:ok, shrunk} = Dataset.new(Enum.drop(cases(1..200), 50))

      base_splits = Map.new(base.cases, &{&1.id, &1.split})

      for c <- grown.cases ++ shrunk.cases, Map.has_key?(base_splits, c.id) do
        assert c.split == base_splits[c.id]
      end
    end

    test "buckets are uniform over the default 60/20/20 ratios" do
      {:ok, dataset} = Dataset.new(cases(1..3000))
      counts = Enum.frequencies_by(dataset.cases, & &1.split)

      assert_in_delta counts["train"] / 3000, 0.6, 0.03
      assert_in_delta counts["val"] / 3000, 0.2, 0.03
      assert_in_delta counts["test"] / 3000, 0.2, 0.03
    end

    test "ratios are configurable" do
      {:ok, dataset} = Dataset.new(cases(1..500), split_ratios: [train: 0.5, test: 0.5])
      counts = Enum.frequencies_by(dataset.cases, & &1.split)

      assert Map.keys(counts) |> Enum.sort() == ["test", "train"]
      assert_in_delta counts["train"] / 500, 0.5, 0.06

      assert {:error, message} = Dataset.new(cases(1..3), split_ratios: [train: 0.5])
      assert message =~ "must sum to 1"
      assert {:error, _} = Dataset.new(cases(1..3), split_ratios: [holdout: 1.0])
    end

    test "a group keeps its paraphrases in one split" do
      paraphrases =
        for group <- 1..40, variant <- 1..3 do
          %{id: "g#{group}-v#{variant}", input: "q", group: "group-#{group}"}
        end

      {:ok, dataset} = Dataset.new(paraphrases)

      dataset.cases
      |> Enum.group_by(& &1.group, & &1.split)
      |> Enum.each(fn {group, splits} ->
        assert length(Enum.uniq(splits)) == 1, "#{group} straddles #{inspect(splits)}"
      end)

      assert dataset.cases |> Enum.map(& &1.split) |> Enum.uniq() |> length() > 1
    end

    test "a declared split pulls its group along; conflicting splits are an error" do
      {:ok, dataset} = Dataset.load(fixture("valid.yaml"))
      assert by_id(dataset)["refund-2b"].split == "test"

      assert {:error, message} =
               Dataset.new([
                 %{id: "a", input: "x", group: "g", split: "train"},
                 %{id: "b", input: "x", group: "g", split: "test"}
               ])

      assert message =~ ~s(group "g" declares different splits: test, train)
    end
  end

  describe "filter/2" do
    setup do
      {:ok, dataset} =
        Dataset.new([
          %{id: "a", input: "x", tags: ["refund"], split: "train"},
          %{id: "b", input: "x", tags: ["refund", "smoke"], split: "test"},
          %{id: "c", input: "x", tags: ["smoke"], split: "val"},
          %{id: "d", input: "x", split: "test"}
        ])

      %{dataset: dataset}
    end

    test "by tags (any of), by splits, and both", %{dataset: dataset} do
      ids = fn ds -> Enum.map(ds.cases, & &1.id) end

      assert ids.(Dataset.filter(dataset, tags: ["refund"])) == ["a", "b"]
      assert ids.(Dataset.filter(dataset, tags: ["smoke", "refund"])) == ["a", "b", "c"]
      assert ids.(Dataset.filter(dataset, splits: ["test"])) == ["b", "d"]
      assert ids.(Dataset.filter(dataset, splits: ["test"], tags: ["smoke"])) == ["b"]
    end

    test "recomputes the hash of the subset", %{dataset: dataset} do
      subset = Dataset.filter(dataset, splits: ["test"])
      refute subset.hash == dataset.hash

      {:ok, rebuilt} = Dataset.new(subset.cases)
      assert rebuilt.hash == subset.hash
      assert Dataset.filter(dataset, []).hash == dataset.hash
    end

    test "rejects atom tags and unknown splits", %{dataset: dataset} do
      assert_raise ArgumentError, ~r/values are strings/, fn ->
        Dataset.filter(dataset, tags: [:refund])
      end

      assert_raise ArgumentError, ~r/unknown split/, fn ->
        Dataset.filter(dataset, splits: ["holdout"])
      end
    end
  end

  describe "new/2 validation" do
    test "rejects unknown and string keys in Elixir cases" do
      assert {:error, message} = Dataset.new([%{id: "a", input: "x", tag: ["t"]}])
      assert message =~ "case 1 (\"a\"): unknown key :tag"

      assert {:error, message} = Dataset.new([%{"id" => "a", "input" => "x"}])
      assert message =~ "Elixir case keys must be atoms"
    end

    test "rejects invalid field values" do
      for {fields, expected} <- [
            {%{id: "", input: "x"}, "id must be a non-empty string"},
            {%{id: "a"}, "input must be a string or a non-empty message list"},
            {%{id: "a", input: [%{role: "user", content: "x"}]}, "%Nous.Message{}"},
            {%{id: "a", input: "x", threshold: 1.5}, "threshold must be a number in 0..1"},
            {%{id: "a", input: "x", tags: [:t]}, "tags must be strings"},
            {%{id: "a", input: "x", split: :train}, "split must be one of"},
            {%{id: "a", input: "x", scorers: [NotAScorer]}, "is not a Nous.Eval.Scorer"},
            {%{id: "a", input: "x", scorers: [{FixtureScorer, weight: -1}]}, "invalid weight -1"}
          ] do
        assert {:error, message} = Dataset.new([fields])
        assert message =~ expected
      end
    end

    test "normalizes scorer declarations and numeric thresholds" do
      spec = %Spec{module: FixtureScorer, opts: [values: ["a"]], required: false}

      {:ok, %Dataset{cases: [c]}} =
        Dataset.new([
          %{
            id: "a",
            input: "x",
            threshold: 1,
            scorers: [FixtureScorer, {FixtureScorer, values: ["b"], weight: 0}, spec]
          }
        ])

      assert c.threshold === 1.0

      assert c.scorers == [
               %Spec{module: FixtureScorer, opts: []},
               %Spec{module: FixtureScorer, opts: [values: ["b"]], weight: 0},
               spec
             ]
    end
  end

  describe "atom safety" do
    test "loading files never creates atoms" do
      novel = fn ->
        "zz_novel_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000_000)}"
      end

      write = fn ->
        {k1, k2, v1, tag, role} = {novel.(), novel.(), novel.(), novel.(), novel.()}

        yaml = """
        schema: nous.case/1
        cases:
          - id: #{novel.()}
            input: #{v1}
            expected: {#{k1}: {#{k2}: #{v1}}}
            metadata: {#{k2}: [#{v1}]}
            tags: [#{tag}]
            group: #{novel.()}
        """

        bad_key = ~s({"id":"#{novel.()}","input":"x","#{k1}":1}\n)
        bad_role = ~s({"id":"#{novel.()}","input":[{"role":"#{role}","content":"x"}]}\n)

        bad_scorer =
          ~s({"id":"#{novel.()}","input":"x","scorers":[{"scorer":"#{novel.()}","#{k2}":1}]}\n)

        bad_option =
          ~s({"id":"#{novel.()}","input":"x","scorers":[{"scorer":"fixture_contains","#{k2}":1}]}\n)

        [
          tmp_file("atoms", "cases.yaml", yaml),
          tmp_file("atoms", "key.jsonl", bad_key),
          tmp_file("atoms", "role.jsonl", bad_role),
          tmp_file("atoms", "scorer.jsonl", bad_scorer),
          tmp_file("atoms", "option.jsonl", bad_option)
        ]
      end

      load_all = fn paths -> Enum.map(paths, &Dataset.load/1) end

      # Warm up: the first load pulls in the YAML/JSON code paths and their
      # atoms. Only the second, with fresh strings, is measured.
      warm = load_all.(write.())
      assert [{:ok, _}, {:error, _}, {:error, _}, {:error, _}, {:error, _}] = warm

      paths = write.()
      before = :erlang.system_info(:atom_count)
      results = load_all.(paths)
      after_count = :erlang.system_info(:atom_count)

      assert [{:ok, %Dataset{cases: [c]}}, {:error, _}, {:error, _}, {:error, _}, {:error, _}] =
               results

      assert [{_, %{}}] = Map.to_list(c.expected)
      assert after_count == before
    end
  end
end
