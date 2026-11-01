if Code.ensure_loaded?(Exqlite) do
  defmodule Nous.Eval.Store.SQLite do
    @moduledoc """
    SQLite-backed `Nous.Eval.Store` using `exqlite`.

        {:ok, store} = Nous.Eval.Store.SQLite.init(path: "priv/eval.sqlite3")

    Runs are rows of `nous_eval_runs`: the full run as
    `Nous.Eval.Codec.encode_run_json/1` text in `payload`, its summary as
    `Nous.Eval.Codec.encode_summary_json/1` text in `summary`, and the
    columns `list_runs/2` filters and sorts on. Baselines are rows of
    `nous_eval_baselines`, only ever inserted. Judge calibrations are rows of
    `nous_eval_calibrations` (`Nous.Eval.Codec.encode_calibration_json/1`
    text); the latest row for a fingerprint id wins.

    ## Options

      * `:path` - database file path (default: `":memory:"`)
    """

    @behaviour Nous.Eval.Store

    alias Exqlite.Sqlite3
    alias Nous.Eval.{Codec, Run, Store}
    alias Nous.Eval.Store.{Baseline, RunSummary}

    @schema [
      """
      CREATE TABLE IF NOT EXISTS nous_eval_runs (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        task TEXT,
        status TEXT NOT NULL,
        started_at_us INTEGER,
        summary TEXT NOT NULL,
        payload TEXT NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS nous_eval_runs_started ON nous_eval_runs(started_at_us)",
      """
      CREATE TABLE IF NOT EXISTS nous_eval_baselines (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        label TEXT NOT NULL,
        run_id TEXT NOT NULL,
        set_at TEXT NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS nous_eval_baselines_label ON nous_eval_baselines(label, seq)",
      """
      CREATE TABLE IF NOT EXISTS nous_eval_calibrations (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        fingerprint_id TEXT NOT NULL,
        payload TEXT NOT NULL
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS nous_eval_calibrations_fingerprint
        ON nous_eval_calibrations(fingerprint_id, seq)
      """
    ]

    @impl true
    def init(opts) do
      path = Keyword.get(opts, :path, ":memory:")

      with {:ok, conn} <- Sqlite3.open(path),
           :ok <- create_schema(conn) do
        {:ok, conn}
      end
    end

    @impl true
    def put_run(conn, %Run{id: id} = run) do
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

        # IMMEDIATE takes the write lock up front, so the existence check and
        # the insert cannot interleave with another writer's.
        transaction(conn, fn ->
          case query(conn, "SELECT 1 FROM nous_eval_runs WHERE id = ?1", [id]) do
            {:ok, []} ->
              with {:ok, _} <-
                     query(
                       conn,
                       """
                       INSERT INTO nous_eval_runs
                         (id, task, status, started_at_us, summary, payload)
                       VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                       """,
                       params
                     ),
                   do: {:ok, conn}

            {:ok, _rows} ->
              {:error, :already_exists}

            {:error, _} = error ->
              error
          end
        end)
      end
    end

    @impl true
    def get_run(conn, id) do
      with :ok <- Store.validate_run_id(id) do
        case query(conn, "SELECT payload FROM nous_eval_runs WHERE id = ?1", [id]) do
          {:ok, [[payload]]} -> Codec.decode_run_json(payload)
          {:ok, []} -> {:error, :not_found}
          {:error, _} = error -> error
        end
      end
    end

    @impl true
    def list_runs(conn, filters) do
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
    def put_baseline(conn, label, run_id) do
      with :ok <- Store.validate_label(label),
           :ok <- Store.validate_run_id(run_id) do
        transaction(conn, fn ->
          case query(conn, "SELECT 1 FROM nous_eval_runs WHERE id = ?1", [run_id]) do
            {:ok, []} ->
              {:error, :not_found}

            {:ok, _rows} ->
              with {:ok, _} <-
                     query(
                       conn,
                       "INSERT INTO nous_eval_baselines (label, run_id, set_at) VALUES (?1, ?2, ?3)",
                       [label, run_id, DateTime.to_iso8601(DateTime.utc_now())]
                     ),
                   do: {:ok, conn}

            {:error, _} = error ->
              error
          end
        end)
      end
    end

    @impl true
    def get_baseline(conn, label) do
      with :ok <- Store.validate_label(label),
           {:ok, rows} <- baselines(conn, label, " LIMIT 1") do
        case rows do
          [entry] -> {:ok, entry}
          [] -> {:error, :not_found}
        end
      end
    end

    @impl true
    def list_baselines(conn, label) do
      with :ok <- Store.validate_label(label), do: baselines(conn, label, "")
    end

    @impl true
    def put_calibration(conn, fingerprint_id, result) do
      with :ok <- Store.validate_calibration(fingerprint_id, result),
           {:ok, payload} <- Codec.encode_calibration_json(result),
           {:ok, _} <-
             query(
               conn,
               "INSERT INTO nous_eval_calibrations (fingerprint_id, payload) VALUES (?1, ?2)",
               [fingerprint_id, payload]
             ) do
        {:ok, conn}
      end
    end

    @impl true
    def get_calibration(conn, fingerprint_id) do
      with :ok <- Store.validate_calibration(fingerprint_id),
           {:ok, rows} <-
             query(
               conn,
               """
               SELECT payload FROM nous_eval_calibrations
               WHERE fingerprint_id = ?1 ORDER BY seq DESC LIMIT 1
               """,
               [fingerprint_id]
             ) do
        case rows do
          [[payload]] -> Codec.decode_calibration_json(payload)
          [] -> {:error, :not_found}
        end
      end
    end

    # -- helpers -------------------------------------------------------------

    defp create_schema(conn) do
      Enum.reduce_while(@schema, :ok, fn sql, :ok ->
        case Sqlite3.execute(conn, sql) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end

    # `suffix` is a literal from this module, never caller data.
    defp baselines(conn, label, suffix) do
      sql =
        "SELECT label, run_id, set_at FROM nous_eval_baselines WHERE label = ?1 ORDER BY seq DESC" <>
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
          {:task, task}, acc -> add_clause(acc, "task = ?", task)
          {:status, status}, acc -> add_clause(acc, "status = ?", Atom.to_string(status))
          {:since, since}, acc -> add_clause(acc, "started_at_us >= ?", started_at_us(since))
          {:until, until}, acc -> add_clause(acc, "started_at_us < ?", started_at_us(until))
          {:limit, _}, acc -> acc
        end)

      case clauses do
        [] -> {"", []}
        _ -> {" WHERE " <> Enum.join(Enum.reverse(clauses), " AND "), Enum.reverse(params)}
      end
    end

    defp add_clause({clauses, params}, clause, value), do: {[clause | clauses], [value | params]}

    # `limit` was checked to be a non-negative integer by validate_filters/1.
    defp limit_clause(nil), do: ""
    defp limit_clause(limit) when is_integer(limit), do: " LIMIT #{limit}"

    defp started_at_us(nil), do: nil
    defp started_at_us(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

    defp query(conn, sql, params) do
      with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
        try do
          with :ok <- Sqlite3.bind(stmt, params), do: Sqlite3.fetch_all(conn, stmt)
        after
          Sqlite3.release(conn, stmt)
        end
      end
    end

    # Commits on `{:ok, _}`, rolls back on anything else, including a raise.
    defp transaction(conn, fun) do
      with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
        try do
          case fun.() do
            {:ok, _} = ok ->
              with :ok <- Sqlite3.execute(conn, "COMMIT"), do: ok

            other ->
              _ = Sqlite3.execute(conn, "ROLLBACK")
              other
          end
        rescue
          e ->
            _ = Sqlite3.execute(conn, "ROLLBACK")
            reraise e, __STACKTRACE__
        end
      end
    end
  end
else
  defmodule Nous.Eval.Store.SQLite do
    @moduledoc """
    SQLite-backed eval store (unavailable).

    Add `{:exqlite, "~> 0.43"}` to your dependencies to enable this store.
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
               get_calibration: 2}

    @error {:error, "Exqlite is not available. Add {:exqlite, \"~> 0.43\"} to your dependencies."}

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
  end
end
