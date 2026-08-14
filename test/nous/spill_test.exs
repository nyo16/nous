defmodule Nous.SpillTest.StubStore do
  @moduledoc false
  # A backend with no filesystem: it keeps content in the calling process's
  # dictionary (maybe_spill/2 calls the store synchronously) so the tests can
  # exercise Nous.Spill's own accounting without touching disk. `opts` steers
  # it: `:id` forces a locator id, `:fail` makes save_text/1 return an error.

  @behaviour Nous.Spill

  alias Nous.Spill.Locator

  @impl true
  def save_text(%{content: content} = attrs) do
    opts = Map.get(attrs, :opts, [])

    case Keyword.get(opts, :fail) do
      nil ->
        id = Keyword.get(opts, :id, "stub-#{System.unique_integer([:positive])}")
        Process.put({__MODULE__, id}, content)

        {:ok,
         %Locator{
           store: __MODULE__,
           id: id,
           bytes: byte_size(content),
           name: attrs.suggested_name
         }}

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def fetch(%Locator{id: id}) do
    case Process.get({__MODULE__, id}) do
      nil -> {:error, :enoent}
      content -> {:ok, content}
    end
  end

  @impl true
  def retrieval_hint(%Locator{id: id}), do: "Stub hint: ask for #{id}."
end

