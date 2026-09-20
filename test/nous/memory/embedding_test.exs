defmodule Nous.Memory.EmbeddingTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Embedding
  alias Nous.Memory.Embedding.Local

  @moduletag :capture_log

  # Exercises the concurrent fallback: no embed_batch/2 exported, so
  # Embedding.embed_batch/3 must fan out over embed/2 itself.
  defmodule FallbackOnly do
    @moduledoc false
    @behaviour Nous.Memory.Embedding

    @impl true
    def embed("crash " <> _rest, _opts), do: raise("provider exploded")
    def embed("error " <> tag, _opts), do: {:error, {:embed_failed, tag}}
    def embed(text, _opts), do: {:ok, [String.length(text) * 1.0]}

    @impl true
    def dimension, do: 1
  end

  defmodule BatchCapable do
    @moduledoc false
    @behaviour Nous.Memory.Embedding

    @impl true
    def embed(_text, _opts), do: {:ok, [:per_text_path_must_not_run]}

    @impl true
    def embed_batch(texts, _opts), do: {:ok, Enum.map(texts, fn _ -> [42.0] end)}

    @impl true
    def dimension, do: 1
  end

  describe "embed_batch/3 fallback (provider without embed_batch/2)" do
    test "embeds every text via embed/2, preserving input order" do
      assert {:ok, [[1.0], [2.0], [3.0]]} =
               Embedding.embed_batch(FallbackOnly, ["a", "bb", "ccc"])
    end

    test "returns the first error in input order" do
      texts = ["ok", "error one", "error two"]

      assert {:error, {:embed_failed, "one"}} = Embedding.embed_batch(FallbackOnly, texts)
    end

    test "a crashing provider surfaces as {:error, {:exit, _}} instead of crashing the caller" do
      # async_stream_nolink is load-bearing here: a linked Task.async_stream
      # would take this test process down with the raising worker.
      assert {:error, {:exit, {%RuntimeError{message: "provider exploded"}, _stack}}} =
               Embedding.embed_batch(FallbackOnly, ["fine", "crash now"])
    end
  end

  describe "embed_batch/3 with a batch-capable provider" do
    test "uses the provider's embed_batch/2 verbatim, never the per-text path" do
      assert {:ok, [[42.0], [42.0]]} = Embedding.embed_batch(BatchCapable, ["a", "b"])
    end

    test "a provider that is on the code path but not yet loaded still takes the batch path" do
      # function_exported?/3 alone answers false for an unloaded module, which
      # would drop this provider into the per-text fallback. Compile a
      # provider to a beam on disk, unload it, and only then call through.
      mod = Module.concat(__MODULE__, "Lazy#{System.unique_integer([:positive])}")
      dir = Path.join(System.tmp_dir!(), "nous-embedding-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      source = """
      defmodule #{inspect(mod)} do
        @behaviour Nous.Memory.Embedding

        @impl true
        def embed(_text, opts) do
          send(opts[:notify], :single_called)
          {:ok, [0.0]}
        end

        @impl true
        def embed_batch(texts, opts) do
          send(opts[:notify], {:batch_called, texts})
          {:ok, Enum.map(texts, fn _ -> [1.0] end)}
        end

        @impl true
        def dimension, do: 1
      end
      """

      [{^mod, beam}] = Code.compile_string(source)
      File.write!(Path.join(dir, "#{mod}.beam"), beam)
      true = Code.append_path(dir)

      on_exit(fn ->
        Code.delete_path(dir)
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
        File.rm_rf!(dir)
      end)

      # compile_string loads the module; put it back to "on disk only".
      :code.purge(mod)
      true = :code.delete(mod)
      :code.purge(mod)
      refute :code.is_loaded(mod)

      assert {:ok, [[1.0], [1.0]]} = Embedding.embed_batch(mod, ["a", "b"], notify: self())
      assert_received {:batch_called, ["a", "b"]}
      refute_received :single_called
    end
  end

  describe "Local provider" do
    setup do
      bypass = Bypass.open()
      test_pid = self()

      # Deterministic per-text vector so batch results can be compared with
      # per-text embed/2 results. `data` is served in REVERSE index order to
      # prove the client orders by `index`, not by position.
      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        %{"input" => input} = JSON.decode!(raw)
        send(test_pid, {:request, input})

        data =
          input
          |> List.wrap()
          |> Enum.with_index(fn text, i ->
            %{"index" => i, "embedding" => [byte_size(text) * 1.0]}
          end)
          |> Enum.reverse()

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{"data" => data}))
      end)

      %{opts: [base_url: "http://localhost:#{bypass.port}/v1"], bypass: bypass}
    end

    test "embed_batch/2 returns one vector per text, in input order, matching embed/2", %{
      opts: opts
    } do
      texts = ["a", "bb", "ccc"]

      assert {:ok, batch} = Local.embed_batch(texts, opts)
      assert_received {:request, ["a", "bb", "ccc"]}

      singles =
        Enum.map(texts, fn t ->
          assert {:ok, emb} = Local.embed(t, opts)
          emb
        end)

      assert batch == singles
      assert batch == [[1.0], [2.0], [3.0]]
    end

    test "embed_batch/2 of an empty list makes no request", %{bypass: bypass, opts: opts} do
      assert {:ok, []} = Local.embed_batch([], opts)
      refute_received {:request, _}
      # The setup expectation is deliberately unmet: no request is the point.
      Bypass.pass(bypass)
    end

    test "embed_batch/2 rejects a response with the wrong number of vectors", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{"data" => [%{"index" => 0, "embedding" => [1.0]}]}))
      end)

      assert {:error, {:unexpected_response, [_]}} = Local.embed_batch(["a", "b"], opts)
    end

    test "Embedding.embed_batch/3 takes Local's native path: one request for the whole list", %{
      opts: opts
    } do
      assert Code.ensure_loaded?(Local) and function_exported?(Local, :embed_batch, 2)

      assert {:ok, [[1.0], [2.0]]} = Embedding.embed_batch(Local, ["a", "bb"], opts)
      assert_received {:request, ["a", "bb"]}
      refute_received {:request, _}
    end
  end
end
