defmodule Nous.HTTP.Backend.HackneyTest do
  # async: false — the "raises instead of mislabelling" test makes the
  # `:hackney` module genuinely unloadable for its duration, which is
  # VM-global. See the comment on that test.
  use ExUnit.Case, async: false

  alias Nous.HTTP.Backend.Hackney

  setup do
    {:ok, _} = Application.ensure_all_started(:hackney)
    bypass = Bypass.open()
    {:ok, bypass: bypass, url: "http://localhost:#{bypass.port}/v1/test"}
  end

  # `post/4` used to wrap BOTH `JSON.encode!/1` and the request in one bare
  # `rescue error ->`, so anything that raised on the transport path came back
  # as `%{reason: :json_encode_error}`. These two halves have to be read
  # together: the negative alone would pass against a backend that never
  # reports an encode error at all, and the positive alone would pass against
  # the bare rescue that reported everything as one.
  describe "encode failures are reported as encode failures" do
    test "a term with no JSON.Encoder implementation", %{bypass: bypass, url: url} do
      # A stub, not an expectation: nothing may reach the wire, because the
      # body never got encoded.
      Bypass.stub(bypass, "POST", "/v1/test", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:error, %{reason: :json_encode_error, details: details}} =
               Hackney.post(url, %{"tuple" => {1, 2}}, [], [])

      assert %Protocol.UndefinedError{} = details
    end

    test "invalid UTF-8 in a value", %{bypass: bypass, url: url} do
      Bypass.stub(bypass, "POST", "/v1/test", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      # `JSON.encode!/1` raises ErlangError ({:invalid_byte, 255}) here, not
      # Protocol.UndefinedError — narrowing the rescue to the protocol error
      # alone would let this escape as a raise.
      assert {:error, %{reason: :json_encode_error, details: %ErlangError{}}} =
               Hackney.post(url, %{"bin" => <<0xFF, 0xFE>>}, [], [])
    end
  end

  describe "transport failures are not reported as encode failures" do
    test "a refused connection surfaces hackney's own reason", %{bypass: bypass, url: url} do
      Bypass.down(bypass)

      assert {:error, reason} = Hackney.post(url, %{"x" => 1}, [], [])
      refute match?(%{reason: :json_encode_error}, reason)
      assert reason == :econnrefused
    end

    test "an exception on the transport path propagates instead of being relabelled", %{
      url: url
    } do
      # The exact shape of the original defect: with `:hackney` absent,
      # `:hackney.request/5` raises UndefinedFunctionError, and the old rescue
      # turned that into `%{reason: :json_encode_error}` — a confidently wrong
      # error pointing at the wrong subsystem. Reproducing it needs the module
      # to actually be gone, and hackney is a dev/test dep of nous itself, so
      # the ebin comes off the code path and the module is purged. Restored in
      # on_exit; safe because this module is `async: false`, so ExUnit runs it
      # with nothing else in flight.
      ebin = :code.lib_dir(:hackney) ++ ~c"/ebin"
      :code.del_path(ebin)
      :code.purge(:hackney)
      :code.delete(:hackney)
      :code.purge(:hackney)

      on_exit(fn ->
        :code.add_pathz(ebin)
        Code.ensure_loaded?(:hackney)
      end)

      refute Code.ensure_loaded?(:hackney),
             "precondition failed: :hackney is still loadable, this test proves nothing"

      assert_raise UndefinedFunctionError, fn ->
        Hackney.post(url, %{"x" => 1}, [], [])
      end
    end
  end

  test "a body that encodes still reaches the wire", %{bypass: bypass, url: url} do
    Bypass.expect_once(bypass, "POST", "/v1/test", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(raw) == %{"x" => 1}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok": true}))
    end)

    assert {:ok, %{"ok" => true}} = Hackney.post(url, %{"x" => 1}, [], [])
  end
end
