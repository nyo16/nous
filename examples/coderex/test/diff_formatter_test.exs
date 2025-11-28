defmodule Coderex.DiffFormatterTest do
  use ExUnit.Case
  alias Coderex.DiffFormatter

  describe "format_diff/4" do
    test "formats simple diff with colors" do
      original = "hello world"
      new_content = "hello universe"

      result = DiffFormatter.format_diff("test.txt", original, new_content, color: true)

      assert result =~ "test.txt"
      assert result =~ "hello"
    end

    test "formats diff without colors" do
      original = "hello world"
      new_content = "hello universe"

      result = DiffFormatter.format_diff("test.txt", original, new_content, color: false)

      assert result =~ "test.txt"
      assert result =~ "━━━"
      refute result =~ "\e["  # No ANSI codes
    end
  end

  describe "format_search_replace/4" do
    test "formats search/replace sections" do
      search = "old code"
      replace = "new code"

      result = DiffFormatter.format_search_replace("test.txt", search, replace, color: false)

      assert result =~ "SEARCH:"
      assert result =~ "REPLACE:"
      assert result =~ "old code"
      assert result =~ "new code"
      assert result =~ "- old code"
      assert result =~ "+ new code"
    end

    test "includes line numbers" do
      search = "line1\nline2\nline3"
      replace = "new1\nnew2"

      result = DiffFormatter.format_search_replace("test.txt", search, replace, color: false)

      assert result =~ "1"
      assert result =~ "2"
      assert result =~ "3"
    end
  end

  describe "format_edit_result/4" do
    test "shows no changes when content is identical" do
      content = "same content"

      result = DiffFormatter.format_edit_result("test.txt", content, content, color: false)

      assert result =~ "No changes"
    end

    test "shows line count changes" do
      original = "line1\nline2"
      new_content = "line1\nline2\nline3\nline4"

      result = DiffFormatter.format_edit_result("test.txt", original, new_content, color: false)

      assert result =~ "Lines:"
      assert result =~ "+2"  # Added 2 lines
    end

    test "shows deletion count" do
      original = "line1\nline2\nline3\nline4"
      new_content = "line1\nline2"

      result = DiffFormatter.format_edit_result("test.txt", original, new_content, color: false)

      assert result =~ "Lines:"
      assert result =~ "-2"  # Removed 2 lines
    end

    test "formats with colors when enabled" do
      original = "hello world"
      new_content = "hello universe"

      result = DiffFormatter.format_edit_result("test.txt", original, new_content, color: true)

      # Should contain ANSI color codes
      assert result =~ "\e["
    end
  end
end
