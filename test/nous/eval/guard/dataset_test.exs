defmodule Nous.Eval.Guard.DatasetTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Guard.{Case, Dataset, Hygiene, Registry}

  @builtin Path.expand("../../../fixtures/guard", __DIR__)

  defp tmp do
    dir = Path.join(System.tmp_dir!(), "nous_guard_ds_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp user(id, label, split, text) do
    {:ok, c} =
      Case.from_map(%{
        "schema" => "nous.guard_case/1",
        "id" => id,
        "surface" => "user_input",
        "label" => label,
        "split" => split,
        "input" => %{"text" => text},
        "provenance" => %{"source" => "t", "license" => "MIT"}
      })

    c
  end

  describe "the built-in dataset" do
    setup do
      {:ok, ds} = Dataset.load(@builtin)
      {:ok, ds: ds}
    end

    test "loads against its manifest and passes every hygiene rule", %{ds: ds} do
      assert ds.name == "nous-builtin-guard"
      assert :ok = Dataset.validate(ds, licences: :in_repo, pii: true, near_duplicates: true)

      assert Enum.sort(Enum.uniq(Enum.map(ds.cases, & &1.surface))) == [
               :model_output,
               :tool_call,
               :tool_result,
               :user_input
             ]
    end

    test "the 140 migrated DecisionGuard records keep their splits and provenance", %{ds: ds} do
      migrated =
        Enum.filter(ds.cases, fn c ->
          String.starts_with?(c.id, ["deepset-", "jackhhao-", "hard-negative-"]) or
            c.id =~ ~r/^nous-b?\d+$/
        end)

      assert length(migrated) == 140
      assert Enum.frequencies_by(migrated, & &1.split) == %{tune: 99, holdout: 41}
      assert Enum.count(migrated, &("hard_negative" in &1.tags)) == 20

      for c <- migrated, String.starts_with?(c.id, "deepset-") do
        "deepset-" <> row = c.id
        assert c.provenance["source_row"] == String.to_integer(row)
        assert c.provenance["source_revision"] == "4f61ecb038e9c3fb77e21034b22511b523772cdd"
        assert c.provenance["upstream_label"] in ["0", "1"]
      end

      jack = Enum.filter(migrated, &String.starts_with?(&1.id, "jackhhao-"))
      assert length(jack) == 70
      assert Enum.all?(jack, &is_integer(&1.provenance["source_row"]))
    end

    test "every split of every surface holds both labels", %{ds: ds} do
      for {{surface, split}, labels} <-
            Enum.group_by(ds.cases, &{&1.surface, &1.split}, & &1.label) do
        assert :block in labels and :allow in labels, "#{surface}/#{split}"
      end
    end

    test "generated test-split cases await review and are not certifiable", %{ds: ds} do
      generated_test =
        Enum.filter(
          ds.cases,
          &(&1.split == :test and &1.provenance["label_source"] == "generated")
        )

      assert generated_test != []

      assert Enum.all?(
               generated_test,
               &(&1.provenance["review"] == "pending" and not Case.certifiable?(&1))
             )
    end

    test "the registry pins exactly these files" do
      for {name, sha} <- Registry.builtin_files() do
        assert sha ==
                 Base.encode16(:crypto.hash(:sha256, File.read!(Path.join(@builtin, name))),
                   case: :lower
                 ),
               name
      end
    end
  end

  test "a file edited behind the manifest's back is refused" do
    dir = tmp()

    {:ok, _manifest} =
      Dataset.write([user("a", "block", "tune", "x"), user("b", "allow", "tune", "y")], dir,
        name: "t"
      )

    assert {:ok, %Dataset{name: "t"}} = Dataset.load(dir)

    File.write!(
      Path.join(dir, "user_input.jsonl"),
      Hygiene.canonical_jsonl([user("a", "allow", "tune", "x")])
    )

    assert {:error, message} = Dataset.load(dir)
    assert message =~ "does not match the manifest"
  end

  test "malformed lines and duplicate ids fail the load with their location" do
    dir = tmp()
    File.mkdir_p!(dir)
    path = Path.join(dir, "cases.jsonl")
    line = JSON.encode!(Case.to_map(user("a", "block", "tune", "x")))

    File.write!(path, line <> "\n{not json\n")
    assert {:error, message} = Dataset.load(path)
    assert message =~ "cases.jsonl:2"

    File.write!(path, line <> "\n" <> line <> "\n")
    assert {:error, message} = Dataset.load(path)
    assert message =~ "duplicate case ids"
  end

  test "validation reports leakage, missing labels and exact duplicates" do
    {:ok, ds} =
      Dataset.new([
        %{user("a", "block", "tune", "same words here") | group: "g"},
        %{user("b", "block", "holdout", "other words") | group: "g"},
        user("c", "allow", "tune", "Same  words here")
      ])

    assert {:error, problems} = Dataset.validate(ds)
    assert Enum.any?(problems, &(&1 =~ "group \"g\" spans splits"))
    assert Enum.any?(problems, &(&1 =~ "user_input/holdout has no allow case"))
    assert Enum.any?(problems, &(&1 =~ "exact duplicates: [\"a\", \"c\"]"))
  end
end
