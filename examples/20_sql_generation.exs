#!/usr/bin/env elixir

# Nous AI - Text-to-SQL Generation
# Turn a natural-language question into a validated SQL SELECT, then run it.
#
# This example demonstrates:
#   1. A real (in-memory ETS) table with a printed schema
#   2. Nous.OutputSchema - the model must answer with {query, explanation}
#   3. A module tool (Nous.Tool.Behaviour) that rejects anything but one SELECT
#   4. Executing the accepted SELECT and printing the rows
#
# Ported from pydantic-ai's `sql_gen.py`.
#
# The table, the guard and the executor all work offline, so this script still
# teaches something when no API key is set - only step 4 needs a model.
#
# Run with: mix run examples/20_sql_generation.exs
#
# Requires (model section only): OPENAI_API_KEY, or NOUS_MODEL pointing at
# another provider.

IO.puts("=== Nous AI - Text-to-SQL Demo ===\n")

# The tool executor logs every call at :debug, and the async logger interleaves
# those lines with this script's output. Quiet it so the demo reads as a story.
Logger.configure(level: :info)

# ============================================================================
# The database: an ETS table
# ============================================================================
#
# ETS ships with the BEAM, so this example runs anywhere. (A SQLite version
# would need `exqlite`, which is commented out in mix.exs by default.)

defmodule SqlGen.Db do
  @moduledoc "A tiny service-log table living in ETS."

  @table :demo_logs

  # Declared column order drives `SELECT *` and the table printer.
  @columns [
    id: :integer,
    service: :string,
    level: :string,
    message: :string,
    duration_ms: :integer
  ]

  @by_name Map.new(@columns, fn {name, _type} -> {Atom.to_string(name), name} end)
  @types Map.new(@columns)

  @rows [
    %{id: 1, service: "checkout", level: "error", message: "payment gateway timeout", duration_ms: 4210},
    %{id: 2, service: "checkout", level: "info", message: "order 1041 placed", duration_ms: 120},
    %{id: 3, service: "search", level: "warn", message: "slow query on products", duration_ms: 1830},
    %{id: 4, service: "auth", level: "error", message: "invalid token signature", duration_ms: 15},
    %{id: 5, service: "auth", level: "info", message: "user 88 logged in", duration_ms: 42},
    %{id: 6, service: "search", level: "error", message: "index shard unavailable", duration_ms: 950},
    %{id: 7, service: "checkout", level: "warn", message: "retrying payment capture", duration_ms: 2600}
  ]

  def table_name, do: Atom.to_string(@table)
  def columns, do: @columns

  @doc "Resolve a column name from untrusted SQL. Whitelist lookup - never String.to_atom/1."
  def column_atom(name), do: Map.fetch(@by_name, name)

  def column_type(column), do: Map.fetch!(@types, column)

  def seed! do
    :ets.new(@table, [:ordered_set, :public, :named_table])
    Enum.each(@rows, fn row -> :ets.insert(@table, {row.id, row}) end)
    :ok
  end

  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, row} -> row end)
  end

  @doc "The schema as DDL, so both the reader and the model see the same thing."
  def ddl do
    body =
      Enum.map_join(@columns, ",\n", fn {name, type} ->
        "  #{name} #{sql_type(type)}"
      end)

    "CREATE TABLE #{@table} (\n#{body}\n);"
  end

  defp sql_type(:integer), do: "INTEGER"
  defp sql_type(:string), do: "TEXT"
end

SqlGen.Db.seed!()

IO.puts("--- Schema ---")
IO.puts(SqlGen.Db.ddl())
IO.puts("\nSeeded #{length(SqlGen.Db.all())} rows into ETS table #{SqlGen.Db.table_name()}.\n")

# ============================================================================
# The guard: a module tool that only lets a single SELECT through
# ============================================================================
#
# A generated query is untrusted input. This is a real Nous.Tool.Behaviour
# module (not a bare anonymous function), so it has a parameter schema, can be
# unit-tested on its own, and can be handed to the agent as a tool.

