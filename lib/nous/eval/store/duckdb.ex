if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Eval.Store.DuckDB do
    @moduledoc """
    DuckDB-backed `Nous.Eval.Store` using `duckdbex`.

        {:ok, store} = Nous.Eval.Store.DuckDB.init(path: "priv/eval.duckdb")

    Same layout as `Nous.Eval.Store.SQLite`: runs are rows of
    `nous_eval_runs` holding the `Nous.Eval.Codec` JSON text of the run
    (`payload`) and of its summary (`summary`), baselines are rows of
    `nous_eval_baselines`, only ever inserted. The payload is plain JSON
    text, so DuckDB's `json_extract` can query stored runs directly.

    ## Options

      * `:path` - database file path (default: `":memory:"`)
    """

    @behaviour Nous.Eval.Store

    alias Nous.Eval.{Codec, Run, Store}
    alias Nous.Eval.Store.{Baseline, RunSummary}

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

    # -- helpers -------------------------------------------------------------

    defp create_schema(conn) do
      Enum.reduce_while(@schema, :ok, fn sql, :ok ->
        case Duckdbex.query(conn, sql) do
          {:ok, _} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
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
               list_baselines: 2}

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
  end
end
