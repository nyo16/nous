if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Eval.Store.DuckDB do
    @moduledoc """
    DuckDB-backed `Nous.Eval.Store` using `duckdbex`.

        {:ok, store} = Nous.Eval.Store.DuckDB.init(path: "priv/eval.duckdb")

    Same layout as `Nous.Eval.Store.SQLite`: runs are rows of
    `nous_eval_runs` holding the `Nous.Eval.Codec` JSON text of the run
    (`payload`) and of its summary (`summary`), baselines are rows of
    `nous_eval_baselines`, only ever inserted, judge calibrations rows of
    `nous_eval_calibrations` (latest row per fingerprint id wins), profiles
    rows of `nous_eval_profiles` (unique by `id` and by `(name, version)`)
    and profile labels rows of `nous_eval_profile_labels`, only ever
    inserted. Payloads are plain JSON text, so DuckDB's `json_extract` can
    query stored runs directly.

    ## Options

      * `:path` - database file path (default: `":memory:"`)
    """

    @behaviour Nous.Eval.Store

    alias Nous.Eval.{Codec, Run, Store}
    alias Nous.Eval.Store.{Baseline, ProfileLabel, RunSummary}

    @schema [
      "CREATE SEQUENCE IF NOT EXISTS nous_eval_runs_seq",
      """
      CREATE TABLE IF NOT EXISTS nous_eval_runs (
        seq BIGINT PRIMARY KEY DEFAULT nextval('nous_eval_runs_seq'),
        id VARCHAR NOT NULL UNIQUE,
        task VARCHAR,
        status VARCHAR NOT NULL,
        started_at_us BIGINT,
        summary VARCHAR NOT NULL,
        payload VARCHAR NOT NULL
      )
      """,
      "CREATE SEQUENCE IF NOT EXISTS nous_eval_baselines_seq",
      """
      CREATE TABLE IF NOT EXISTS nous_eval_baselines (
        seq BIGINT PRIMARY KEY DEFAULT nextval('nous_eval_baselines_seq'),
        label VARCHAR NOT NULL,
        run_id VARCHAR NOT NULL,
        set_at VARCHAR NOT NULL
      )
      """,
      "CREATE SEQUENCE IF NOT EXISTS nous_eval_calibrations_seq",
      """
      CREATE TABLE IF NOT EXISTS nous_eval_calibrations (
        seq BIGINT PRIMARY KEY DEFAULT nextval('nous_eval_calibrations_seq'),
        fingerprint_id VARCHAR NOT NULL,
        payload VARCHAR NOT NULL
      )
      """,
      "CREATE SEQUENCE IF NOT EXISTS nous_eval_profiles_seq",
      """
      CREATE TABLE IF NOT EXISTS nous_eval_profiles (
        seq BIGINT PRIMARY KEY DEFAULT nextval('nous_eval_profiles_seq'),
        id VARCHAR NOT NULL UNIQUE,
        name VARCHAR,
        version BIGINT,
        payload VARCHAR NOT NULL,
        UNIQUE (name, version)
      )
      """,
      "CREATE SEQUENCE IF NOT EXISTS nous_eval_profile_labels_seq",
      """
      CREATE TABLE IF NOT EXISTS nous_eval_profile_labels (
        seq BIGINT PRIMARY KEY DEFAULT nextval('nous_eval_profile_labels_seq'),
        name VARCHAR NOT NULL,
        label VARCHAR NOT NULL,
        profile_id VARCHAR NOT NULL,
        set_at VARCHAR NOT NULL
      )
      """
    ]

    @impl true
    def init(opts) do
      path = Keyword.get(opts, :path, ":memory:")

      with {:ok, db} <- Duckdbex.open(path),
           {:ok, conn} <- Duckdbex.connection(db),
           :ok <- create_schema(conn) do
        {:ok, %{db: db, conn: conn}}
      end
    end

    @impl true
    def put_run(%{conn: conn} = state, %Run{id: id} = run) do
      with :ok <- Store.validate_run_id(id),
           {:ok, payload} <- Codec.encode_run_json(run),
           {:ok, summary} <- Codec.encode_summary_json(RunSummary.from_run(run)) do
        params = [
          id,
          run.task,
          Atom.to_string(run.status),
          started_at_us(run.started_at),
          summary,
          payload
        ]

        transaction(conn, fn ->
          case query(conn, "SELECT 1 FROM nous_eval_runs WHERE id = $1", [id]) do
            {:ok, []} ->
              with {:ok, _} <-
                     query(
                       conn,
                       """
                       INSERT INTO nous_eval_runs
                         (id, task, status, started_at_us, summary, payload)
                       VALUES ($1, $2, $3, $4, $5, $6)
                       """,
                       params
                     ),
                   do: {:ok, state}

            {:ok, _rows} ->
              {:error, :already_exists}

            {:error, _} = error ->
              error
          end
        end)
      end
    end

    @impl true
    def get_run(%{conn: conn}, id) do
      with :ok <- Store.validate_run_id(id) do
        case query(conn, "SELECT payload FROM nous_eval_runs WHERE id = $1", [id]) do
          {:ok, [[payload]]} -> Codec.decode_run_json(payload)
          {:ok, []} -> {:error, :not_found}
          {:error, _} = error -> error
        end
      end
    end

    @impl true
    def list_runs(%{conn: conn}, filters) do
      with {:ok, filters} <- Store.validate_filters(filters) do
        {where, params} = where_clause(filters)

        sql =
          "SELECT summary FROM nous_eval_runs" <>
            where <>
            " ORDER BY started_at_us IS NULL, started_at_us DESC, seq DESC" <>
            limit_clause(filters[:limit])

        with {:ok, rows} <- query(conn, sql, params) do
          decode_all(rows, fn [summary] -> Codec.decode_summary_json(summary) end)
        end
      end
    end

    @impl true
    def put_baseline(%{conn: conn} = state, label, run_id) do
      with :ok <- Store.validate_label(label),
           :ok <- Store.validate_run_id(run_id) do
        transaction(conn, fn ->
          case query(conn, "SELECT 1 FROM nous_eval_runs WHERE id = $1", [run_id]) do
            {:ok, []} ->
              {:error, :not_found}

            {:ok, _rows} ->
              with {:ok, _} <-
                     query(
                       conn,
                       "INSERT INTO nous_eval_baselines (label, run_id, set_at) VALUES ($1, $2, $3)",
                       [label, run_id, DateTime.to_iso8601(DateTime.utc_now())]
                     ),
                   do: {:ok, state}

            {:error, _} = error ->
              error
          end
        end)
      end
    end

    @impl true
    def get_baseline(%{conn: conn}, label) do
      with :ok <- Store.validate_label(label),
           {:ok, rows} <- baselines(conn, label, " LIMIT 1") do
        case rows do
          [entry] -> {:ok, entry}
          [] -> {:error, :not_found}
        end
      end
    end

    @impl true
    def list_baselines(%{conn: conn}, label) do
      with :ok <- Store.validate_label(label), do: baselines(conn, label, "")
    end

    @impl true
    def put_calibration(%{conn: conn} = state, fingerprint_id, result) do
      with :ok <- Store.validate_calibration(fingerprint_id, result),
           {:ok, payload} <- Codec.encode_calibration_json(result),
           {:ok, _} <-
             query(
               conn,
               "INSERT INTO nous_eval_calibrations (fingerprint_id, payload) VALUES ($1, $2)",
               [fingerprint_id, payload]
             ) do
        {:ok, state}
      end
    end

    @impl true
    def get_calibration(%{conn: conn}, fingerprint_id) do
      with :ok <- Store.validate_calibration(fingerprint_id),
           {:ok, rows} <-
             query(
               conn,
               """
               SELECT payload FROM nous_eval_calibrations
               WHERE fingerprint_id = $1 ORDER BY seq DESC LIMIT 1
               """,
               [fingerprint_id]
             ) do
        case rows do
          [[payload]] -> Codec.decode_calibration_json(payload)
          [] -> {:error, :not_found}
        end
      end
    end

    @impl true
    def put_profile(%{conn: conn} = state, profile) do
      with {:ok, profile} <- Store.validate_profile(profile) do
        transaction(conn, fn ->
          with {:ok, rows} <-
                 query(conn, "SELECT payload FROM nous_eval_profiles WHERE id = $1", [profile.id]) do
            case rows do
              [[payload]] -> stored_profile(state, profile, payload)
              [] -> insert_profile(state, profile)
            end
          end
        end)
        |> case do
          {:ok, {stored, state}} -> {:ok, stored, state}
          error -> error
        end
      end
    end

    @impl true
    def get_profile(%{conn: conn}, ref) do
      with :ok <- Store.validate_profile_ref(ref),
           {:ok, rows} <- profile_rows(conn, ref) do
        case rows do
          [[payload]] -> decode_profile(payload, ref)
          [] -> {:error, :not_found}
        end
      end
    end

    @impl true
    def list_profiles(%{conn: conn}, name) do
      with :ok <- Store.validate_profile_name(name),
           {:ok, rows} <-
             query(
               conn,
               "SELECT version, payload FROM nous_eval_profiles WHERE name = $1 ORDER BY version DESC",
               [name]
             ) do
        decode_all(rows, fn [version, payload] ->
          decode_profile(payload, {:version, name, version})
        end)
      end
    end

    @impl true
    def put_profile_label(%{conn: conn} = state, name, label, profile_id) do
      with :ok <- Store.validate_profile_name(name),
           :ok <- Store.validate_label(label),
           :ok <- Store.validate_profile_id(profile_id) do
        transaction(conn, fn ->
          case query(
                 conn,
                 "SELECT 1 FROM nous_eval_profiles WHERE id = $1 AND name = $2",
                 [profile_id, name]
               ) do
            {:ok, []} ->
              {:error, :not_found}

            {:ok, _rows} ->
              with {:ok, _} <-
                     query(
                       conn,
                       """
                       INSERT INTO nous_eval_profile_labels (name, label, profile_id, set_at)
                       VALUES ($1, $2, $3, $4)
                       """,
                       [name, label, profile_id, DateTime.to_iso8601(DateTime.utc_now())]
                     ),
                   do: {:ok, state}

            {:error, _} = error ->
              error
          end
        end)
      end
    end

    @impl true
    def list_profile_labels(%{conn: conn}, name, label) do
      with :ok <- Store.validate_profile_name(name),
           :ok <- Store.validate_label(label),
           {:ok, rows} <-
             query(
               conn,
               """
               SELECT name, label, profile_id, set_at FROM nous_eval_profile_labels
               WHERE name = $1 AND label = $2 ORDER BY seq DESC
               """,
               [name, label]
             ) do
        decode_all(rows, &decode_profile_label/1)
      end
    end

    # -- retention (online eval) ---------------------------------------------

    # DuckDB answers a DELETE with a single `Count` row: the deleted rows.
    @impl true
    def delete_runs_before(%{conn: conn} = state, task, before) do
      sql = """
      DELETE FROM nous_eval_runs
      WHERE task = $1 AND started_at_us IS NOT NULL AND started_at_us < $2
      """

      with :ok <- Store.validate_retention(task, before),
           {:ok, count} <-
             transaction(conn, fn ->
               case query(conn, sql, [task, started_at_us(before)]) do
                 {:ok, [[count]]} when is_integer(count) and count >= 0 -> {:ok, count}
                 {:ok, other} -> {:error, {:unexpected_delete_result, other}}
                 {:error, _} = error -> error
               end
             end) do
        {:ok, count, state}
      end
    end

    # -- helpers -------------------------------------------------------------

    defp create_schema(conn) do
      Enum.reduce_while(@schema, :ok, fn sql, :ok ->
        case Duckdbex.query(conn, sql) do
          {:ok, _} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end

    defp stored_profile(state, profile, payload) do
      with {:ok, stored} <- decode_profile(payload, {:id, profile.id}) do
        if profile.name && stored.name != profile.name,
          do: {:error, {:name_conflict, stored.name}},
          else: {:ok, {stored, state}}
      end
    end

    defp insert_profile(state, %{name: nil} = profile) do
      write_profile(state, %{profile | version: nil})
    end

    defp insert_profile(%{conn: conn} = state, profile) do
      with {:ok, [[latest]]} <-
             query(
               conn,
               "SELECT COALESCE(MAX(version), 0) FROM nous_eval_profiles WHERE name = $1",
               [profile.name]
             ) do
        write_profile(state, %{profile | version: latest + 1})
      end
    end

    defp write_profile(%{conn: conn} = state, profile) do
      with {:ok, payload} <- Codec.encode_profile_json(profile),
           {:ok, _} <-
             query(
               conn,
               "INSERT INTO nous_eval_profiles (id, name, version, payload) VALUES ($1, $2, $3, $4)",
               [profile.id, profile.name, profile.version, payload]
             ) do
        {:ok, {profile, state}}
      end
    end

    defp profile_rows(conn, {:id, id}),
      do: query(conn, "SELECT payload FROM nous_eval_profiles WHERE id = $1", [id])

    defp profile_rows(conn, {:version, name, version}) do
      query(
        conn,
        "SELECT payload FROM nous_eval_profiles WHERE name = $1 AND version = $2",
        [name, version]
      )
    end

    # The label's latest entry, joined to the profile it names.
    defp profile_rows(conn, {:label, name, label}) do
      query(
        conn,
        """
        SELECT p.payload FROM nous_eval_profile_labels l
        JOIN nous_eval_profiles p ON p.id = l.profile_id
        WHERE l.name = $1 AND l.label = $2
        ORDER BY l.seq DESC LIMIT 1
        """,
        [name, label]
      )
    end

    defp decode_profile(payload, ref) do
      with {:ok, profile} <- Codec.decode_profile_json(payload),
           :ok <- Store.check_profile_ref(profile, ref),
           do: {:ok, profile}
    end

    defp decode_profile_label([name, label, profile_id, set_at] = row) do
      case DateTime.from_iso8601(set_at) do
        {:ok, at, _offset} ->
          {:ok, %ProfileLabel{name: name, label: label, profile_id: profile_id, set_at: at}}

        {:error, _} ->
          {:error, {:corrupt_profile_label, row}}
      end
    end

    # `suffix` is a literal from this module, never caller data.
    defp baselines(conn, label, suffix) do
      sql =
        "SELECT label, run_id, set_at FROM nous_eval_baselines WHERE label = $1 ORDER BY seq DESC" <>
          suffix

      with {:ok, rows} <- query(conn, sql, [label]) do
        decode_all(rows, &decode_baseline/1)
      end
    end

    defp decode_baseline([label, run_id, set_at]) do
      case DateTime.from_iso8601(set_at) do
        {:ok, at, _offset} -> {:ok, %Baseline{label: label, run_id: run_id, set_at: at}}
        {:error, _} -> {:error, {:corrupt_baseline_entry, [label, run_id, set_at]}}
      end
    end

    defp decode_all(rows, fun) do
      rows
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case fun.(row) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    end

    # Every filter value is bound as a parameter; only the literal column
    # fragments below are interpolated.
    defp where_clause(filters) do
      {clauses, params} =
        Enum.reduce(filters, {[], []}, fn
          {:task, task}, acc -> add_clause(acc, "task", "=", task)
          {:status, status}, acc -> add_clause(acc, "status", "=", Atom.to_string(status))
          {:since, since}, acc -> add_clause(acc, "started_at_us", ">=", started_at_us(since))
          {:until, until}, acc -> add_clause(acc, "started_at_us", "<", started_at_us(until))
          {:limit, _}, acc -> acc
        end)

      case clauses do
        [] -> {"", []}
        _ -> {" WHERE " <> Enum.join(Enum.reverse(clauses), " AND "), Enum.reverse(params)}
      end
    end

    defp add_clause({clauses, params}, column, op, value) do
      {["#{column} #{op} $#{length(params) + 1}" | clauses], [value | params]}
    end

    # `limit` was checked to be a non-negative integer by validate_filters/1.
    defp limit_clause(nil), do: ""
    defp limit_clause(limit) when is_integer(limit), do: " LIMIT #{limit}"

    defp started_at_us(nil), do: nil
    defp started_at_us(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

    defp query(conn, sql, params) do
      with {:ok, result} <- Duckdbex.query(conn, sql, params) do
        case Duckdbex.fetch_all(result) do
          rows when is_list(rows) -> {:ok, rows}
          {:error, _} = error -> error
        end
      end
    end

    # Commits on `{:ok, _}`, rolls back on anything else, including a raise.
    defp transaction(conn, fun) do
      with :ok <- Duckdbex.begin_transaction(conn) do
        try do
          case fun.() do
            {:ok, _} = ok ->
              with :ok <- Duckdbex.commit(conn), do: ok

            other ->
              _ = Duckdbex.rollback(conn)
              other
          end
        rescue
          e ->
            _ = Duckdbex.rollback(conn)
            reraise e, __STACKTRACE__
        end
      end
    end
  end
else
  defmodule Nous.Eval.Store.DuckDB do
    @moduledoc """
    DuckDB-backed eval store (unavailable).

    Add `{:duckdbex, "~> 0.7"}` to your dependencies to enable this store.
    """

    @behaviour Nous.Eval.Store

    @dialyzer {:nowarn_function,
               init: 1,
               put_run: 2,
               get_run: 2,
               list_runs: 2,
               put_baseline: 3,
               get_baseline: 2,
               list_baselines: 2,
               put_calibration: 3,
               get_calibration: 2,
               put_profile: 2,
               get_profile: 2,
               list_profiles: 2,
               put_profile_label: 4,
               list_profile_labels: 3,
               delete_runs_before: 3}

    @error {:error,
            "Duckdbex is not available. Add {:duckdbex, \"~> 0.7\"} to your dependencies."}

    @impl true
    def init(_opts), do: @error

    @impl true
    def put_run(_state, _run), do: @error

    @impl true
    def get_run(_state, _id), do: @error

    @impl true
    def list_runs(_state, _filters), do: @error

    @impl true
    def put_baseline(_state, _label, _run_id), do: @error

    @impl true
    def get_baseline(_state, _label), do: @error

    @impl true
    def list_baselines(_state, _label), do: @error

    @impl true
    def put_calibration(_state, _fingerprint_id, _result), do: @error

    @impl true
    def get_calibration(_state, _fingerprint_id), do: @error

    @impl true
    def put_profile(_state, _profile), do: @error

    @impl true
    def get_profile(_state, _ref), do: @error

    @impl true
    def list_profiles(_state, _name), do: @error

    @impl true
    def put_profile_label(_state, _name, _label, _profile_id), do: @error

    @impl true
    def list_profile_labels(_state, _name, _label), do: @error

    @impl true
    def delete_runs_before(_state, _task, _before), do: @error
  end
end
