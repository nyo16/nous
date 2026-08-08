if Code.ensure_loaded?(Exqlite) do
  defmodule Nous.Memory.Store.SQLiteTest do
    use ExUnit.Case, async: true

    @moduletag :sqlite

    alias Nous.Memory.Entry
    alias Nous.Memory.Store.SQLite

    setup do
      {:ok, conn} = SQLite.init([])
      %{conn: conn}
    end

    # Exercises every field whose representation changes crossing into SQLite:
    # the type atom becomes TEXT, `evergreen` an INTEGER, the embedding and the
    # metadata JSON strings, the three timestamps ISO8601. Anything the encoder
    # or the decoder gets wrong shows up as an inequality in the round trip.
    defp sample_entry(attrs \\ %{}) do
      Entry.new(
        Map.merge(
          %{
            content: "the harbour lights at dusk",
            type: :episodic,
            importance: 0.875,
            evergreen: true,
            embedding: [0.1, -0.25, 0.5],
            metadata: %{source: "notebook", page: 12},
            agent_id: "agent-1",
            session_id: "session-1",
            user_id: "user-1",
            namespace: "namespace-1"
          },
          attrs
        )
      )
    end

    describe "store/2 and fetch/2" do
      test "a stored entry comes back byte-identical", %{conn: conn} do
        entry = sample_entry()

        assert {:ok, ^conn} = SQLite.store(conn, entry)
        assert {:ok, fetched} = SQLite.fetch(conn, entry.id)

        # Whole-struct equality, not a field spot-check: a decoder that drops a
        # column or mistypes one fails here without the test having to name it.
        assert fetched == entry
      end

      test "the fields that change representation survive the boundary", %{conn: conn} do
        entry = sample_entry()
        {:ok, _conn} = SQLite.store(conn, entry)
        {:ok, fetched} = SQLite.fetch(conn, entry.id)

        # TEXT -> atom, INTEGER -> boolean, JSON string -> [float], JSON string
        # -> map with atom keys, REAL -> float, ISO8601 -> DateTime.
        assert fetched.type == :episodic
        assert fetched.evergreen === true
        assert fetched.embedding == [0.1, -0.25, 0.5]
        assert fetched.metadata == %{source: "notebook", page: 12}
        assert fetched.importance === 0.875
        assert DateTime.compare(fetched.created_at, entry.created_at) == :eq
      end

      test "nil embedding and empty metadata decode to nil and %{}", %{conn: conn} do
        entry = sample_entry(%{embedding: nil, metadata: %{}})
        {:ok, _conn} = SQLite.store(conn, entry)

        assert {:ok, fetched} = SQLite.fetch(conn, entry.id)
        assert fetched.embedding == nil
        assert fetched.metadata == %{}
        assert fetched.evergreen == true
      end

      test "an unknown id is :not_found, not a crash", %{conn: conn} do
        assert SQLite.fetch(conn, "no-such-id") == {:error, :not_found}
      end
    end

    describe "update/3" do
      test "changes only the named fields", %{conn: conn} do
        entry = sample_entry()
        {:ok, _conn} = SQLite.store(conn, entry)

        assert {:ok, ^conn} = SQLite.update(conn, entry.id, %{importance: 0.1})
        assert {:ok, updated} = SQLite.fetch(conn, entry.id)

        # `updated_at` is stamped by the store on every update; everything else
        # must be the entry as stored.
        assert updated.importance == 0.1
        assert DateTime.compare(updated.updated_at, entry.updated_at) == :gt
        assert %{updated | importance: entry.importance, updated_at: entry.updated_at} == entry
      end

      test "re-encodes fields that cross the type boundary", %{conn: conn} do
        entry = sample_entry()
        {:ok, _conn} = SQLite.store(conn, entry)

        updates = %{
          type: :procedural,
          evergreen: false,
          embedding: [1.0, 0.0, -1.0],
          metadata: %{source: "revised"},
          access_count: 7
        }

        assert {:ok, ^conn} = SQLite.update(conn, entry.id, updates)
        assert {:ok, updated} = SQLite.fetch(conn, entry.id)

        assert updated.type == :procedural
        assert updated.evergreen === false
        assert updated.embedding == [1.0, 0.0, -1.0]
        assert updated.metadata == %{source: "revised"}
        assert updated.access_count == 7
      end

      test "moves the FTS row with the content", %{conn: conn} do
        entry = sample_entry()
        {:ok, _conn} = SQLite.store(conn, entry)
        {:ok, _conn} = SQLite.update(conn, entry.id, %{content: "the lighthouse at dawn"})

        assert {:ok, [{hit, _score}]} = SQLite.search_text(conn, "lighthouse", [])
        assert hit.id == entry.id
        assert {:ok, []} = SQLite.search_text(conn, "harbour", [])
      end

      test "a failed FTS write rolls the whole update back", %{conn: conn} do
        entry = sample_entry()
        {:ok, _conn} = SQLite.store(conn, entry)

        # Removing the FTS table is the cheapest way to make the second write in
        # the transaction fail for real, with no stubbing. The `memories` write
        # has already succeeded at that point, so a store that ignores the FTS
        # result commits a row whose indexed text no longer matches its content.
        :ok = Exqlite.Sqlite3.execute(conn, "DROP TABLE memories_fts")

        assert {:error, _reason} = SQLite.update(conn, entry.id, %{content: "never indexed"})
        assert {:ok, unchanged} = SQLite.fetch(conn, entry.id)
        assert unchanged.content == entry.content
      end

      test "an unknown id propagates :not_found", %{conn: conn} do
        assert SQLite.update(conn, "no-such-id", %{importance: 0.1}) == {:error, :not_found}
      end

      # `Nous.Memory.Store`'s `update/3` callback documents this precedence:
      # validation runs BEFORE the row lookup, so an unknown field raises even
      # when the id is also unknown — it does not degrade to `{:error,
      # :not_found}`. An unknown field is a caller bug, not a missing row, and
      # checking ahead of I/O is what keeps the SQL-identifier allowlist
      # reachable without a live driver. The `:not_found` control is the test
      # directly above: same absent id, allowlisted field, tuple not raise.
      test "an unlisted column raises before the lookup, even for an unknown id", %{conn: conn} do
        assert SQLite.fetch(conn, "any-id") == {:error, :not_found}

        assert_raise ArgumentError, ~r/unknown memory column/, fn ->
          SQLite.update(conn, "any-id", %{"content = '' OR 1=1 --" => "x"})
        end
      end
    end

    describe "delete/2" do
      test "removes the row and its FTS entry", %{conn: conn} do
        entry = sample_entry()
        {:ok, _conn} = SQLite.store(conn, entry)

        assert {:ok, ^conn} = SQLite.delete(conn, entry.id)
        assert SQLite.fetch(conn, entry.id) == {:error, :not_found}
        assert {:ok, []} = SQLite.search_text(conn, "harbour", [])
        assert {:ok, []} = SQLite.list(conn, [])
      end
    end

    describe "search_text/3" do
      test "finds an entry by its content and scores it", %{conn: conn} do
        entry = sample_entry()
        {:ok, _conn} = SQLite.store(conn, entry)

        assert {:ok, [{hit, score}]} = SQLite.search_text(conn, "harbour", [])
        # The join returns `m.*` plus a `rank` column; the decoder must ignore
        # the extra column and still rebuild the entry in full.
        assert hit == entry
        assert is_float(score) and score > 0.0
      end

      test "respects :scope", %{conn: conn} do
        mine = sample_entry(%{agent_id: "mine"})
        theirs = sample_entry(%{agent_id: "theirs"})
        {:ok, _conn} = SQLite.store(conn, mine)
        {:ok, _conn} = SQLite.store(conn, theirs)

        assert {:ok, [{hit, _}]} = SQLite.search_text(conn, "harbour", scope: %{agent_id: "mine"})
        assert hit.id == mine.id
        assert {:ok, []} = SQLite.search_text(conn, "harbour", scope: %{agent_id: "nobody"})
      end

      test "honours :limit", %{conn: conn} do
        for _ <- 1..3, do: {:ok, _conn} = SQLite.store(conn, sample_entry())

        assert {:ok, hits} = SQLite.search_text(conn, "harbour", limit: 2)
        assert length(hits) == 2
      end

      test "a quoted term is escaped rather than parsed as FTS5 syntax", %{conn: conn} do
        entry = sample_entry(%{content: ~s(she said "hi" twice)})
        {:ok, _conn} = SQLite.store(conn, entry)

        assert {:ok, [{hit, _}]} = SQLite.search_text(conn, ~s(said "hi"), [])
        assert hit.id == entry.id
      end

      test "no match is an empty list", %{conn: conn} do
        {:ok, _conn} = SQLite.store(conn, sample_entry())
        assert {:ok, []} = SQLite.search_text(conn, "zzzunmatchable", [])
      end
    end

    describe "search_vector/3" do
      test "ranks by cosine similarity and applies :min_score", %{conn: conn} do
        near = sample_entry(%{content: "near", embedding: [1.0, 0.0]})
        far = sample_entry(%{content: "far", embedding: [0.0, 1.0]})
        {:ok, _conn} = SQLite.store(conn, near)
        {:ok, _conn} = SQLite.store(conn, far)

        assert {:ok, [{first, first_score}, {second, _}]} =
                 SQLite.search_vector(conn, [1.0, 0.0], [])

        assert first.id == near.id
        assert second.id == far.id
        assert_in_delta first_score, 1.0, 1.0e-9

        assert {:ok, [{only, _}]} = SQLite.search_vector(conn, [1.0, 0.0], min_score: 0.5)
        assert only.id == near.id
      end

      test "skips rows with no embedding", %{conn: conn} do
        {:ok, _conn} = SQLite.store(conn, sample_entry(%{embedding: nil}))
        assert {:ok, []} = SQLite.search_vector(conn, [1.0, 0.0], [])
      end
    end

    describe "list/2" do
      test "returns every entry, filtered by :scope", %{conn: conn} do
        mine = sample_entry(%{user_id: "mine"})
        theirs = sample_entry(%{user_id: "theirs"})
        {:ok, _conn} = SQLite.store(conn, mine)
        {:ok, _conn} = SQLite.store(conn, theirs)

        assert {:ok, all} = SQLite.list(conn, [])
        assert length(all) == 2

        assert {:ok, [only]} = SQLite.list(conn, scope: %{user_id: "mine"})
        assert only == mine
      end
    end

    describe "decoding a corrupt persisted row" do
      test "an unknown type yields nil rather than raising", %{conn: conn} do
        now = DateTime.to_iso8601(DateTime.utc_now())

        insert = """
        INSERT INTO memories (id, content, type, created_at, updated_at, last_accessed_at)
        VALUES ('corrupt-entry', 'hello', 'no_such_memory_type_xyz', '#{now}', '#{now}', '#{now}')
        """

        :ok = Exqlite.Sqlite3.execute(conn, insert)

        assert {:ok, fetched} = SQLite.fetch(conn, "corrupt-entry")
        assert fetched.type == nil
        assert fetched.content == "hello"
      end

      test "every declared memory type still roundtrips", %{conn: conn} do
        for type <- [:semantic, :episodic, :procedural] do
          entry = Entry.new(%{content: "note", type: type})
          {:ok, _conn} = SQLite.store(conn, entry)

          assert {:ok, fetched} = SQLite.fetch(conn, entry.id)
          assert fetched.type == type
        end
      end
    end
  end
else
  # `exqlite` is a declared optional dep now, so this branch should not be
  # reached in nous's own CI — it is here for the case that actually happens
  # with a NIF dep: the amalgamation fails to build in some environment and
  # the suite silently stops existing. The reason lives in the test NAME
  # because the default formatter prints the `skip:` tag's value nowhere.
  #
  # The column allowlist is covered unconditionally by
  # `test/nous/memory/store/sqlite_columns_test.exs`.
  defmodule Nous.Memory.Store.SQLiteTest do
    use ExUnit.Case, async: true

    @tag skip: "Exqlite not available"
    test "SQLite store suite skipped: {:exqlite, \"~> 0.27\"} is declared but did not compile" do
      flunk("tagged skip; this body must never execute")
    end
  end
end
