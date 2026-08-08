# Compiled unconditionally, unlike the two stores that call in. `exqlite` and
# `duckdbex` are optional dependencies, so anything inside their
# `Code.ensure_loaded?` gates disappears in any build that does not install them
# — which is exactly where the SQL-identifier allowlist must not live. The data
# and the check sit here; the stores call in.
defmodule Nous.Memory.Store.Columns do
  @moduledoc false

  # Allowlist of `Nous.Memory.Entry` field → physical `memories` column, shared
  # by the SQLite and DuckDB memory stores. Column names are interpolated into
  # `SET col = ?n` / `WHERE col = ?n` (`$n` for DuckDB), so they must never be a
  # raw `to_string/1` of caller input (SQL-identifier injection primitive).
  #
  # The two stores describe the same logical `memories` table with the same
  # column names — only the physical types differ (`BLOB`/`INTEGER` vs
  # `DOUBLE[]`/`BOOLEAN`), and this allowlist is name-only. One map is therefore
  # one source of truth rather than a clone plus a drift-detecting test.
  #
  # It stays disjoint from `Nous.Decisions.Store.DuckDB.Columns`, which is the
  # invariant P5-T3 established: that allowlist addresses a different table
  # (`decision_nodes`), and a single map spanning both would let either domain
  # write the other's columns. Note `:type` resolves to "type" here and to
  # "node_type" there — the two maps are not mergeable.
  @column_map %{
    id: "id",
    content: "content",
    type: "type",
    importance: "importance",
    evergreen: "evergreen",
    embedding: "embedding",
    agent_id: "agent_id",
    session_id: "session_id",
    user_id: "user_id",
    namespace: "namespace",
    metadata: "metadata_json",
    access_count: "access_count",
    created_at: "created_at",
    updated_at: "updated_at",
    last_accessed_at: "last_accessed_at"
  }

  @spec column_map() :: %{atom() => String.t()}
  def column_map, do: @column_map

  @spec fetch!(term()) :: String.t()
  def fetch!(field) do
    case Map.fetch(@column_map, field) do
      {:ok, col} ->
        col

      :error ->
        raise ArgumentError,
              "unknown memory column #{inspect(field)} — not in the allowlist " <>
                "(#{@column_map |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)})"
    end
  end

  @spec validate!(map()) :: :ok
  def validate!(updates) when is_map(updates), do: Enum.each(Map.keys(updates), &fetch!/1)
end
