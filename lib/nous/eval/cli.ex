defmodule Nous.Eval.CLI do
  @moduledoc false
  # Shared by the `mix nous.eval*` tasks: argument parsing, store specs,
  # gates, reports and exit codes.
  #
  # Nothing here turns command-line text into a new atom. Switch names go
  # through `OptionParser`'s `:strict` list (unknown switches stay strings),
  # task modules through `Module.safe_concat/1` (an atom that does not exist
  # is an error, not a new atom), and splits, formats, stores and gate
  # metrics through literal tables or `Nous.Eval.Compare.Metric.parse/1`.
  #
  # Exit codes: 0 pass, 1 regression, 2 operational error. Non-zero codes
  # leave through `exit({:shutdown, code})`, which Mix turns into the
  # process exit status and a test can catch.

  alias Nous.Eval.{Case, Compare, Reporter, Run, Store}
  alias Nous.Eval.Compare.Metric

  @default_store "file:.nous/eval"

  @stores %{
    "file" => {Nous.Eval.Store.File, :root},
    "sqlite" => {Nous.Eval.Store.SQLite, :path},
    "duckdb" => {Nous.Eval.Store.DuckDB, :path}
  }

  @formats %{"console" => :console, "markdown" => :markdown, "json" => :json}

  @splits Map.new(Case.splits(), &{&1, &1})

  @doc false
  def default_store, do: @default_store

  @doc false
  # Ends a task: `{:ok, 0}` returns, `{:ok, code}` exits with it, an error
  # is printed and exits with 2.
  @spec finish(String.t(), {:ok, 0..2} | {:error, String.t()}) :: :ok
  def finish(_task, {:ok, 0}), do: :ok
  def finish(_task, {:ok, code}) when code in [1, 2], do: exit({:shutdown, code})

  def finish(task, {:error, message}) do
    Mix.shell().error("mix #{task}: " <> message)
    exit({:shutdown, 2})
  end

  @doc false
  @spec parse([String.t()], keyword()) :: {:ok, keyword(), [String.t()]} | {:error, String.t()}
  def parse(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, args, []} ->
        {:ok, opts, args}

      {_opts, _args, [{switch, nil} | _]} ->
        {:error, "unknown option #{switch}"}

      {_opts, _args, [{switch, value} | _]} ->
        {:error, "invalid value #{inspect(value)} for #{switch}"}
    end
  end

  @doc false
  @spec task_module(String.t() | nil) :: {:ok, module()} | {:error, String.t()}
  def task_module(nil), do: {:error, "missing --task MODULE"}

  def task_module(name) when is_binary(name) do
    {:ok, Module.safe_concat([name])}
  rescue
    ArgumentError -> {:error, "unknown task module #{inspect(name)}"}
  end

  @doc false
  @spec format(String.t() | nil) :: {:ok, atom()} | {:error, String.t()}
  def format(nil), do: {:ok, :console}
  def format(name), do: lookup(@formats, name, "--format")

  @doc false
  # `--split train,val` → `["train", "val"]`, checked against the known splits.
  @spec splits(String.t() | nil) :: {:ok, [String.t()] | nil} | {:error, String.t()}
  def splits(nil), do: {:ok, nil}

  def splits(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn split, {:ok, acc} ->
      case lookup(@splits, split, "--split") do
        {:ok, split} -> {:cont, {:ok, [split | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "--split needs at least one split"}
      {:ok, splits} -> {:ok, Enum.reverse(splits)}
      error -> error
    end
  end

  @doc false
  # The `budget:` option from `--budget-cost`, `--budget-tokens` and
  # `--budget-samples`; `nil` without any.
  @spec budget(keyword()) :: keyword() | nil
  def budget(opts) do
    case [
           max_cost: opts[:budget_cost],
           max_tokens: opts[:budget_tokens],
           max_samples: opts[:budget_samples]
         ]
         |> Enum.reject(fn {_key, value} -> is_nil(value) end) do
      [] -> nil
      budget -> budget
    end
  end

  @doc false
  # Every `--tag` (repeatable, each possibly comma-separated), as strings.
  @spec tags(keyword()) :: [String.t()] | nil
  def tags(opts) do
    case opts
         |> Keyword.get_values(:tag)
         |> Enum.flat_map(&String.split(&1, ",", trim: true))
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      tags -> tags
    end
  end

  @doc false
  # The `Nous.Eval.Compare` gate from `--gate`, `--margin`, `--max-error-rate`.
  @spec gate(keyword()) :: {:ok, map()} | {:error, String.t()}
  def gate(opts) do
    with {:ok, metrics} <- metrics(Keyword.get(opts, :gate)),
         {:ok, margin} <- unit(opts, :margin, 0.0, "--margin"),
         {:ok, max_error_rate} <- unit(opts, :max_error_rate, 0.0, "--max-error-rate") do
      {:ok, %{metrics: metrics, margin: margin, max_error_rate: max_error_rate}}
    end
  end

  defp metrics(nil), do: {:ok, [:pass_rate]}

  defp metrics(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Metric.parse(name) do
        {:ok, metric} ->
          {:cont, {:ok, [metric | acc]}}

        {:error, _} ->
          {:halt,
           {:error,
            "unknown --gate metric #{inspect(name)}; expected pass_rate, case_score or scorer:NAME"}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "--gate needs at least one metric"}
      {:ok, metrics} -> {:ok, metrics |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp unit(opts, key, default, flag) do
    case Keyword.get(opts, key, default) do
      value when value >= 0 and value < 1 -> {:ok, value / 1}
      value -> {:error, "#{flag} must be in [0, 1), got #{value}"}
    end
  end

  @doc false
  @spec label(String.t() | nil, String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def label(nil, _flag), do: {:ok, nil}

  def label(label, flag) do
    case Store.validate_label(label) do
      :ok -> {:ok, label}
      {:error, _} -> {:error, "invalid #{flag} #{inspect(label)}: use a-z, 0-9, '.', '_', '-'"}
    end
  end

  # ── stores ─────────────────────────────────────────────────────────────────

  @doc false
  # `file:DIR`, `sqlite:PATH` or `duckdb:PATH` → `{module, state, spec}`.
  @spec open_store(String.t() | nil) ::
          {:ok, {module(), term(), String.t()}} | {:error, String.t()}
  def open_store(nil), do: open_store(@default_store)

  def open_store(spec) do
    with {:ok, {module, init_opts}} <- store_spec(spec) do
      case module.init(init_opts) do
        {:ok, state} -> {:ok, {module, state, spec}}
        {:error, reason} -> {:error, "cannot open store #{spec}: #{describe(reason)}"}
      end
    end
  end

  @doc false
  # `file:DIR`, `sqlite:PATH` or `duckdb:PATH` → `{module, init_opts}`,
  # without opening the store.
  @spec store_spec(String.t()) :: {:ok, {module(), keyword()}} | {:error, String.t()}
  def store_spec(spec) do
    with [kind, location] when location != "" <- String.split(spec, ":", parts: 2),
         {:ok, {module, key}} <- lookup(@stores, kind, "store kind") do
      {:ok, {module, [{key, location}]}}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         "invalid --store #{inspect(spec)}: expected file:DIR, sqlite:PATH or duckdb:PATH"}
    end
  end

  @doc false
  # A run by id, or the run a label points at (`baseline:LABEL`).
  @spec fetch_run({module(), term(), String.t()}, String.t()) ::
          {:ok, Run.t()} | {:error, String.t()}
  def fetch_run(store, "baseline:" <> label), do: baseline_run(store, label)

  def fetch_run({module, state, spec}, id) do
    with :ok <- valid_run_id(id) do
      case module.get_run(state, id) do
        {:ok, run} -> {:ok, run}
        {:error, :not_found} -> {:error, "no run #{id} in #{spec}"}
        {:error, reason} -> {:error, "cannot read run #{id}: #{describe(reason)}"}
      end
    end
  end

  @doc false
  @spec baseline_run({module(), term(), String.t()}, String.t()) ::
          {:ok, Run.t()} | {:error, String.t()}
  def baseline_run({module, state, spec} = store, label) do
    with {:ok, label} <- label(label, "baseline label") do
      case module.get_baseline(state, label) do
        {:ok, %{run_id: id}} -> fetch_run(store, id)
        {:error, :not_found} -> {:error, "baseline #{inspect(label)} is not set in #{spec}"}
        {:error, reason} -> {:error, "cannot read baseline #{label}: #{describe(reason)}"}
      end
    end
  end

  defp valid_run_id(id) do
    case Store.validate_run_id(id) do
      :ok -> :ok
      {:error, _} -> {:error, "invalid run id #{inspect(id)}"}
    end
  end

  @doc false
  @spec put_run({module(), term(), String.t()}, Run.t()) :: :ok | {:error, String.t()}
  def put_run({module, state, spec}, run) do
    case module.put_run(state, run) do
      {:ok, _state} ->
        Mix.shell().info("Stored run #{run.id} in #{spec}")

      {:error, reason} ->
        {:error, "cannot store run #{run.id} in #{spec}: #{describe(reason)}"}
    end
  end

  @doc false
  @spec set_baseline({module(), term(), String.t()}, String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def set_baseline({module, state, spec}, label, run_id) do
    with :ok <- valid_run_id(run_id) do
      case module.put_baseline(state, label, run_id) do
        {:ok, _state} -> Mix.shell().info("Baseline #{label} -> #{run_id} (#{spec})")
        {:error, :not_found} -> {:error, "no run #{run_id} in #{spec}"}
        {:error, reason} -> {:error, "cannot set baseline #{label}: #{describe(reason)}"}
      end
    end
  end

  # ── reports & exit codes ───────────────────────────────────────────────────

  @doc false
  # Prints, or writes to `path`, the rendered reports.
  @spec emit([Run.t() | Compare.t()], atom(), String.t() | nil) :: :ok | {:error, String.t()}
  def emit(subjects, format, path) do
    text =
      subjects
      |> Enum.map(&Reporter.render(&1, format: format))
      |> Enum.intersperse("\n")
      |> IO.iodata_to_binary()

    case path do
      nil ->
        Mix.shell().info(text)

      path ->
        case File.write(path, text) do
          :ok -> Mix.shell().info("Wrote the report to #{path}")
          {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
        end
    end
  end

  @doc false
  # Why a run cannot pass a gate on its own: aborted, budget exhausted, or
  # more scorer errors than tolerated. Each is an operational failure (exit
  # 2): its results are incomplete or untrustworthy, so it must not read as
  # a pass or a mere regression.
  @spec problems(Run.t(), float()) :: [String.t()]
  def problems(%Run{} = run, max_error_rate) do
    totals = Map.get(run.summary, "totals", %{})
    error_rate = totals["error_rate"]

    [
      run.status == :aborted &&
        "the run was aborted (#{Map.get(run.metadata, :abort_reason, "unknown reason")})",
      run.status == :budget_exhausted &&
        "the run budget was exhausted (#{exhausted(run)}); " <>
          "#{get_in(totals, ["verdicts", "none"]) || 0} samples did not run",
      totals["samples"] == 0 && "the run has no samples",
      (is_number(error_rate) and error_rate > max_error_rate) &&
        "scorer error rate #{Reporter.pct(error_rate)} exceeds --max-error-rate " <>
          Reporter.pct(max_error_rate)
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp exhausted(%Run{budget: %{exhausted: reason}}) when reason != nil, do: reason
  defp exhausted(_run), do: "a model-graded scorer had no budget left"

  @doc false
  # The exit code of a run and an optional comparison, printing why.
  @spec exit_code(Run.t(), Compare.t() | nil, float()) :: 0..2
  def exit_code(run, comparison, max_error_rate) do
    problems = problems(run, max_error_rate)
    Enum.each(problems, &Mix.shell().error("Operational error: " <> &1))

    compare_code =
      case comparison do
        nil -> 0
        %Compare{verdict: :pass} -> 0
        %Compare{verdict: :regression} -> 1
        %Compare{verdict: :error} -> 2
      end

    code = if problems == [], do: compare_code, else: 2
    Mix.shell().info("Exit status #{code} (#{meaning(code)})")
    code
  end

  defp meaning(0), do: "pass"
  defp meaning(1), do: "regression"
  defp meaning(2), do: "operational error"

  @doc false
  # Human text for the error terms of `Nous.Eval.run/2` and the stores.
  @spec describe(term()) :: String.t()
  def describe(message) when is_binary(message), do: message
  def describe(:no_cases), do: "no cases to run (check --split and --tag)"

  def describe({:unknown_price, model}),
    do:
      "budget refused: no known price for #{model}, so --budget-cost cannot be enforced " <>
        "(add it with config :nous, :model_prices)"

  def describe({:scorer_init_failed, module, reason}),
    do: "scorer #{inspect(module)} has invalid options: #{inspect(reason)}"

  def describe({:invalid_option, key, value}), do: "invalid #{key}: #{inspect(value)}"
  def describe({:unknown_options, keys}), do: "unknown options #{inspect(keys)}"
  def describe({:missing_cases, ids}), do: "the task no longer has cases #{Enum.join(ids, ", ")}"
  def describe({:store, reason}), do: "store error: #{describe(reason)}"

  def describe({:store_put_failed, reason, run}),
    do: "run #{run.id} finished but could not be stored: #{describe(reason)}"

  def describe({:dataset_changed, %{baseline: a, candidate: b}}),
    do:
      "the runs used different datasets (#{a} vs #{b}); " <>
        "pass --allow-dataset-change to compare their common cases"

  def describe(:trace_handler_detached), do: "the trace collector's handler is not attached"
  def describe(other), do: inspect(other)

  defp lookup(table, key, name) do
    case Map.fetch(table, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         "unknown #{name} #{inspect(key)}; expected one of #{table |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}
    end
  end
end
