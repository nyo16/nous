defmodule Nous.Eval.Store do
  @moduledoc """
  Storage behaviour for eval runs and baseline labels.

  Nous ships three implementations: `Nous.Eval.Store.File` (the default; a
  directory of JSON files, no dependencies), `Nous.Eval.Store.SQLite`
  (`exqlite`) and `Nous.Eval.Store.DuckDB` (`duckdbex`). A backend of your
  own is a module with `@behaviour Nous.Eval.Store`; hold it to the same
  contract with `Nous.Eval.Store.Conformance`.

  ## The state contract

  As with `Nous.Memory.Store`, `init/1` returns an opaque `state` that is
  threaded back into every other callback, and callbacks that write return
  `{:ok, new_state}` even when the term never changes.

  ## Records

  Runs are immutable: `put_run/2` refuses an id that is already stored, so a
  baseline can never silently start pointing at different results. Store
  runs as `Nous.Eval.Codec.encode_run_json/1` text and read them back with
  `Nous.Eval.Codec.decode_run_json/1`; that is what makes records written by
  an older Nous readable and records written by a newer one refused with
  `{:error, {:unsupported_schema_version, v}}`.

  ## Baselines

  A baseline label (`"main"`, `"release-0.20"`) names the run a regression
  gate compares against. Labels are **append-only**: `put_baseline/3` adds
  an entry, `get_baseline/2` returns the label's latest entry, and
  `list_baselines/2` returns its whole history, so who-pointed-what-when is
  never lost and a rollback is just another entry. A label that was never
  set is `{:error, :not_found}`; a backend MUST NOT fall back to the latest
  run, because a gate that silently compares against whatever ran last
  passes every regression.

  ## Identifiers

  Run ids and labels end up in file names and SQL parameters, so every
  backend validates them with `validate_run_id/1` and `validate_label/1`
  before touching storage. Both are lowercase so that two ids can never
  collide on a case-insensitive file system.
  """

  alias Nous.Eval.Run
  alias Nous.Eval.Store.{Baseline, RunSummary}

  @typedoc """
  Filters for `list_runs/2`:

    * `:task` - the run's task (string)
    * `:status` - `:completed | :budget_exhausted | :aborted`
    * `:since` / `:until` - `DateTime`; `started_at >= since` and
      `started_at < until`. A run without `started_at` never matches a time
      filter
    * `:limit` - at most this many summaries (non-negative integer)
  """
  @type filters :: [
          task: String.t(),
          status: Run.status(),
          since: DateTime.t(),
          until: DateTime.t(),
          limit: non_neg_integer()
        ]

  @doc """
  Open or create the backend and return its opaque state. Return
  `{:error, reason}` rather than raising when it is unreachable or
  misconfigured.
  """
  @callback init(opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Persist `run`. Returns `{:error, :already_exists}` when a run with the same
  id is stored, `{:error, {:invalid_run_id, id}}` for an id that fails
  `validate_run_id/1`.
  """
  @callback put_run(state :: term(), run :: Run.t()) :: {:ok, term()} | {:error, term()}

  @doc "Fetch a run by id. `{:error, :not_found}` when absent."
  @callback get_run(state :: term(), id :: String.t()) ::
              {:ok, Run.t()} | {:error, :not_found | term()}

  @doc """
  Summaries of the stored runs matching `filters`, newest `started_at`
  first (runs without one last; ties in reverse insertion order). Never
  decodes samples or traces. An unknown filter or a value of the wrong type
  is `{:error, {:invalid_filter, filter}}`.
  """
  @callback list_runs(state :: term(), filters :: filters()) ::
              {:ok, [RunSummary.t()]} | {:error, term()}

  @doc """
  Point `label` at `run_id` by appending a history entry stamped with the
  current time. The run must be stored: `{:error, :not_found}` otherwise.
  """
  @callback put_baseline(state :: term(), label :: String.t(), run_id :: String.t()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  The latest entry for `label`. `{:error, :not_found}` when the label was
  never set; never a fallback to the latest run.
  """
  @callback get_baseline(state :: term(), label :: String.t()) ::
              {:ok, Baseline.t()} | {:error, :not_found | term()}

  @doc "Every entry for `label`, newest first. `{:ok, []}` when never set."
  @callback list_baselines(state :: term(), label :: String.t()) ::
              {:ok, [Baseline.t()]} | {:error, term()}

  @run_id ~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/
  @label ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @statuses [:completed, :budget_exhausted, :aborted]

  @doc """
  Checks a run id: 1-128 characters of `a-z`, `0-9`, `.`, `_`, `-`, starting
  with a letter or digit. That excludes path separators, `..`, and anything
  a file system or shell would treat specially.
  """
  @spec validate_run_id(term()) :: :ok | {:error, {:invalid_run_id, term()}}
  def validate_run_id(id) when is_binary(id) do
    if Regex.match?(@run_id, id), do: :ok, else: {:error, {:invalid_run_id, id}}
  end

  def validate_run_id(id), do: {:error, {:invalid_run_id, id}}

  @doc """
  Checks a baseline label: 1-64 characters of `a-z`, `0-9`, `.`, `_`, `-`,
  starting with a letter or digit.
  """
  @spec validate_label(term()) :: :ok | {:error, {:invalid_label, term()}}
  def validate_label(label) when is_binary(label) do
    if Regex.match?(@label, label), do: :ok, else: {:error, {:invalid_label, label}}
  end

  def validate_label(label), do: {:error, {:invalid_label, label}}

  @doc """
  Validates `list_runs/2` filters, returning them as a map.

  Backends call this first so an unknown or mistyped filter fails instead
  of being ignored (an ignored `:status` filter would list every run).
  """
  @spec validate_filters(term()) :: {:ok, map()} | {:error, {:invalid_filter, term()}}
  def validate_filters(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, %{}}, fn filter, {:ok, acc} ->
      case filter do
        {key, value} when is_atom(key) ->
          if valid_filter?(key, value),
            do: {:cont, {:ok, Map.put(acc, key, value)}},
            else: {:halt, {:error, {:invalid_filter, filter}}}

        other ->
          {:halt, {:error, {:invalid_filter, other}}}
      end
    end)
  end

  def validate_filters(filters), do: {:error, {:invalid_filter, filters}}

  defp valid_filter?(:task, task), do: is_binary(task)
  defp valid_filter?(:status, status), do: status in @statuses
  defp valid_filter?(:since, %DateTime{}), do: true
  defp valid_filter?(:until, %DateTime{}), do: true
  defp valid_filter?(:limit, limit), do: is_integer(limit) and limit >= 0
  defp valid_filter?(_key, _value), do: false
end