defmodule SqlGen.Guard do
  @moduledoc """
  Validates that a SQL string is a single, read-only SELECT.

  Rules, applied in order:

    1. Non-empty after trimming.
    2. At most 500 characters.
    3. No SQL comments (`--` or `/*`) anywhere - they hide payloads.
    4. Balanced single quotes (an odd count means an unterminated literal).
    5. At most ONE trailing `;`, and no other `;` after stripping it - that
       kills stacked statements like `SELECT 1; DROP TABLE t;`.
    6. Must start with the `SELECT` keyword.
    7. No forbidden keyword anywhere as a whole word (INSERT, UPDATE, DELETE,
       DROP, ALTER, CREATE, TRUNCATE, REPLACE, ATTACH, DETACH, PRAGMA, VACUUM,
       GRANT, REVOKE, EXEC, EXECUTE, INTO, MERGE, CALL).

  Rule 7 scans string literals too, so a harmless `WHERE message LIKE '%drop%'`
  is rejected as well. That is deliberate: over-rejecting is far cheaper than
  reasoning about quoting, and it keeps the guard a pure lexical check with no
  SQL parser to fool. Note it matches whole words only - `'%dropped%'` passes.
  """

  @behaviour Nous.Tool.Behaviour

  @max_length 500

  @forbidden ~w(
    insert update delete drop alter create truncate replace
    attach detach pragma vacuum grant revoke exec execute into merge call
  )

  @impl true
  def metadata do
    %{
      name: "validate_sql",
      description:
        "Check that a SQL statement is a single read-only SELECT. " <>
          "Returns the accepted query, or the reason it was rejected.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "The SQL statement to validate"
          }
        },
        "required" => ["query"]
      },
      category: :read
    }
  end

  @impl true
  def execute(_ctx, %{"query" => query}) when is_binary(query) do
    # A rejection is a normal outcome, not a tool failure: returning {:ok, ...}
    # lets the model read the reason and try again instead of burning retries.
    case validate(query) do
      {:ok, sql} -> {:ok, %{status: "accepted", query: sql}}
      {:error, reason} -> {:ok, %{status: "rejected", reason: reason}}
    end
  end

  def execute(_ctx, _args), do: {:error, ~s(validate_sql expects a "query" string)}

  @doc "Returns `{:ok, sql}` with the trailing `;` stripped, or `{:error, reason}`."
  def validate(sql) when is_binary(sql) do
    trimmed = String.trim(sql)

    cond do
      trimmed == "" ->
        {:error, "empty query"}

      String.length(trimmed) > @max_length ->
        {:error, "query is longer than #{@max_length} characters"}

      String.contains?(trimmed, "--") or String.contains?(trimmed, "/*") ->
        {:error, "SQL comments (-- or /* */) are not allowed"}

      rem(count_quotes(trimmed), 2) != 0 ->
        {:error, "unterminated string literal (odd number of single quotes)"}

      true ->
        check_statement(strip_one_semicolon(trimmed))
    end
  end

  defp check_statement(body) do
    with :ok <- single_statement(body),
         :ok <- starts_with_select(body),
         :ok <- no_forbidden_keyword(body) do
      {:ok, body}
    end
  end

  defp single_statement(body) do
    if String.contains?(body, ";") do
      {:error, "stacked statements are not allowed (found an inner ';')"}
    else
      :ok
    end
  end

  defp starts_with_select(body) do
    if Regex.match?(~r/^select\s/i, body) do
      :ok
    else
      {:error, "query must begin with SELECT"}
    end
  end

  defp no_forbidden_keyword(body) do
    words =
      ~r/[a-z_]+/
      |> Regex.scan(String.downcase(body))
      |> List.flatten()

    case Enum.find(words, &(&1 in @forbidden)) do
      nil -> :ok
      word -> {:error, "forbidden keyword #{String.upcase(word)}"}
    end
  end

  # Exactly one trailing semicolon is tolerated; String.trim_trailing/2 would
  # happily eat `;;;`, which is precisely the game we are refusing to play.
  defp strip_one_semicolon(body) do
    if String.ends_with?(body, ";") do
      body |> String.slice(0..-2//1) |> String.trim()
    else
      body
    end
  end

  defp count_quotes(body) do
    body |> String.graphemes() |> Enum.count(&(&1 == "'"))
  end
end

# ============================================================================
# The executor: a deliberately small SQL subset over the ETS rows
# ============================================================================

defmodule SqlGen.MiniSql do
  @moduledoc """
  Runs the accepted SELECT against the ETS rows. It understands exactly:

      SELECT <* | col, col, ...> FROM demo_logs
        [WHERE <cond> [AND <cond> ...]]
        [ORDER BY <col> [ASC|DESC]]
        [LIMIT <n>]

  where `<cond>` is `col <op> literal` with op in `= != <> < <= > >=`, or
  `col LIKE 'pattern'` (`%` and `_` wildcards). A literal is a single-quoted
  string or an integer, and its type must match the column's declared type.

  No joins, no OR, no aggregates, no expressions, no subqueries. Anything else
  returns `{:error, reason}` rather than pretending to have run.
  """

  @statement ~r/
    ^select\s+(?<cols>.+?)
    \s+from\s+(?<table>[a-z_][a-z0-9_]*)
    (?:\s+where\s+(?<where>.+?))?
    (?:\s+order\s+by\s+(?<order>[a-z_][a-z0-9_]*(?:\s+(?:asc|desc))?))?
    (?:\s+limit\s+(?<limit>\d+))?$
  /ix

  @like ~r/^(?<col>[a-z_][a-z0-9_]*)\s+like\s+'(?<pattern>[^']*)'$/i
  @cmp ~r/^(?<col>[a-z_][a-z0-9_]*)\s*(?<op><=|>=|<>|!=|=|<|>)\s*(?:'(?<str>[^']*)'|(?<num>-?\d+))$/i

  @doc "Returns `{:ok, columns, rows}` or `{:error, reason}`."
  def run(sql, rows) do
    normalized =
      sql
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case Regex.named_captures(@statement, normalized) do
      nil -> {:error, "this mini executor does not support that SQL shape"}
      caps -> execute(caps, rows)
    end
  end

  defp execute(caps, rows) do
    with :ok <- check_table(caps["table"]),
         {:ok, columns} <- parse_columns(caps["cols"]),
         {:ok, conditions} <- parse_where(caps["where"]),
         {:ok, order} <- parse_order(caps["order"]),
         {:ok, limit} <- parse_limit(caps["limit"]) do
      selected =
        rows
        |> Enum.filter(fn row -> Enum.all?(conditions, &matches?(&1, row)) end)
        |> apply_order(order)
        |> apply_limit(limit)
        |> Enum.map(&Map.take(&1, columns))

      {:ok, columns, selected}
    end
  end

  defp check_table(name) do
    if name == SqlGen.Db.table_name() do
      :ok
    else
      {:error, "unknown table #{inspect(name)}"}
    end
  end

  defp parse_columns("*"), do: {:ok, Enum.map(SqlGen.Db.columns(), fn {name, _} -> name end)}

  defp parse_columns(list) do
    list
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> reduce_ok(&resolve_column/1)
  end

  defp resolve_column(name) do
    case SqlGen.Db.column_atom(String.downcase(name)) do
      {:ok, column} -> {:ok, column}
      :error -> {:error, "unsupported column #{inspect(name)} - only bare demo_logs columns"}
    end
  end

  defp parse_where(""), do: {:ok, []}

  defp parse_where(clause) do
    clause
    |> String.split(~r/\s+and\s+/i)
    |> Enum.map(&String.trim/1)
    |> reduce_ok(&parse_condition/1)
  end

  defp parse_condition(condition) do
    cond do
      caps = Regex.named_captures(@like, condition) ->
        with {:ok, column} <- resolve_column(caps["col"]),
             :ok <- expect_type(column, :string) do
          {:ok, {column, :like, like_regex(caps["pattern"])}}
        end

      caps = Regex.named_captures(@cmp, condition) ->
        with {:ok, column} <- resolve_column(caps["col"]),
             {:ok, value} <- literal(caps),
             :ok <- expect_type(column, value_type(value)) do
          {:ok, {column, operator(caps["op"]), value}}
        end

      true ->
        {:error, "unsupported condition #{inspect(condition)}"}
    end
  end

  # named_captures/2 fills non-participating groups with "", so an empty
  # `num` means the literal came through as a quoted string.
  defp literal(%{"num" => ""} = caps), do: {:ok, caps["str"]}
  defp literal(%{"num" => num}), do: {:ok, String.to_integer(num)}

  defp value_type(value) when is_integer(value), do: :integer
  defp value_type(value) when is_binary(value), do: :string

  defp expect_type(column, type) do
    actual = SqlGen.Db.column_type(column)

    if actual == type do
      :ok
    else
      {:error, "column #{column} is #{actual}, cannot compare it with a #{type} literal"}
    end
  end

  defp operator("="), do: :eq
  defp operator("!="), do: :neq
  defp operator("<>"), do: :neq
  defp operator("<"), do: :lt
  defp operator("<="), do: :lte
  defp operator(">"), do: :gt
  defp operator(">="), do: :gte

  defp like_regex(pattern) do
    body =
      pattern
      |> String.graphemes()
      |> Enum.map_join(fn
        "%" -> ".*"
        "_" -> "."
        char -> Regex.escape(char)
      end)

    Regex.compile!("^" <> body <> "$", "i")
  end

  defp matches?({column, :like, regex}, row), do: Regex.match?(regex, Map.fetch!(row, column))

  defp matches?({column, op, value}, row) do
    actual = Map.fetch!(row, column)

    case op do
      :eq -> actual == value
      :neq -> actual != value
      :lt -> actual < value
      :lte -> actual <= value
      :gt -> actual > value
      :gte -> actual >= value
    end
  end

  defp parse_order(""), do: {:ok, nil}

  defp parse_order(clause) do
    {name, direction} =
      case String.split(clause, ~r/\s+/) do
        [name] -> {name, :asc}
        [name, dir] -> {name, if(String.downcase(dir) == "desc", do: :desc, else: :asc)}
      end

    with {:ok, column} <- resolve_column(name), do: {:ok, {column, direction}}
  end

  defp parse_limit(""), do: {:ok, nil}
  defp parse_limit(digits), do: {:ok, String.to_integer(digits)}

  defp apply_order(rows, nil), do: Enum.sort_by(rows, & &1.id)
  defp apply_order(rows, {column, direction}), do: Enum.sort_by(rows, &Map.fetch!(&1, column), direction)

  defp apply_limit(rows, nil), do: rows
  defp apply_limit(rows, limit), do: Enum.take(rows, limit)

  # Map a list through a fallible function, short-circuiting on the first error.
  defp reduce_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end

