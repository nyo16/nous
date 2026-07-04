defmodule Nous.ToolCallTest do
  use ExUnit.Case, async: true

  alias Nous.ToolCall

  describe "field/3" do
    test "reads atom keys" do
      assert ToolCall.field(%{name: "search"}, :name) == "search"
    end

    test "reads string keys" do
      assert ToolCall.field(%{"name" => "search"}, :name) == "search"
    end

    test "atom key wins when both present" do
      assert ToolCall.field(%{"name" => "string", name: "atom"}, :name) == "atom"
    end

    test "preserves falsy values instead of coalescing them away" do
      # The `call[:x] || call["x"]` idiom this replaces silently dropped these.
      assert ToolCall.field(%{arguments: false}, :arguments) == false
      assert ToolCall.field(%{arguments: 0}, :arguments) == 0
      assert ToolCall.field(%{arguments: ""}, :arguments) == ""
      assert ToolCall.field(%{"arguments" => false}, :arguments) == false
    end

    test "returns default when key is missing" do
      assert ToolCall.field(%{}, :name) == nil
      assert ToolCall.field(%{}, :name, "unknown") == "unknown"
      assert ToolCall.field(%{}, :arguments, %{}) == %{}
    end

    test "nil values fall through to the default" do
      assert ToolCall.field(%{name: nil}, :name, "unknown") == "unknown"
      assert ToolCall.field(%{"name" => nil}, :name, "unknown") == "unknown"
    end

    test "nil atom value falls through to string key" do
      assert ToolCall.field(%{"name" => "search", name: nil}, :name) == "search"
    end
  end

  describe "put_field/3" do
    test "updates an existing atom key" do
      assert ToolCall.put_field(%{name: "a"}, :name, "b") == %{name: "b"}
    end

    test "updates an existing string key without adding an atom key" do
      assert ToolCall.put_field(%{"name" => "a"}, :name, "b") == %{"name" => "b"}
    end

    test "prefers the atom key when both present" do
      assert ToolCall.put_field(%{"name" => "a", name: "a"}, :name, "b") ==
               %{"name" => "a", name: "b"}
    end

    test "adds a string key when neither present" do
      assert ToolCall.put_field(%{}, :name, "b") == %{"name" => "b"}
    end
  end
end
