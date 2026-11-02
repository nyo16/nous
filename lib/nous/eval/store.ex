defmodule Nous.Eval.Store do
  @moduledoc """
  Storage behaviour for eval runs, baseline labels and judge calibrations.

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

  ## Judge calibrations

  The optional `put_calibration/3` / `get_calibration/2` keep
  `Nous.Eval.JudgeCalibration.Result`s keyed by the judge fingerprint id
  (`Nous.Eval.Scorers.Judge.fingerprint_id/1`), stored as
  `Nous.Eval.Codec.encode_calibration_json/1` text. A newer result for the
  same id replaces the older one for `get_calibration/2`. The runner looks a
  judge's calibration up before it grades, so a judge with
  `require_calibration:` refuses to run against a store without them.

  ## Profiles

  The optional profile callbacks keep `Nous.Profile`s, the versioned prompt
  text an optimizer produces and a human promotes:

    * `put_profile/2` stores a profile **by id** (its content hash).
      Profiles are immutable: putting an id that is already stored returns
      the stored profile unchanged (the first put's `name`, `version`,
      `parent_id` and `provenance` win), and putting it under another
      `name` is `{:error, {:name_conflict, stored_name}}`. A named profile
      gets the next `version` under its name on its first put (1, 2, ...);
      a `version` on the given struct is ignored.
    * `get_profile/2` resolves a `t:profile_ref/0`: `{:id, id}`,
      `{:version, name, n}` or `{:label, name, label}` (the label's latest
      entry). There is no "latest version" ref, and an unknown ref is
      `{:error, :not_found}`, never a fallback.
    * `put_profile_label/4` points `label` of profile `name` at a stored
      profile of that name; labels are append-only like baselines and
      `list_profile_labels/3` returns the history.

  Every read decodes the stored record with
  `Nous.Eval.Codec.decode_profile_json/1`, which recomputes the content hash:
  a record whose text no longer matches its id is refused
  (`:id_mismatch`), and one that does not match the ref it was read by is
  `{:error, {:corrupt_profile, ref}}` (see `check_profile_ref/2`). The hash
  catches corruption and naive edits, not a writer who re-hashes: write
  access to the store is control over the prompts of every agent that
  loads from it.

  ## Retention

  The optional `delete_runs_before/3` deletes one task's runs that started
  before a cutoff. `Nous.Eval.Online` stores sampled production traffic as
  runs of task `"online:<instance>"` and uses it to enforce its required
  retention policy, so it refuses to start with a finite retention against
  a store without it. Retention is a privacy policy and wins over a
  baseline label: history entries stay, but `get_run/2` on a deleted run is
  `{:error, :not_found}`. Backends check the arguments with
  `validate_retention/2`.

  ## Identifiers

  Run ids, labels and profile names end up in file names and SQL
  parameters, so every backend validates them with `validate_run_id/1`,
  `validate_label/1` and `validate_profile_name/1` before touching storage.
  All are lowercase so that two ids can never collide on a case-insensitive
  file system. Calibration keys go through `validate_calibration/2`,
  profile refs through `validate_profile_ref/1`.
  """

  alias Nous.Eval.{Codec, JudgeCalibration}
  alias Nous.Eval.Run
  alias Nous.Eval.Store.{Baseline, ProfileLabel, RunSummary}
  alias Nous.Profile

  @typedoc """
  How `get_profile/2` finds a profile: by content hash, by `name` and
  store-assigned version, or by the latest entry of a label.
  """
  @type profile_ref ::
          {:id, String.t()}
          | {:version, String.t(), pos_integer()}
          | {:label, String.t(), String.t()}

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

  @doc """
  Store `result` as the calibration of the judge with `fingerprint_id`.
  Check the arguments with `validate_calibration/2` first. Optional.
  """
  @callback put_calibration(
              state :: term(),
              fingerprint_id :: String.t(),
              result :: JudgeCalibration.Result.t()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  The most recently stored calibration for `fingerprint_id`.
  `{:error, :not_found}` when there is none; never a calibration of another
  fingerprint. Optional.
  """
  @callback get_calibration(state :: term(), fingerprint_id :: String.t()) ::
              {:ok, JudgeCalibration.Result.t()} | {:error, :not_found | term()}

  @doc """
  Store `profile` (see "Profiles"). Returns the stored profile, with the
  `version` assigned under its name, and the new state. Check it with
  `validate_profile/1` first. Optional.
  """
  @callback put_profile(state :: term(), profile :: Profile.t()) ::
              {:ok, Profile.t(), term()} | {:error, term()}

  @doc """
  The profile `ref` resolves to, verified against its id and the ref.
  `{:error, :not_found}` when nothing matches. Optional.
  """
  @callback get_profile(state :: term(), ref :: profile_ref()) ::
              {:ok, Profile.t()} | {:error, :not_found | term()}

  @doc "Every stored profile named `name`, newest version first. Optional."
  @callback list_profiles(state :: term(), name :: String.t()) ::
              {:ok, [Profile.t()]} | {:error, term()}

  @doc """
  Point `label` of profile `name` at `profile_id` by appending a history
  entry stamped with the current time. The profile must be stored under
  `name`: `{:error, :not_found}` otherwise. Optional.
  """
  @callback put_profile_label(
              state :: term(),
              name :: String.t(),
              label :: String.t(),
              profile_id :: String.t()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Every entry for `label` of profile `name`, newest first. `{:ok, []}` when
  never set. Optional.
  """
  @callback list_profile_labels(state :: term(), name :: String.t(), label :: String.t()) ::
              {:ok, [ProfileLabel.t()]} | {:error, term()}

  @doc """
  Delete every stored run whose `task` equals `task` and whose `started_at`
  is before `before` (strictly earlier). Runs without `started_at` and runs
  of other tasks are never deleted. Baseline history entries are kept even
  when they point at a deleted run (`get_run/2` on it is then
  `{:error, :not_found}`): retention is a privacy policy and wins over a
  label. Returns the number of runs deleted. Check the arguments with
  `validate_retention/2` first. Optional; `Nous.Eval.Online` refuses to
  start with a finite retention against a store without it.
  """
  @callback delete_runs_before(state :: term(), task :: String.t(), before :: DateTime.t()) ::
              {:ok, non_neg_integer(), term()} | {:error, term()}

  @optional_callbacks put_calibration: 3,
                      get_calibration: 2,
                      put_profile: 2,
                      get_profile: 2,
                      list_profiles: 2,
                      put_profile_label: 4,
                      list_profile_labels: 3,
                      delete_runs_before: 3

  @run_id ~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/
  @label ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @fingerprint_id ~r/\Asha256:[0-9a-f]{64}\z/
  @statuses [:completed, :budget_exhausted, :aborted]

  @doc """
  Checks a calibration before it is stored or looked up: `fingerprint_id`
  must be a `"sha256:"` content hash (lowercase hex), and `result`, when
  given, a `Nous.Eval.JudgeCalibration.Result` for that same fingerprint.
  """
  @spec validate_calibration(term(), JudgeCalibration.Result.t() | nil) ::
          :ok
          | {:error,
             {:invalid_fingerprint_id, term()}
             | :fingerprint_mismatch
             | {:invalid_calibration, term()}}
  def validate_calibration(fingerprint_id, result \\ nil) do
    cond do
      not (is_binary(fingerprint_id) and Regex.match?(@fingerprint_id, fingerprint_id)) ->
        {:error, {:invalid_fingerprint_id, fingerprint_id}}

      is_nil(result) ->
        :ok

      not is_struct(result, JudgeCalibration.Result) ->
        {:error, {:invalid_calibration, result}}

      result.fingerprint_id != fingerprint_id ->
        {:error, :fingerprint_mismatch}

      true ->
        :ok
    end
  end

  @doc """
  Checks the arguments of `delete_runs_before/3`: `task` must be a non-empty
  string and `before` a `DateTime`.
  """
  @spec validate_retention(term(), term()) ::
          :ok | {:error, {:invalid_argument, {:task | :before, term()}}}
  def validate_retention(task, before) do
    cond do
      not (is_binary(task) and task != "") -> {:error, {:invalid_argument, {:task, task}}}
      not is_struct(before, DateTime) -> {:error, {:invalid_argument, {:before, before}}}
      true -> :ok
    end
  end

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
  Checks a profile name: the `Nous.Profile` name grammar, 1-64 characters
  of `a-z`, `0-9`, `.`, `_`, `-`, starting with a letter or digit.
  """
  @spec validate_profile_name(term()) :: :ok | {:error, {:invalid_profile_name, term()}}
  def validate_profile_name(name) when is_binary(name) do
    if Regex.match?(@label, name), do: :ok, else: {:error, {:invalid_profile_name, name}}
  end

  def validate_profile_name(name), do: {:error, {:invalid_profile_name, name}}

  @doc "Checks a profile id: `\"sha256:\"` and 64 lowercase hex digits."
  @spec validate_profile_id(term()) :: :ok | {:error, {:invalid_profile_id, term()}}
  def validate_profile_id(id) do
    if is_binary(id) and Regex.match?(@fingerprint_id, id),
      do: :ok,
      else: {:error, {:invalid_profile_id, id}}
  end

  @doc """
  Checks a `t:profile_ref/0`: its shape, then the id, name, version or
  label in it.
  """
  @spec validate_profile_ref(term()) :: :ok | {:error, term()}
  def validate_profile_ref({:id, id}), do: validate_profile_id(id)

  def validate_profile_ref({:version, name, version} = ref) do
    with :ok <- validate_profile_name(name) do
      if is_integer(version) and version > 0,
        do: :ok,
        else: {:error, {:invalid_profile_ref, ref}}
    end
  end

  def validate_profile_ref({:label, name, label}) do
    with :ok <- validate_profile_name(name), do: validate_label(label)
  end

  def validate_profile_ref(ref), do: {:error, {:invalid_profile_ref, ref}}

  @doc """
  Checks a profile before it is stored: a `Nous.Profile` that passes every
  check that needs no agent, with a declared `id` equal to its content hash
  (`Nous.Errors.ProfileError` `:id_mismatch` otherwise). Returns it with the
  id filled in.
  """
  @spec validate_profile(term()) :: {:ok, Profile.t()} | {:error, term()}
  def validate_profile(%Profile{} = profile) do
    with {:ok, encoded} <- Codec.encode_profile(profile),
         {:ok, decoded} <- Profile.from_map(encoded) do
      {:ok, decoded}
    end
  end

  def validate_profile(other), do: {:error, {:invalid_profile, other}}

  @doc """
  Checks that `profile`, read back by `ref`, is what `ref` names: the same
  id, the same name and version, or the label's name.
  `{:error, {:corrupt_profile, ref}}` otherwise, e.g. a record copied over
  another one.
  """
  @spec check_profile_ref(Profile.t(), profile_ref()) ::
          :ok | {:error, {:corrupt_profile, profile_ref()}}
  def check_profile_ref(%Profile{id: id}, {:id, id}), do: :ok
  def check_profile_ref(%Profile{name: name, version: v}, {:version, name, v}), do: :ok
  def check_profile_ref(%Profile{name: name}, {:label, name, _label}), do: :ok
  def check_profile_ref(_profile, ref), do: {:error, {:corrupt_profile, ref}}

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
