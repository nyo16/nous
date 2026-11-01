defmodule Nous.Eval.Store.FileConformanceTest do
  @moduledoc false
  use Nous.Eval.Store.Conformance, store: Nous.Eval.Store.File, tmp_dir: :root
end

defmodule Nous.Eval.Store.FileTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Codec
  alias Nous.Eval.Store.Conformance
  alias Nous.Eval.Store.File, as: FileStore

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "store")
    {:ok, state} = FileStore.init(root: root)
    %{state: state, root: root, tmp_dir: tmp_dir}
  end

  test "init/1 requires a root" do
    assert {:error, {:missing_option, :root}} = FileStore.init([])
    assert {:error, {:invalid_option, {:root, ""}}} = FileStore.init(root: "")
  end

  test "a run is one codec JSON file plus one manifest line", %{state: state, root: root} do
    run = Conformance.run_fixture("run-1")
    {:ok, _} = FileStore.put_run(state, run)

    payload = File.read!(Path.join([root, "runs", "run-1.json"]))
    assert {:ok, ^run} = Codec.decode_run_json(payload)
    assert payload =~ ~s({"$atom":"executed"})
    assert payload =~ ~s("name":["nous","agent","tool_call","stop"])

    assert [line] =
             root |> Path.join("manifest.jsonl") |> File.read!() |> String.split("\n", trim: true)

    assert {:ok, %{id: "run-1", sample_count: 2}} = Codec.decode_summary_json(line)
    refute line =~ "events"

    # Every write went through a temp file that was renamed away.
    assert root |> Path.join("**/*.tmp-*") |> Path.wildcard() == []
  end

  test "traversal ids never create files outside the root", %{state: state, tmp_dir: tmp_dir} do
    for id <- ["../escape", "../../escape", "runs/../../escape"] do
      assert {:error, {:invalid_run_id, ^id}} =
               FileStore.put_run(state, Conformance.run_fixture(id))
    end

    assert Path.wildcard(Path.join(tmp_dir, "**/escape*")) == []
  end

  test "a put torn between run file and manifest completes on retry", %{state: state, root: root} do
    run = Conformance.run_fixture("run-torn")
    {:ok, payload} = Codec.encode_run_json(run)
    File.write!(Path.join([root, "runs", "run-torn.json"]), payload)

    assert {:ok, []} = FileStore.list_runs(state, [])
    assert {:ok, _} = FileStore.put_run(state, run)
    assert {:ok, [%{id: "run-torn"}]} = FileStore.list_runs(state, [])
    assert {:error, :already_exists} = FileStore.put_run(state, run)
  end

  test "get_run/2 refuses a run written by a newer schema version", %{state: state, root: root} do
    {:ok, _} = FileStore.put_run(state, Conformance.run_fixture("run-future"))
    path = Path.join([root, "runs", "run-future.json"])

    future =
      path
      |> File.read!()
      |> JSON.decode!()
      |> Map.put("schema_version", 99)
      |> JSON.encode!()

    File.write!(path, future)

    assert {:error, {:unsupported_schema_version, 99}} = FileStore.get_run(state, "run-future")
  end

  test "baselines.jsonl only ever grows", %{state: state, root: root} do
    {:ok, _} = FileStore.put_run(state, Conformance.run_fixture("run-a"))
    {:ok, _} = FileStore.put_run(state, Conformance.run_fixture("run-b"))
    {:ok, _} = FileStore.put_baseline(state, "main", "run-a")
    {:ok, _} = FileStore.put_baseline(state, "main", "run-b")

    lines = root |> Path.join("baselines.jsonl") |> File.read!() |> String.split("\n", trim: true)

    assert [%{"label" => "main", "run_id" => "run-a"}, %{"label" => "main", "run_id" => "run-b"}] =
             Enum.map(lines, &JSON.decode!/1)
  end
end
