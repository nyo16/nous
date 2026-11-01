defmodule Mix.Tasks.Nous.Eval.Judge.Calibrate do
  @shortdoc "Measures an LLM eval judge against human labels and stores the result"

  @moduledoc """
  Calibrates a `Nous.Eval.Scorers.Judge` configuration against human labels
  (see `Nous.Eval.JudgeCalibration`).

      mix nous.eval.judge.calibrate --judge openai:gpt-4o-2024-08-06 \\
        --dataset priv/eval/judge_cases.jsonl --rubric-file priv/eval/rubric.md

  Replays the dataset's stored outputs through the judge (no agent runs),
  prints agreement, Cohen's κ (quadratic-weighted for Likert scales), the
  confusion matrix, the false-pass rate and the judge error rate on the
  holdout split, and stores the result in an eval store under the judge's
  fingerprint id. A judge configured with `require_calibration:` looks it up
  there.

  The judge options here must match the judge's options in your eval
  (rubric, scale, threshold, include, seed): any difference is another
  fingerprint, and the stored calibration does not apply to it.

  ## Options

    * `--judge MODEL` - the judge model, `provider:model` (required)
    * `--dataset PATH` - a `nous.judge_case/1` JSONL file (required)
    * `--scale SCALE` - `binary` (default), `ternary`, `ternary:PARTIAL`,
      `likert:MIN:MAX`, `choices:A=1.0,B=0.4,C=0`, or the dataset-file JSON
      form (`{"likert": {"min": 1, "max": 5, "labels": {...}}}`)
    * `--threshold X` - the pass threshold (required for non-binary scales)
    * `--rubric-file PATH` - the rubric text (default: the judge's default
      rubric)
    * `--include ITEMS` - comma-separated: `input`, `output`, `reference`,
      `expected` (default `input,output`)
    * `--seed N` - the judge's seed
    * `--concurrency N` - judge calls in flight (default 4)
    * `--store SPEC` - `file:DIR` (default `file:.nous/eval`, the store the
      other `mix nous.eval*` tasks use), `sqlite:PATH` or `duckdb:PATH`
    * `--format FORMAT` - `console` (default) or `json` (the stored record)

  Exits with status 2 on an operational error (bad arguments, unreadable
  dataset, invalid judge options, store failure).
  """

  use Mix.Task

  alias Nous.Eval.{Codec, JudgeCalibration}

  @switches [
    judge: :string,
    dataset: :string,
    scale: :string,
    threshold: :float,
    rubric_file: :string,
    include: :string,
    seed: :integer,
    concurrency: :integer,
    store: :string,
    format: :string
  ]

  @stores %{
    "file" => {Nous.Eval.Store.File, :root},
    "sqlite" => {Nous.Eval.Store.SQLite, :path},
    "duckdb" => {Nous.Eval.Store.DuckDB, :path}
  }

  @formats %{"console" => :console, "json" => :json}

  @default_store "file:.nous/eval"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    case execute(argv) do
      :ok ->
        :ok

      {:error, message} ->
        Mix.shell().error("mix nous.eval.judge.calibrate: " <> message)
        exit({:shutdown, 2})
    end
  end

  defp execute(argv) do
    with {:ok, opts} <- parse_args(argv),
         {:ok, format} <- lookup(@formats, Keyword.get(opts, :format, "console"), "format"),
         {:ok, judge_opts} <- judge_opts(opts),
         {:ok, store, state} <- open_store(Keyword.get(opts, :store, @default_store)),
         {:ok, cases} <- JudgeCalibration.load(Keyword.fetch!(opts, :dataset)),
         {:ok, result} <- calibrate(judge_opts, cases, opts),
         {:ok, _state} <- put(store, state, result) do
      report(format, result, Keyword.get(opts, :store, @default_store))
    end
  end

  defp parse_args(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        missing = Enum.reject([:judge, :dataset], &Keyword.has_key?(opts, &1))

        if missing == [],
          do: {:ok, opts},
          else: {:error, "missing #{Enum.map_join(missing, ", ", &"--#{&1}")}"}

      {_opts, [arg | _], _} ->
        {:error, "unexpected argument #{inspect(arg)}"}

      {_opts, _rest, [{switch, _} | _]} ->
        {:error, "invalid option #{switch}"}
    end
  end

  defp judge_opts(opts) do
    with {:ok, scale} <- scale(Keyword.get(opts, :scale, "binary")),
         {:ok, rubric} <- rubric(Keyword.get(opts, :rubric_file)) do
      judge_opts =
        [judge: Keyword.fetch!(opts, :judge), scale: scale]
        |> put_present(:rubric, rubric)
        |> put_present(:threshold, Keyword.get(opts, :threshold))
        |> put_present(:seed, Keyword.get(opts, :seed))
        |> put_present(:include, include(Keyword.get(opts, :include)))

      {:ok, judge_opts}
    end
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # Scale strings become the dataset-file forms the judge already accepts;
  # nothing here makes an atom.
  defp scale("binary"), do: {:ok, "binary"}
  defp scale("ternary"), do: {:ok, "ternary"}

  defp scale("ternary:" <> partial) do
    case Float.parse(partial) do
      {value, ""} -> {:ok, %{"ternary" => %{"partial" => value}}}
      _ -> {:error, "invalid --scale ternary:#{partial}: PARTIAL must be a number"}
    end
  end

  defp scale("likert:" <> range) do
    with [min, max] <- String.split(range, ":"),
         {min, ""} <- Integer.parse(min),
         {max, ""} <- Integer.parse(max) do
      {:ok, %{"likert" => %{"min" => min, "max" => max}}}
    else
      _ -> {:error, "invalid --scale likert:#{range}: expected likert:MIN:MAX"}
    end
  end

  defp scale("choices:" <> pairs) do
    pairs
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
      with [label, value] <- String.split(pair, "=", parts: 2),
           {number, ""} <- Float.parse(value) do
        {:cont, {:ok, Map.put(acc, String.trim(label), number)}}
      else
        _ -> {:halt, {:error, "invalid --scale choice #{inspect(pair)}: expected LABEL=VALUE"}}
      end
    end)
    |> case do
      {:ok, choices} -> {:ok, %{"choices" => choices}}
      error -> error
    end
  end

  defp scale("{" <> _ = json) do
    case JSON.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, "invalid --scale: not a JSON object"}
    end
  end

  defp scale(other), do: {:error, "unknown --scale #{inspect(other)}"}

  defp rubric(nil), do: {:ok, nil}

  defp rubric(path) do
    case File.read(path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error, "cannot read --rubric-file #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp include(nil), do: nil
  defp include(items), do: items |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp open_store(spec) do
    with [kind, location] when location != "" <- String.split(spec, ":", parts: 2),
         {:ok, {module, key}} <- lookup(@stores, kind, "store") do
      case module.init([{key, location}]) do
        {:ok, state} -> {:ok, module, state}
        {:error, reason} -> {:error, "cannot open store #{spec}: #{describe(reason)}"}
      end
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         "invalid --store #{inspect(spec)}: expected file:DIR, sqlite:PATH or duckdb:PATH"}
    end
  end

  defp lookup(table, key, name) do
    case Map.fetch(table, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         "unknown #{name} #{inspect(key)}; expected one of #{Enum.join(Map.keys(table), ", ")}"}
    end
  end

  defp calibrate(judge_opts, cases, opts) do
    case JudgeCalibration.calibrate(judge_opts, cases, Keyword.take(opts, [:concurrency])) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp put(store, state, result) do
    case store.put_calibration(state, result.fingerprint_id, result) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, "cannot store the calibration: #{describe(reason)}"}
    end
  end

  defp report(:console, result, store) do
    Mix.shell().info(JudgeCalibration.format(result))
    Mix.shell().info("\nStored in #{store} under #{result.fingerprint_id}")
  end

  defp report(:json, result, _store) do
    {:ok, json} = Codec.encode_calibration_json(result)
    Mix.shell().info(json)
  end

  defp describe(message) when is_binary(message), do: message
  defp describe(:no_holdout_cases), do: "the dataset has no holdout cases"

  defp describe({:unknown_human_label, id, label}),
    do: "case #{inspect(id)}: human_label #{inspect(label)} is not a label of the judge's scale"

  defp describe({:unsupported_include, items}),
    do: "judge cases carry no trace, so the judge cannot include #{inspect(items)}"

  defp describe(reason), do: inspect(reason)
end
