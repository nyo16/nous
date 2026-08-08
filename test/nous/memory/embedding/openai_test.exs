defmodule Nous.Memory.Embedding.OpenAITest do
  # async: false — the missing-key tests have to delete OPENAI_API_KEY, which
  # is process-global. Every other test passes :api_key explicitly.
  use ExUnit.Case, async: false

  alias Nous.Memory.Embedding.OpenAI

  @api_key "sk-embed-test"

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}/v1"}
  end

  defp read_json_body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {JSON.decode!(raw), conn}
  end

  defp respond_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  # Reports the request it saw so the wire format — key, model, input shape —
  # can be asserted rather than inferred from the return value.
  defp expect_embeddings(bypass, owner, data) do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      {body, conn} = read_json_body(conn)
      send(owner, {:embed_request, conn.req_headers, body})
      respond_json(conn, 200, %{"data" => data})
    end)
  end

  describe "embed/2" do
    test "sends the text and returns the single embedding", %{bypass: bypass, base: base} do
      expect_embeddings(bypass, self(), [%{"index" => 0, "embedding" => [0.1, 0.2, 0.3]}])

      assert {:ok, [0.1, 0.2, 0.3]} =
               OpenAI.embed("hello", api_key: @api_key, base_url: base)

      assert_received {:embed_request, headers, body}
      # The key is the whole point of this module reaching the network.
      assert {"authorization", "Bearer #{@api_key}"} in headers
      assert body["input"] == "hello"
      assert body["model"] == "text-embedding-3-small"
    end

    test "the model option overrides the default", %{bypass: bypass, base: base} do
      expect_embeddings(bypass, self(), [%{"index" => 0, "embedding" => [1.0]}])

      assert {:ok, [1.0]} =
               OpenAI.embed("hello",
                 api_key: @api_key,
                 base_url: base,
                 model: "text-embedding-3-large"
               )

      assert_received {:embed_request, _headers, body}
      assert body["model"] == "text-embedding-3-large"
    end

    test "a non-200 surfaces the status and body instead of a vector", %{
      bypass: bypass,
      base: base
    } do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        respond_json(conn, 429, %{"error" => %{"message" => "rate limited"}})
      end)

      assert {:error, %{status: 429, body: body}} =
               OpenAI.embed("hello", api_key: @api_key, base_url: base)

      assert body["error"]["message"] == "rate limited"
    end

    test "a transport failure is returned, not raised", %{bypass: bypass, base: base} do
      Bypass.down(bypass)

      assert {:error, %Req.TransportError{}} =
               OpenAI.embed("hello", api_key: @api_key, base_url: base)
    end
  end

  describe "embed_batch/2" do
    test "sends the whole list and restores provider order by index", %{
      bypass: bypass,
      base: base
    } do
      # OpenAI does not promise response order; the sort is what keeps
      # embeddings aligned with the texts the caller passed in. Returning the
      # rows shuffled is the only way to see the sort actually run.
      expect_embeddings(bypass, self(), [
        %{"index" => 2, "embedding" => [3.0]},
        %{"index" => 0, "embedding" => [1.0]},
        %{"index" => 1, "embedding" => [2.0]}
      ])

      assert {:ok, [[1.0], [2.0], [3.0]]} =
               OpenAI.embed_batch(["one", "two", "three"], api_key: @api_key, base_url: base)

      assert_received {:embed_request, _headers, body}
      assert body["input"] == ["one", "two", "three"]
      assert body["model"] == "text-embedding-3-small"
    end

    test "a non-200 surfaces the status and body", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        respond_json(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, %{status: 500, body: %{"error" => "boom"}}} =
               OpenAI.embed_batch(["one"], api_key: @api_key, base_url: base)
    end

    test "a transport failure is returned, not raised", %{bypass: bypass, base: base} do
      Bypass.down(bypass)

      assert {:error, %Req.TransportError{}} =
               OpenAI.embed_batch(["one"], api_key: @api_key, base_url: base)
    end
  end

  describe "missing credentials" do
    setup do
      previous = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      on_exit(fn ->
        if previous, do: System.put_env("OPENAI_API_KEY", previous)
      end)

      :ok
    end

    test "embed/2 fails closed without issuing a request", %{bypass: bypass, base: base} do
      # Bypass.stub registers no expectation, so a request arriving here would
      # be recorded as an unexpected call; the counter below is the direct
      # proof that nothing was sent.
      owner = self()

      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        send(owner, :unexpected_request)
        respond_json(conn, 200, %{"data" => []})
      end)

      assert {:error, message} = OpenAI.embed("hello", base_url: base)
      assert message =~ "OpenAI API key required"

      refute_received :unexpected_request
    end

    test "embed_batch/2 fails closed without issuing a request", %{bypass: bypass, base: base} do
      owner = self()

      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        send(owner, :unexpected_request)
        respond_json(conn, 200, %{"data" => []})
      end)

      assert {:error, message} = OpenAI.embed_batch(["hello"], base_url: base)
      assert message =~ "OpenAI API key required"

      refute_received :unexpected_request
    end

    test "an explicit api_key still wins over the absent env var", %{
      bypass: bypass,
      base: base
    } do
      expect_embeddings(bypass, self(), [%{"index" => 0, "embedding" => [0.5]}])

      assert {:ok, [0.5]} = OpenAI.embed("hello", api_key: @api_key, base_url: base)
    end
  end

  describe "dimension/0" do
    test "reports the width callers size their vector columns to" do
      assert OpenAI.dimension() == 1536
    end
  end
end