defmodule Nous.SpillTest do
  # async: false — the config/1 tests write `config :nous, :spill`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nous.RunContext
  alias Nous.Spill
  alias Nous.Spill.Locator
  alias Nous.SpillTest.StubStore

  @app_cfg %{store: StubStore, opts: [id: "from-app-config"], max_inline_bytes: 10}

  setup do
    original = Application.fetch_env(:nous, :spill)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:nous, :spill, value)
        :error -> Application.delete_env(:nous, :spill)
      end
    end)

    :ok
  end

  defp cfg(overrides \\ %{}) do
    Map.merge(%{store: StubStore, opts: [], max_inline_bytes: 100}, overrides)
  end

  defp ctx(spill_config), do: %{spill_config: spill_config}

  describe "config/1" do
    test "resolves from a RunContext's deps" do
      run_ctx = RunContext.new(%{spill_config: %{store: StubStore, opts: [root: "/x"]}})

      assert {:ok, resolved} = Spill.config(run_ctx)
      assert resolved.store == StubStore
      assert resolved.opts == [root: "/x"]
      # The documented default ceiling, not an accident of the caller's map.
      assert resolved.max_inline_bytes == 65_536
    end

    test "resolves from a bare deps map" do
      assert {:ok, resolved} = Spill.config(%{spill_config: cfg(%{max_inline_bytes: 7})})
      assert resolved.max_inline_bytes == 7
    end

    test "resolves from application config when deps carry none" do
      Application.put_env(:nous, :spill, @app_cfg)

      assert {:ok, resolved} = Spill.config(nil)
      assert resolved == @app_cfg
      assert {:ok, ^resolved} = Spill.config(RunContext.new(%{}))
    end

    test "deps wins over application config" do
      Application.put_env(:nous, :spill, @app_cfg)

      assert {:ok, resolved} = Spill.config(ctx(cfg(%{opts: [id: "from-deps"]})))
      assert resolved.opts == [id: "from-deps"]
      assert resolved.max_inline_bytes == 100
    end

    test "is :disabled with no deps and no application config" do
      Application.delete_env(:nous, :spill)

      assert Spill.config(nil) == :disabled
      assert Spill.config(%{}) == :disabled
      assert Spill.config(RunContext.new(%{})) == :disabled
    end

    test "is :disabled when the store is missing or nil" do
      assert Spill.config(ctx(%{opts: [root: "/x"]})) == :disabled
      assert Spill.config(ctx(%{store: nil})) == :disabled
      Application.put_env(:nous, :spill, %{store: nil})
      assert Spill.config(nil) == :disabled
    end
  end

  describe "maybe_spill/2 threshold" do
    test "content exactly at max_inline_bytes stays inline" do
      text = String.duplicate("a", 100)

      assert Spill.maybe_spill(text, ctx: ctx(cfg())) == :inline
    end

    test "one byte over max_inline_bytes spills" do
      text = String.duplicate("a", 101)

      assert {:spilled, replacement, %Locator{}} = Spill.maybe_spill(text, ctx: ctx(cfg()))
      refute replacement == text
    end

    test "one byte under max_inline_bytes stays inline" do
      assert Spill.maybe_spill(String.duplicate("a", 99), ctx: ctx(cfg())) == :inline
    end

    test "is :inline when spilling is disabled, whatever the size" do
      Application.delete_env(:nous, :spill)

      assert Spill.maybe_spill(String.duplicate("a", 5_000_000), ctx: nil) == :inline
    end

    test "content that is not valid UTF-8 stays inline" do
      # Well over the ceiling, but a byte-slice preview of binary content is
      # noise, so it is left alone.
      binary = String.duplicate(<<0xFF, 0xFE, 0x00>>, 1_000)

      refute String.valid?(binary)
      assert Spill.maybe_spill(binary, ctx: ctx(cfg())) == :inline
    end
  end

  describe "maybe_spill/2 replacement budget" do
    test "the replacement including the notice never exceeds max_inline_bytes" do
      max = 4096

      for size <- [max + 1, max * 10, max * 1000],
          id <- ["short", String.duplicate("i", 512)] do
        text = String.duplicate("x", size)
        config = cfg(%{max_inline_bytes: max, opts: [id: id]})

        assert {:spilled, replacement, _locator} = Spill.maybe_spill(text, ctx: ctx(config))

        assert byte_size(replacement) <= max,
               "size=#{size} id_bytes=#{byte_size(id)} produced #{byte_size(replacement)} bytes"
      end
    end

    test "a long locator id eats the preview budget, not the ceiling" do
      config = fn id -> cfg(%{max_inline_bytes: 4096, opts: [id: id]}) end
      text = String.duplicate("x", 100_000)

      assert {:spilled, short, _} = Spill.maybe_spill(text, ctx: ctx(config.("i")))

      assert {:spilled, long, _} =
               Spill.maybe_spill(text, ctx: ctx(config.(String.duplicate("i", 512))))

      # Both spend the whole ceiling; what the long id displaces is preview, so
      # the count of omitted bytes — not the replacement size — is what grows.
      assert byte_size(long) <= 4096
      assert byte_size(short) <= 4096
      assert omitted(long) - omitted(short) >= 512
    end

    test "every byte is accounted for: preview plus omitted equals the original" do
      text = "HEAD-MARKER" <> String.duplicate("x", 100_000) <> "TAIL-MARKER"
      config = cfg(%{max_inline_bytes: 4096, opts: [id: "acct"]})

      assert {:spilled, replacement, _locator} = Spill.maybe_spill(text, ctx: ctx(config))

      assert [head, rest] = String.split(replacement, "\n(Omitted", parts: 2)
      assert [_notice, tail] = String.split(rest, ")\n", parts: 2)

      assert byte_size(head) + omitted(replacement) + byte_size(tail) == byte_size(text)
      assert String.starts_with?(head, "HEAD-MARKER")
      assert String.ends_with?(tail, "TAIL-MARKER")
    end

    test "the replacement names the locator id and the backend's retrieval hint" do
      config = cfg(%{max_inline_bytes: 200, opts: [id: "spill-42"]})

      assert {:spilled, replacement, locator} =
               Spill.maybe_spill(String.duplicate("x", 10_000), ctx: ctx(config))

      assert locator.id == "spill-42"
      assert replacement =~ "spill-42"
      assert replacement =~ StubStore.retrieval_hint(locator)
      assert replacement =~ "Omitted"
    end

    test "multibyte content produces a valid-UTF-8 replacement" do
      # A byte-budgeted cut through 4-byte codepoints is where a naive slice
      # emits mojibake.
      text = String.duplicate("😀κόσμος", 5_000)
      config = cfg(%{max_inline_bytes: 501, opts: [id: "mb"]})

      assert {:spilled, replacement, _locator} = Spill.maybe_spill(text, ctx: ctx(config))

      assert String.valid?(replacement)
      assert byte_size(replacement) <= 501
    end
  end

  describe "maybe_spill/2 best effort" do
    test "a backend error yields :inline and logs, leaving the result untouched" do
      text = String.duplicate("a", 5_000)
      config = cfg(%{opts: [fail: :enospc]})

      log = capture_log(fn -> assert Spill.maybe_spill(text, ctx: ctx(config)) == :inline end)

      assert log =~ "Nous.Spill"
      assert log =~ "StubStore"
      assert log =~ ":enospc"
      # The caller keeps its successful tool result verbatim.
      assert text == String.duplicate("a", 5_000)
    end
  end

  describe "save_text/2, fetch/1 and retrieval_hint/1" do
    test "save_text/2 injects the configured opts and round-trips through fetch/1" do
      attrs = %{
        owner: "session-a",
        source: "file_grep",
        suggested_name: "grep.txt",
        content: "content"
      }

      assert {:ok, locator} = Spill.save_text(cfg(%{opts: [id: "injected"]}), attrs)
      assert locator.id == "injected"
      assert locator.name == "grep.txt"
      assert Spill.fetch(locator) == {:ok, "content"}
      assert Spill.retrieval_hint(locator) == "Stub hint: ask for injected."
    end

    test "spilled content is retrievable through the locator" do
      text = String.duplicate("payload ", 1_000)

      assert {:spilled, _replacement, locator} = Spill.maybe_spill(text, ctx: ctx(cfg()))
      assert Spill.fetch(locator) == {:ok, text}
      assert locator.bytes == byte_size(text)
    end

    test "attrs default when the caller names neither owner, source, nor name" do
      assert {:spilled, _replacement, locator} =
               Spill.maybe_spill(String.duplicate("a", 5_000), ctx: ctx(cfg()))

      assert locator.name == "result.txt"
    end
  end

  # The omitted-byte count the notice reports, which is the visible half of the
  # budget accounting.
  defp omitted(replacement) do
    assert [_all, count] = Regex.run(~r/\(Omitted (\d+) bytes\./, replacement)
    String.to_integer(count)
  end
end