defmodule SqlGen.Printer do
  @moduledoc "Prints result rows as a fixed-width table."

  def rows(_columns, []), do: IO.puts("  (no rows)")

  def rows(columns, rows) do
    widths =
      Map.new(columns, fn column ->
        cells = [header(column) | Enum.map(rows, &cell(&1, column))]
        {column, cells |> Enum.map(&String.length/1) |> Enum.max()}
      end)

    IO.puts("  " <> line(columns, widths, &header/1))
    IO.puts("  " <> Enum.map_join(columns, "-+-", fn c -> String.duplicate("-", widths[c]) end))

    Enum.each(rows, fn row ->
      IO.puts("  " <> line(columns, widths, &cell(row, &1)))
    end)
  end

  defp line(columns, widths, formatter) do
    Enum.map_join(columns, " | ", fn column ->
      String.pad_trailing(formatter.(column), widths[column])
    end)
  end

  defp header(column), do: Atom.to_string(column)
  defp cell(row, column), do: to_string(Map.fetch!(row, column))
end

# ============================================================================
# Offline: the guard in action
# ============================================================================
#
# Build the tool from the behaviour module and drive it through the same
# executor the agent runner uses, so argument validation and the parameter
# schema are exercised exactly as they would be mid-run.

validator = Nous.Tool.from_module(SqlGen.Guard)
ctx = Nous.RunContext.new(%{})

