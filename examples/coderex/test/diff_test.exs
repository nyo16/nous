defmodule Coderex.DiffTest do
  use ExUnit.Case
  alias Coderex.Diff

  describe "construct_new_content/3" do
    test "simple replacement" do
      original = "hello world"
      diff = """
      ------- SEARCH
      hello world
      =======
      hello universe
      +++++++ REPLACE
      """

      assert {:ok, result} = Diff.construct_new_content(diff, original)
      assert result == "hello universe\n"
    end

    test "replacement with multiple lines" do
      original = """
      def hello do
        :world
      end
      """

      diff = """
      ------- SEARCH
      def hello do
        :world
      end
      =======
      def hello do
        :universe
      end
      +++++++ REPLACE
      """

      assert {:ok, result} = Diff.construct_new_content(diff, original)
      assert result =~ ":universe"
      refute result =~ ":world"
    end

    test "multiple replacements" do
      original = """
      foo
      bar
      baz
      """

      diff = """
      ------- SEARCH
      foo
      =======
      FOO
      +++++++ REPLACE
      ------- SEARCH
      baz
      =======
      BAZ
      +++++++ REPLACE
      """

      assert {:ok, result} = Diff.construct_new_content(diff, original)
      assert result =~ "FOO"
      assert result =~ "bar"
      assert result =~ "BAZ"
    end

    test "deletion (empty replace)" do
      original = """
      keep this
      delete this
      keep this too
      """

      diff = """
      ------- SEARCH
      delete this
      =======
      +++++++ REPLACE
      """

      assert {:ok, result} = Diff.construct_new_content(diff, original)
      assert result =~ "keep this"
      assert result =~ "keep this too"
      refute result =~ "delete this"
    end

    test "error when search doesn't match" do
      original = "hello world"
      diff = """
      ------- SEARCH
      not found
      =======
      replacement
      +++++++ REPLACE
      """

      assert {:error, reason} = Diff.construct_new_content(diff, original)
      assert reason =~ "does not match"
    end

    test "new file (empty original with empty search)" do
      original = ""
      diff = """
      ------- SEARCH
      =======
      new content
      +++++++ REPLACE
      """

      assert {:ok, result} = Diff.construct_new_content(diff, original)
      assert result == "new content\n"
    end

    test "whitespace-tolerant matching" do
      original = "  hello world  "
      diff = """
      ------- SEARCH
      hello world
      =======
      hello universe
      +++++++ REPLACE
      """

      assert {:ok, result} = Diff.construct_new_content(diff, original)
      assert result =~ "hello universe"
    end

    test "legacy markers (<<< and >>>)" do
      original = "hello world"
      diff = """
      <<<<<<< SEARCH
      hello world
      =======
      hello universe
      >>>>>>> REPLACE
      """

      assert {:ok, result} = Diff.construct_new_content(diff, original)
      assert result == "hello universe\n"
    end
  end

  describe "make_block/2" do
    test "creates properly formatted block" do
      block = Diff.make_block("old code", "new code")

      assert block =~ "------- SEARCH"
      assert block =~ "======="
      assert block =~ "+++++++ REPLACE"
      assert block =~ "old code"
      assert block =~ "new code"
    end
  end

  describe "line_trimmed_fallback_match/3" do
    test "matches with different indentation" do
      original = "    hello world\n    foo bar"
      search = "hello world\nfoo bar"

      result = Diff.line_trimmed_fallback_match(original, search, 0)
      assert result != nil
      {start_idx, _end_idx} = result
      assert start_idx == 0
    end
  end

  describe "block_anchor_fallback_match/3" do
    test "matches using first and last line anchors" do
      original = """
      function start() {
        // some code
        // that might differ
      }
      """

      search = """
      function start() {
        // different middle
        // content here
      }
      """

      result = Diff.block_anchor_fallback_match(original, search, 0)
      assert result != nil
    end

    test "returns nil for small blocks" do
      original = "line1\nline2"
      search = "line1\nline2"

      result = Diff.block_anchor_fallback_match(original, search, 0)
      assert result == nil
    end
  end
end
