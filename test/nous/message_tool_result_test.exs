defmodule Nous.MessageToolResultTest do
  use ExUnit.Case, async: true

  alias Nous.Message

  # A tool returning bytes that are not valid UTF-8 is ordinary — `file_read`
  # on a binary, `bash` stdout from a command that emits one. `JSON.encode!/1`
  # raises ErlangError ({:invalid_byte, _}) on those, and the raise does not
  # happen here: the message is built fine and the request blows up later, in
  # the provider's encode of the whole body, where nothing recovers it.
  #
  # `provider_encode/1` stands in for that: it is the assertion that matters,
  # because a Message whose content cannot be serialised is a dead run, not a
  # degraded one.
  @bad_bytes <<"hello ", 0xFF, 0xFE, " world">>

  defp provider_encode(%Message{} = message) do
    JSON.encode!(%{"messages" => [%{"role" => "tool", "content" => message.content}]})
  end

  describe "invalid UTF-8 never reaches the wire" do
    test "a raw binary tool result is repaired" do
      message = Message.tool("call_1", @bad_bytes, name: "bash")

      assert String.valid?(message.content)
      assert message.content =~ "hello"
      assert message.content =~ "world"
      assert is_binary(provider_encode(message))
    end

    test "an invalid binary nested in a result map is repaired" do
      message = Message.tool("call_1", %{"stdout" => @bad_bytes}, name: "bash")

      assert %{"stdout" => stdout} = JSON.decode!(message.content)
      assert String.valid?(stdout)
      assert stdout =~ "hello"
      assert is_binary(provider_encode(message))
    end

    test "an invalid binary used as a map key is repaired" do
      message = Message.tool("call_1", %{@bad_bytes => 1}, name: "bash")

      assert [{key, 1}] = message.content |> JSON.decode!() |> Map.to_list()
      assert String.valid?(key)
      assert is_binary(provider_encode(message))
    end

    test "a bitstring that is not byte-aligned does not crash the walk" do
      # Reaches :json.encode_binary/2 and raises FunctionClauseError, which the
      # rescue deliberately does not catch — so this has to be handled by
      # sanitisation or not at all.
      message = Message.tool("call_1", %{"bits" => <<1::size(3)>>}, name: "probe")

      assert %{"bits" => "<<1::size(3)>>"} = JSON.decode!(message.content)
      assert is_binary(provider_encode(message))
    end
  end

  # The other half: repairing must not touch anything that was already fine,
  # and must not silently swallow the existing conversions. Without these, a
  # `sanitize_for_json/1` that returned `inspect(value)` for every input would
  # pass every test above.
  describe "well-formed results are untouched" do
    test "a valid binary result is passed through byte-identical" do
      content = "search returned 3 results — ünïcödé and emoji 🎉 included"

      assert %Message{content: ^content} = Message.tool("call_1", content, name: "search")
    end

    test "a map result still encodes to plain JSON" do
      assert %Message{content: ~s({"status":"success"})} =
               Message.tool("call_1", %{status: "success"})
    end

    test "BEAM-only values still become their inspect form rather than crashing" do
      message =
        Message.tool(
          "call_1",
          %{"at" => ~U[2026-01-01 00:00:00Z], "pid" => self(), "set" => MapSet.new([1, 2])},
          name: "probe"
        )

      decoded = JSON.decode!(message.content)

      assert decoded["at"] == "2026-01-01T00:00:00Z"
      assert decoded["pid"] == inspect(self())
      assert Enum.sort(decoded["set"]) == [1, 2]
    end

    test "a value with no JSON.Encoder implementation still falls back to inspect" do
      # `sanitize_for_json/1` turns a function into its inspect form; the point
      # here is that the tool message is built at all rather than raising.
      message = Message.tool("call_1", %{"fun" => &String.length/1}, name: "probe")

      assert %{"fun" => fun_repr} = JSON.decode!(message.content)
      assert fun_repr =~ "String.length"
    end
  end
end