IO.puts("--- Guard: #{validator.name} (#{validator.category}) ---")

candidates = [
  {"honest query", "SELECT service, message, duration_ms FROM demo_logs WHERE level = 'error' ORDER BY duration_ms DESC LIMIT 3"},
  {"stacked DROP", "SELECT * FROM demo_logs; DROP TABLE demo_logs;"},
  {"semicolon games", "SELECT * FROM demo_logs;;"},
  {"comment smuggling", "SELECT * FROM demo_logs -- WHERE level = 'error'"},
  {"outright mutation", "DELETE FROM demo_logs WHERE level = 'error'"},
  {"exfiltration", "SELECT * INTO OUTFILE '/tmp/leak.csv' FROM demo_logs"}
]

accepted =
  Enum.reduce(candidates, nil, fn {label, sql}, first_accepted ->
    {:ok, verdict} = Nous.ToolExecutor.execute(validator, %{"query" => sql}, ctx)

    case verdict do
      %{status: "accepted", query: query} ->
        IO.puts("  ACCEPT  #{label}\n          #{query}")
        first_accepted || query

      %{status: "rejected", reason: reason} ->
        IO.puts("  REJECT  #{label}: #{reason}\n          #{sql}")
        first_accepted
    end
  end)

IO.puts("")

# ============================================================================
# Offline: run the accepted SELECT
# ============================================================================

