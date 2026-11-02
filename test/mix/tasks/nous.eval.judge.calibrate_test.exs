defmodule Mix.Tasks.Nous.Eval.Judge.CalibrateTest do
  # Mix.shell/1 is global.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Mix.Tasks.Nous.Eval.Judge.Calibrate
  alias Nous.Eval.Codec
  alias Nous.Eval.JudgeStub
  alias Nous.Eval.Scorers.Judge
  alias Nous.Eval.Store

  @judge "openai:judge-model-2026-01-01"

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    # The scripted judge answers whatever the replayed output asks for.
    JudgeStub.install(fn %{user: user} ->
      [_, label] = Regex.run(~r/judge says: (\S+)/, JudgeStub.fenced(user, "AGENT_OUTPUT"))
      JudgeStub.verdict(label)
    end)

    :ok
  end

  defp write_cases(dir, rows) do
    path = Path.join(dir, "judge_cases.jsonl")

    lines =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {{human, judge, split}, i} ->
        JSON.encode!(%{
          "id" => "c#{i}",
          "input" => "question #{i}",
          "output" => "answer #{i}; judge says: #{judge}",
          "human_label" => human,
          "annotator" => "ana",
          "split" => split,
          "group" => "c#{i}",
          "provenance" => "fixture"
        })
      end)

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp output_lines do
    receive do
      {:mix_shell, :info, [line]} -> [line | output_lines()]
    after
      0 -> []
    end
  end

  defp run_failing(args) do
    assert catch_exit(Calibrate.run(args)) == {:shutdown, 2}
    assert_received {:mix_shell, :error, [message]}
    message
  end

  test "prints the holdout report and stores the result under the judge fingerprint",
       %{tmp_dir: dir} do
    dataset =
      write_cases(dir, [
        {"pass", "pass", "holdout"},
        {"pass", "pass", "holdout"},
        {"fail", "pass", "holdout"},
        {"fail", "fail", "holdout"},
        {"pass", "fail", "tune"}
      ])

    store_dir = Path.join(dir, "store")
    Calibrate.run(["--judge", @judge, "--dataset", dataset, "--store", "file:" <> store_dir])

    output = Enum.join(output_lines(), "\n")
    assert output =~ "Judge calibration — #{@judge}"
    assert output =~ "agreement     75.0% (3/4"
    assert output =~ "false pass    50.0% (1/2"

    {:ok, config} = Judge.init(judge: @judge)
    fingerprint = Judge.fingerprint_id(config)
    assert output =~ "Stored in file:#{store_dir} under #{fingerprint}"

    {:ok, store} = Store.File.init(root: store_dir)
    assert {:ok, result} = Store.File.get_calibration(store, fingerprint)
    assert %{n_holdout: 4, n_tune: 1, agreement: %{count: 3, n: 4}} = result

    # The stored result is what a judge with require_calibration accepts.
    assert {:ok, _} =
             Judge.init(
               judge: @judge,
               require_calibration: [min_kappa: 0.0, max_false_pass: 0.5],
               calibration: result
             )
  end

  if Code.ensure_loaded?(Exqlite) do
    @tag :sqlite
    test "a Likert judge with a rubric file, JSON output and an SQLite store", %{tmp_dir: dir} do
      dataset =
        write_cases(dir, [
          {"1", "1", "holdout"},
          {"2", "3", "holdout"},
          {"3", "3", "holdout"},
          {"1", "2", "holdout"},
          {"3", "3", "holdout"}
        ])

      rubric = Path.join(dir, "rubric.md")
      File.write!(rubric, "Score how completely the answer resolves the question.")
      db = Path.join(dir, "eval.sqlite3")

      Calibrate.run([
        "--judge",
        @judge,
        "--dataset",
        dataset,
        "--scale",
        "likert:1:3",
        "--threshold",
        "0.5",
        "--rubric-file",
        rubric,
        "--seed",
        "11",
        "--store",
        "sqlite:" <> db,
        "--format",
        "json"
      ])

      [json] = output_lines()
      assert {:ok, printed} = Codec.decode_calibration_json(json)
      assert printed.kappa_kind == :quadratic_weighted
      assert_in_delta printed.kappa, 0.75, 1.0e-12

      # The CLI judge is the same judge an eval declares with these options.
      {:ok, config} =
        Judge.init(
          judge: @judge,
          rubric: "Score how completely the answer resolves the question.",
          scale: {:likert, 1, 3},
          threshold: 0.5,
          seed: 11
        )

      assert printed.fingerprint_id == Judge.fingerprint_id(config)

      {:ok, store} = Store.SQLite.init(path: db)
      assert {:ok, ^printed} = Store.SQLite.get_calibration(store, printed.fingerprint_id)
    end
  end

  test "operational errors exit with status 2", %{tmp_dir: dir} do
    dataset = write_cases(dir, [{"pass", "pass", "holdout"}])
    store = "file:" <> Path.join(dir, "store")

    assert run_failing(["--judge", @judge]) =~ "missing --dataset"

    assert run_failing(["--judge", @judge, "--dataset", dataset, "--bogus"]) =~
             "invalid option --bogus"

    assert run_failing([
             "--judge",
             @judge,
             "--dataset",
             dataset,
             "--scale",
             "stars",
             "--store",
             store
           ]) =~
             ~s(unknown --scale "stars")

    assert run_failing(["--judge", @judge, "--dataset", dataset, "--store", "s3:bucket"]) =~
             ~s(unknown store kind "s3")

    assert run_failing([
             "--judge",
             @judge,
             "--dataset",
             Path.join(dir, "nope.jsonl"),
             "--store",
             store
           ]) =~
             "cannot read"

    assert run_failing([
             "--judge",
             @judge,
             "--dataset",
             dataset,
             "--scale",
             "likert:1:5",
             "--store",
             store
           ]) =~
             "threshold is required"

    assert run_failing([
             "--judge",
             @judge,
             "--dataset",
             dataset,
             "--format",
             "xml",
             "--store",
             store
           ]) =~
             ~s(unknown format "xml")

    tune_only =
      write_cases(Path.join(dir, "t") |> tap(&File.mkdir_p!/1), [{"pass", "pass", "tune"}])

    assert run_failing(["--judge", @judge, "--dataset", tune_only, "--store", store]) =~
             "no holdout cases"

    refute File.exists?(Path.join([dir, "store", "calibrations"]))
  end
end
