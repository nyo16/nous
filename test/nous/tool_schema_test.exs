defmodule Nous.ToolSchemaTest do
  use ExUnit.Case, async: true

  alias Nous.{Tool, ToolSchema}

  defp sample_tool do
    %Tool{
      name: "search",
      description: "Search the index",
      function: fn _, _ -> {:ok, "n/a"} end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"},
          "limit" => %{"type" => "integer"}
        },
        "required" => ["query"],
        "additionalProperties" => false
      }
    }
  end

  describe "to_gemini/1" do
    test "produces a flat function declaration with name/description/parameters" do
      schema = ToolSchema.to_gemini(sample_tool())

      assert %{
               "name" => "search",
               "description" => "Search the index",
               "parameters" => %{"type" => "object", "properties" => _, "required" => ["query"]}
             } = schema
    end

    test "strips OpenAI-only `strict` field if present" do
      tool = %Tool{
        name: "x",
        description: "y",
        function: fn _, _ -> {:ok, nil} end,
        parameters: %{"type" => "object", "properties" => %{}}
      }

      schema = ToolSchema.to_gemini(tool)
      refute Map.has_key?(schema, "strict")
      refute Map.has_key?(schema, "type")
      refute Map.has_key?(schema, "function")
    end

    test "removes additionalProperties from parameters (Vertex doesn't accept it)" do
      schema = ToolSchema.to_gemini(sample_tool())
      refute Map.has_key?(schema["parameters"], "additionalProperties")
    end

    test "removes additionalProperties recursively from nested objects" do
      tool = %Tool{
        name: "x",
        description: "y",
        function: fn _, _ -> {:ok, nil} end,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "nested" => %{
              "type" => "object",
              "properties" => %{"a" => %{"type" => "string"}},
              "additionalProperties" => false
            }
          },
          "additionalProperties" => false
        }
      }

      schema = ToolSchema.to_gemini(tool)
      refute Map.has_key?(schema["parameters"], "additionalProperties")
      refute Map.has_key?(schema["parameters"]["properties"]["nested"], "additionalProperties")
    end
  end
end
