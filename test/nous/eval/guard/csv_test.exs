defmodule Nous.Eval.Guard.CSVTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Guard.CSV

  test "parses quoted fields, escapes, embedded newlines, CRLF and a BOM" do
    body = "\uFEFFa,b\r\n\"x, \"\"y\"\"\",\"line\nbreak\"\r\nplain,\r\n"

    assert CSV.parse(body) ==
             {:ok, [%{"a" => "x, \"y\"", "b" => "line\nbreak"}, %{"a" => "plain", "b" => ""}]}
  end

  for {name, body, message} <- [
        {"a record with the wrong field count", "a,b\n1,2\n1,2,3\n",
         "CSV record 3 has 3 fields, the header 2"},
        {"invalid UTF-8 in an unquoted field", "a,b\n1,\xFF\n", "CSV is not valid UTF-8"},
        {"invalid UTF-8 in a quoted field", "a,b\n1,\"x\xFF\"\n", "CSV is not valid UTF-8"},
        {"text after a closing quote", "a,b\n1,\"x\"y\n", "CSV text after a closing quote"},
        {"an unterminated quoted field", "a,b\n1,\"open\n", "CSV ends inside a quoted field"}
      ] do
    test "rejects #{name}" do
      assert CSV.parse(unquote(body)) == {:error, unquote(message)}
    end
  end
end