IO.puts("--- Executing the accepted query ---")

case SqlGen.MiniSql.run(accepted, SqlGen.Db.all()) do
  {:ok, columns, rows} ->
    IO.puts("  #{accepted}\n")
    SqlGen.Printer.rows(columns, rows)

  {:error, reason} ->
    IO.puts("  Executor error: #{reason}")
end

IO.puts("")

# ============================================================================
# The output schema
# ============================================================================
#
# `use Nous.OutputSchema` on an Ecto embedded schema is the documented form:
# the schema becomes the JSON schema sent to the provider, and @llm_doc adds
# per-field guidance the model sees.

defmodule SqlGen.Answer do
  use Ecto.Schema
  use Nous.OutputSchema

  @llm_doc """
  ## Field Descriptions:
  - query: A single SQL SELECT statement against demo_logs. No semicolon, no comments.
  - explanation: One sentence, under 20 words, saying what the query returns.
  """
  @primary_key false
  embedded_schema do
    field(:query, :string)
    field(:explanation, :string)
  end
end

# ============================================================================
# Model selection + credential guard
# ============================================================================

model_override = System.get_env("NOUS_MODEL")
model = model_override || "openai:gpt-4o-mini"
openai_key = System.get_env("OPENAI_API_KEY") || Application.get_env(:nous, :openai_api_key)

if is_nil(model_override) and is_nil(openai_key) do
  IO.puts("""
  --- Skipping the model section ---

  Everything above ran offline. Generating SQL needs credentials for the
  default model (#{model}).

  Set an OpenAI key, or point NOUS_MODEL at another provider:

      export OPENAI_API_KEY="sk-..."
      # or
      NOUS_MODEL=lmstudio:qwen3 mix run examples/20_sql_generation.exs
  """)

  System.halt(0)
end

# ============================================================================
# Natural language -> SQL -> guard -> rows
# ============================================================================

IO.puts("--- Model: #{model} ---")

instructions = """
You write SQL SELECT statements for a SQLite-flavoured table.

Schema:
#{SqlGen.Db.ddl()}

Rules:
- Emit exactly one SELECT. Never INSERT, UPDATE, DELETE, DROP or ATTACH.
- No semicolons and no SQL comments.
- Supported grammar only: SELECT <columns> FROM demo_logs [WHERE col <op> literal
  [AND ...]] [ORDER BY col [ASC|DESC]] [LIMIT n]. No joins, no OR, no aggregates.
- Call the validate_sql tool on your query before answering, and fix it if the
  tool rejects it.
"""

agent =
  Nous.new(model,
    output_type: SqlGen.Answer,
    tools: [validator],
    instructions: instructions,
    structured_output: [max_retries: 2]
  )

question = "Which error-level events were the slowest? Show the service, message and duration."
IO.puts("  Question: #{question}\n")

case Nous.run(agent, question) do
  {:ok, result} ->
    answer = result.output
    IO.puts("  Generated: #{answer.query}")
    IO.puts("  Rationale: #{answer.explanation}\n")

    # Never trust the model's own tool call - re-validate before executing.
    {:ok, verdict} = Nous.ToolExecutor.execute(validator, %{"query" => answer.query}, ctx)

    case verdict do
      %{status: "accepted", query: query} ->
        case SqlGen.MiniSql.run(query, SqlGen.Db.all()) do
          {:ok, columns, rows} -> SqlGen.Printer.rows(columns, rows)
          {:error, reason} -> IO.puts("  Executor error: #{reason}")
        end

      %{status: "rejected", reason: reason} ->
        IO.puts("  Guard rejected the generated query: #{reason}")
    end

  {:error, error} ->
    reason = if is_exception(error), do: Exception.message(error), else: inspect(error)
    IO.puts("  Run failed: #{reason}")
end

IO.puts("")
IO.puts("Done!")
