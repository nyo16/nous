defmodule Nous.JSONTest do
  use ExUnit.Case, async: true

  alias Nous.JSON, as: NousJSON

  # pretty_encode!/1 walks the encoded binary directly rather than exploding it
  # into graphemes first. The contract that has to survive that: the output is
  # still valid JSON that decodes back to the original term, byte-for-byte
  # identical string content included.
  describe "pretty_encode!/1 round-trips" do
    test "primitives, containers, and nesting" do
      terms = [
        %{},
        [],
        %{"a" => 1},
        [1, 2, 3],
        %{"a" => [1, 2, %{"b" => nil}], "c" => %{}},
        %{"deep" => %{"a" => %{"b" => %{"c" => [[], %{}, [%{}]]}}}},
        [1.5, -2, true, false, nil],
        %{"big" => 123_456_789_012_345}
      ]

      for term <- terms do
        assert term |> NousJSON.pretty_encode!() |> JSON.decode!() == term
      end
    end

    test "strings containing JSON metacharacters" do
      term = %{
        "quotes" => ~s(he said "hi"),
        "backslash" => "a\\b\\\\c",
        "control" => "line\nbreak\ttab",
        "solidus" => "a/b",
        "braces" => "{not: [an, object]}",
        "colon_comma" => "a:b, c:d",
        "spaces" => "  padded  "
      }

      assert term |> NousJSON.pretty_encode!() |> JSON.decode!() == term
    end

    test "multi-byte UTF-8 survives unchanged" do
      term = %{
        "greek" => "αβγδε",
        "cjk" => "日本語のテキスト",
        "emoji" => "🌍🚀👩‍💻",
        "accents" => "héllo ünïcødé",
        "mixed" => "a\"b🌍c\\d"
      }

      pretty = NousJSON.pretty_encode!(term)

      assert JSON.decode!(pretty) == term
      # Not mangled into escapes or replacement characters on the way through.
      assert pretty =~ "🌍🚀👩‍💻"
      assert pretty =~ "日本語のテキスト"
    end

    test "a large document round-trips" do
      term = for i <- 1..500, into: %{}, do: {"key_#{i}", "value ü 🌍 #{i}"}

      assert term |> NousJSON.pretty_encode!() |> JSON.decode!() == term
    end
  end

  describe "pretty_encode!/1 formatting" do
    test "indents nested structures" do
      assert NousJSON.pretty_encode!(%{"a" => %{"b" => [1, 2]}}) == """
             {
               "a": {
                 "b": [
                   1,
                   2
                 ]
               }
             }\
             """
    end

    test "does not indent empty containers" do
      # The empty-container peek suppresses the indent bump, not the newline.
      assert NousJSON.pretty_encode!(%{"a" => %{}}) == "{\n  \"a\": {\n}\n}"
      assert NousJSON.pretty_encode!(%{"a" => []}) == "{\n  \"a\": [\n]\n}"
      assert NousJSON.pretty_encode!(%{}) == "{\n}"
      assert NousJSON.pretty_encode!([]) == "[\n]"
    end

    test "does not reformat inside string values" do
      # Spaces are stripped outside strings but must be preserved inside them.
      assert NousJSON.pretty_encode!(%{"k" => "a  b, c: d"}) == "{\n  \"k\": \"a  b, c: d\"\n}"
    end

    test "encodes a bare string" do
      assert NousJSON.pretty_encode!("plain") == "\"plain\""
    end
  end
end
