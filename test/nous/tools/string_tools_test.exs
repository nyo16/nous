defmodule Nous.Tools.StringToolsTest do
  use ExUnit.Case, async: true

  alias Nous.Tools.StringTools

  describe "string_length/2" do
    test "returns length for valid string" do
      assert %{length: 11, byte_size: 11} =
               StringTools.string_length(nil, %{"text" => "hello world"})
    end

    test "returns 0 for missing text" do
      assert %{length: 0} = StringTools.string_length(nil, %{})
    end

    test "coerces non-string text to default" do
      # Nil-pun chains used to crash here. Now non-strings degrade to "".
      assert %{length: 0} = StringTools.string_length(nil, %{"text" => 123})
    end
  end

  describe "replace_text/2" do
    test "replaces with primary key 'pattern'" do
      assert %{result: "hi world"} =
               StringTools.replace_text(nil, %{
                 "text" => "hello world",
                 "pattern" => "hello",
                 "replacement" => "hi"
               })
    end

    test "falls back to alias 'old' / 'new'" do
      assert %{result: "hi world"} =
               StringTools.replace_text(nil, %{
                 "text" => "hello world",
                 "old" => "hello",
                 "new" => "hi"
               })
    end

    test "prefers primary key when both keys present" do
      assert %{result: "hi world"} =
               StringTools.replace_text(nil, %{
                 "text" => "hello world",
                 "pattern" => "hello",
                 "old" => "should-be-ignored",
                 "replacement" => "hi",
                 "new" => "should-be-ignored"
               })
    end

    test "non-string pattern degrades to '' rather than crashing the tool call" do
      # The LLM occasionally hands tools args of the wrong type. We don't
      # care what the resulting string-edit looks like for an empty
      # pattern — we care that this DOESN'T raise FunctionClauseError
      # from `String.replace/3` like the old nil-pun chain did.
      result =
        StringTools.replace_text(nil, %{
          "text" => "hello",
          "pattern" => 123,
          "replacement" => "hi"
        })

      assert %{pattern: ""} = result
    end
  end

  describe "split_text/2" do
    test "splits with delimiter alias 'separator'" do
      assert %{parts: ["a", "b", "c"]} =
               StringTools.split_text(nil, %{"text" => "a,b,c", "separator" => ","})
    end

    test "defaults to space delimiter" do
      assert %{parts: ["a", "b"]} = StringTools.split_text(nil, %{"text" => "a b"})
    end
  end

  describe "count_occurrences/2" do
    test "counts with alias 'substring'" do
      assert %{count: 2} =
               StringTools.count_occurrences(nil, %{
                 "text" => "abc abc xyz",
                 "substring" => "abc"
               })
    end
  end

  describe "contains/2" do
    test "checks contains with alias 'substring'" do
      assert %{contains: true} =
               StringTools.contains(nil, %{"text" => "hello", "substring" => "ell"})
    end
  end
end
