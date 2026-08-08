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

  describe "string_length/2 on multibyte text" do
    test "separates grapheme count from byte size" do
      # Every ASCII case in this file has length == byte_size, so the two
      # fields are indistinguishable there.
      assert %{length: 5, byte_size: 6, grapheme_count: 5} =
               StringTools.string_length(nil, %{"text" => "héllo"})

      assert %{length: 1, byte_size: 4} = StringTools.string_length(nil, %{"text" => "👍"})
    end
  end

  describe "replace_text/2 case-insensitive path" do
    test "replaces every case variant and counts them" do
      result =
        StringTools.replace_text(nil, %{
          "text" => "Hello hello HELLO",
          "pattern" => "hello",
          "replacement" => "hi",
          "case_sensitive" => false
        })

      assert result.result == "hi hi hi"
      assert result.replacements_made == 3
    end

    test "the pattern is matched literally, not as a regex" do
      # The pattern comes from the model. Without `Regex.escape/1` the `.`
      # below matches the `b` in "abc" and the tool silently edits text the
      # caller never asked it to touch.
      result =
        StringTools.replace_text(nil, %{
          "text" => "abc a.c",
          "pattern" => "a.c",
          "replacement" => "X",
          "case_sensitive" => false
        })

      assert result.result == "abc X"
      assert result.replacements_made == 1
    end
  end

  describe "count_occurrences/2 edge cases" do
    test "an empty pattern counts zero rather than dividing by it" do
      # `div(_, String.length(pattern))` is an ArithmeticError without the
      # empty-pattern guard, on both branches.
      for case_sensitive <- [true, false] do
        assert %{count: 0} =
                 StringTools.count_occurrences(nil, %{
                   "text" => "anything",
                   "pattern" => "",
                   "case_sensitive" => case_sensitive
                 })
      end
    end

    test "case-insensitive counting treats the pattern literally" do
      assert %{count: 3} =
               StringTools.count_occurrences(nil, %{
                 "text" => "Ab ab AB",
                 "pattern" => "ab",
                 "case_sensitive" => false
               })

      assert %{count: 1} =
               StringTools.count_occurrences(nil, %{
                 "text" => "a+b aXb",
                 "pattern" => "A+B",
                 "case_sensitive" => false
               })
    end
  end

  describe "join_text/2" do
    test "accepts a list of parts" do
      assert %{result: "a-b-c", length: 5, parts: ["a", "b", "c"]} =
               StringTools.join_text(nil, %{"parts" => ["a", "b", "c"], "delimiter" => "-"})
    end

    test "accepts a comma-separated string and defaults the delimiter to a space" do
      assert %{result: "a b c", parts: ["a", "b", "c"]} =
               StringTools.join_text(nil, %{"parts" => "a,b,c"})
    end

    test "a non-list, non-string parts value yields an empty join" do
      assert %{parts: [], result: "", length: 0} =
               StringTools.join_text(nil, %{"parts" => 123})
    end
  end

  describe "capitalize_text/2" do
    test "each mode reshapes the text differently" do
      cases = [
        {"words", "hELLO wORLD", "Hello World"},
        {"first", "hELLO wORLD", "Hello world"},
        {"sentences", "hello there. how are you", "Hello there. How are you"},
        # An unrecognised mode must still return usable text.
        {"shouting", "hELLO wORLD", "Hello world"}
      ]

      for {mode, text, expected} <- cases do
        assert %{result: ^expected, mode: ^mode} =
                 StringTools.capitalize_text(nil, %{"text" => text, "mode" => mode})
      end
    end

    test "words is the default mode" do
      assert %{result: "Hello World"} =
               StringTools.capitalize_text(nil, %{"text" => "hello world"})
    end
  end

  describe "trim_text/2" do
    test "each side trims only its own end and reports the characters removed" do
      cases = [
        {"left", "hi  ", 2},
        {"right", "  hi", 2},
        {"both", "hi", 4},
        {"sideways", "hi", 4}
      ]

      for {side, expected, removed} <- cases do
        assert %{result: ^expected, chars_removed: ^removed} =
                 StringTools.trim_text(nil, %{"text" => "  hi  ", "side" => side})
      end
    end
  end

  describe "substring/2" do
    test "start and length select a window" do
      assert %{result: "world", start: 6, length: 5} =
               StringTools.substring(nil, %{"text" => "hello world", "start" => 6, "length" => 5})
    end

    test "\"end\" is inclusive, so it selects one more character than the offset gap" do
      assert %{result: "world"} =
               StringTools.substring(nil, %{"text" => "hello world", "start" => 6, "end" => 10})
    end

    test "an omitted length runs to the end of the string" do
      assert %{result: "world", length: nil} =
               StringTools.substring(nil, %{"text" => "hello world", "start" => 6})
    end

    test "a start past the end yields an empty string rather than an error" do
      assert %{result: ""} = StringTools.substring(nil, %{"text" => "hi", "start" => 99})
    end
  end

  describe "contains/2, starts_with/2 and ends_with/2" do
    test "case-insensitive matching is opt-in" do
      assert %{contains: false} =
               StringTools.contains(nil, %{"text" => "Hello", "pattern" => "HELL"})

      assert %{contains: true} =
               StringTools.contains(nil, %{
                 "text" => "Hello",
                 "pattern" => "HELL",
                 "case_sensitive" => false
               })
    end

    test "prefixes and suffixes are anchored to their own end" do
      args = %{"text" => "Hello world", "prefix" => "world", "suffix" => "Hello"}

      assert %{starts_with: false} = StringTools.starts_with(nil, args)
      assert %{ends_with: false} = StringTools.ends_with(nil, args)

      assert %{starts_with: true} =
               StringTools.starts_with(nil, %{
                 "text" => "Hello world",
                 "prefix" => "HELLO",
                 "case_sensitive" => false
               })

      assert %{ends_with: true} =
               StringTools.ends_with(nil, %{
                 "text" => "Hello world",
                 "suffix" => "WORLD",
                 "case_sensitive" => false
               })
    end
  end

  describe "reverse_text/2" do
    test "reverses graphemes, not bytes" do
      assert %{result: "lëon"} = StringTools.reverse_text(nil, %{"text" => "noël"})
      assert %{result: "cba"} = StringTools.reverse_text(nil, %{"text" => "abc"})
    end
  end

  describe "repeat_text/2" do
    test "caps the repeat count at 100 whatever the model asks for" do
      # The only bound on the size of this tool's output.
      result = StringTools.repeat_text(nil, %{"text" => "ab", "times" => 10_000})

      assert result.times == 100
      assert result.result_length == 200
      assert String.length(result.result) == 200
    end

    test "a count under the cap is honoured, and one is the default" do
      assert %{times: 3, result: "ababab"} =
               StringTools.repeat_text(nil, %{"text" => "ab", "times" => 3})

      assert %{times: 1, result: "ab"} = StringTools.repeat_text(nil, %{"text" => "ab"})
    end
  end

  describe "extract_words/2" do
    test "splits on non-word characters and filters by minimum length" do
      result =
        StringTools.extract_words(nil, %{
          "text" => "the quick, brown; fox! the",
          "min_length" => 4
        })

      assert result.words == ["quick", "brown"]
      assert result.word_count == 2
    end

    test "word_count counts occurrences while unique_words counts distinct ones" do
      result = StringTools.extract_words(nil, %{"text" => "bb bb ccc"})

      assert result.words == ["bb", "bb", "ccc"]
      assert result.word_count == 3
      assert result.unique_words == 2
    end
  end

  describe "pad_text/2" do
    test "pads on the requested side" do
      cases = [
        {"left", "****ab"},
        {"right", "ab****"},
        # Odd padding goes to the trailing side.
        {"both", "**ab**"},
        {"middle", "ab****"}
      ]

      for {side, expected} <- cases do
        assert %{result: ^expected, result_length: 6} =
                 StringTools.pad_text(nil, %{
                   "text" => "ab",
                   "length" => 6,
                   "padding" => "*",
                   "side" => side
                 })
      end
    end

    test "an odd gap leaves the extra character on the trailing side" do
      assert %{result: "*ab**"} =
               StringTools.pad_text(nil, %{
                 "text" => "ab",
                 "length" => 5,
                 "padding" => "*",
                 "side" => "both"
               })
    end

    test "a target shorter than the text leaves it untouched" do
      assert %{result: "abcdef", result_length: 6} =
               StringTools.pad_text(nil, %{"text" => "abcdef", "length" => 2})
    end
  end

  describe "is_palindrome/2" do
    test "the two normalisations each change the verdict" do
      text = "A man a plan a canal Panama"

      assert %{is_palindrome: true, processed_text: "amanaplanacanalpanama"} =
               StringTools.is_palindrome(nil, %{"text" => text})

      assert %{is_palindrome: false} =
               StringTools.is_palindrome(nil, %{"text" => text, "ignore_case" => false})

      assert %{is_palindrome: false} =
               StringTools.is_palindrome(nil, %{"text" => text, "ignore_spaces" => false})
    end

    test "a non-palindrome is reported as such" do
      assert %{is_palindrome: false} = StringTools.is_palindrome(nil, %{"text" => "hello"})
    end
  end

  describe "extract_numbers/2" do
    test "finds integers, decimals and negatives, and sums them" do
      result = StringTools.extract_numbers(nil, %{"text" => "3.14 apples, -2 pears and 10 figs"})

      assert result.numbers_found == ["3.14", "-2", "10"]
      assert result.count == 3
      assert_in_delta result.sum, 11.14, 0.0001
    end

    test "text with no digits sums to zero rather than erroring" do
      assert %{count: 0, numbers_found: [], parsed_numbers: [], sum: 0} =
               StringTools.extract_numbers(nil, %{"text" => "no digits here"})
    end
  end
end
