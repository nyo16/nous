defmodule Nous.Tool.SchemaTest do
  use ExUnit.Case, async: true

  alias Nous.Tool

  # Test tool with all features
  defmodule FileReadTool do
    use Nous.Tool.Schema

    tool "file_read",
      description: "Read a file from the filesystem",
      category: :read,
      tags: [:file] do
      param(:path, :string, required: true, doc: "Absolute file path")
      param(:offset, :integer, doc: "Line offset to start reading from")
      param(:limit, :integer, doc: "Number of lines to read")
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, %{"path" => path}) do
      {:ok, "contents of #{path}"}
    end
  end

  # Minimal tool with no category or tags
  defmodule MinimalTool do
    use Nous.Tool.Schema

    tool "minimal",
      description: "A minimal tool" do
      param(:input, :string, required: true)
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, %{"input" => input}) do
      {:ok, input}
    end
  end

  # Tool with all param types
  defmodule AllTypesTool do
    use Nous.Tool.Schema

    tool "all_types",
      description: "Tool with all supported param types",
      category: :execute,
      tags: [:test, :demo] do
      param(:name, :string, required: true, doc: "A string")
      param(:count, :integer, doc: "An integer")
      param(:score, :number, doc: "A number")
      param(:active, :boolean, doc: "A boolean")
      param(:items, :array, doc: "An array")
      param(:config, :object, doc: "An object")
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, _args), do: {:ok, "done"}
  end

  describe "metadata/0" do
    test "generates correct metadata from tool declaration" do
      meta = FileReadTool.metadata()

      assert meta.name == "file_read"
      assert meta.description == "Read a file from the filesystem"
      assert meta.category == :read
      assert meta.tags == [:file]
    end

    test "generates correct parameter JSON Schema" do
      meta = FileReadTool.metadata()

      assert meta.parameters == %{
               "type" => "object",
               "properties" => %{
                 "path" => %{"type" => "string", "description" => "Absolute file path"},
                 "offset" => %{
                   "type" => "integer",
                   "description" => "Line offset to start reading from"
                 },
                 "limit" => %{"type" => "integer", "description" => "Number of lines to read"}
               },
               "required" => ["path"]
             }
    end

    test "minimal tool has nil category and empty tags" do
      meta = MinimalTool.metadata()

      assert meta.name == "minimal"
      assert meta.description == "A minimal tool"
      assert meta.category == nil
      assert meta.tags == []
    end

    test "required params appear in required list" do
      meta = MinimalTool.metadata()
      assert meta.parameters["required"] == ["input"]
    end

    test "optional params do not appear in required list" do
      meta = FileReadTool.metadata()
      required = meta.parameters["required"]

      assert "path" in required
      refute "offset" in required
      refute "limit" in required
    end
  end

  describe "all param types" do
    test "maps all Elixir types to JSON Schema types" do
      meta = AllTypesTool.metadata()
      props = meta.parameters["properties"]

      assert props["name"]["type"] == "string"
      assert props["count"]["type"] == "integer"
      assert props["score"]["type"] == "number"
      assert props["active"]["type"] == "boolean"
      assert props["items"]["type"] == "array"
      assert props["config"]["type"] == "object"
    end

    test "only required params in required list" do
      meta = AllTypesTool.metadata()
      assert meta.parameters["required"] == ["name"]
    end

    test "descriptions are included when provided" do
      meta = AllTypesTool.metadata()
      props = meta.parameters["properties"]

      assert props["name"]["description"] == "A string"
      assert props["count"]["description"] == "An integer"
      assert props["score"]["description"] == "A number"
      assert props["active"]["description"] == "A boolean"
      assert props["items"]["description"] == "An array"
      assert props["config"]["description"] == "An object"
    end
  end

  describe "__tool_schema__/0" do
    test "returns introspection data with params list" do
      schema = FileReadTool.__tool_schema__()

      assert schema.name == "file_read"
      assert schema.description == "Read a file from the filesystem"
      assert schema.category == :read
      assert schema.tags == [:file]

      assert [path_param, offset_param, limit_param] = schema.params

      assert path_param == %{
               name: :path,
               type: :string,
               required: true,
               doc: "Absolute file path"
             }

      assert offset_param == %{
               name: :offset,
               type: :integer,
               required: false,
               doc: "Line offset to start reading from"
             }

      assert limit_param == %{
               name: :limit,
               type: :integer,
               required: false,
               doc: "Number of lines to read"
             }
    end

    test "matches schema/0 callback output" do
      assert FileReadTool.__tool_schema__() == FileReadTool.schema()
    end

    test "minimal tool schema has no category" do
      schema = MinimalTool.__tool_schema__()

      assert schema.category == nil
      assert schema.tags == []
      assert length(schema.params) == 1
    end
  end

  describe "category and tags storage" do
    test "category is stored on metadata" do
      assert FileReadTool.metadata().category == :read
      assert AllTypesTool.metadata().category == :execute
      assert MinimalTool.metadata().category == nil
    end

    test "tags are stored on metadata" do
      assert FileReadTool.metadata().tags == [:file]
      assert AllTypesTool.metadata().tags == [:test, :demo]
      assert MinimalTool.metadata().tags == []
    end
  end

  describe "integration with Tool.from_module/2" do
    test "creates a tool struct from a schema module" do
      tool = Tool.from_module(FileReadTool)

      assert tool.name == "file_read"
      assert tool.description == "Read a file from the filesystem"
      assert tool.category == :read
      assert tool.tags == [:file]
      assert tool.module == FileReadTool
      assert is_function(tool.function, 2)
    end

    test "opts override metadata category and tags" do
      tool = Tool.from_module(FileReadTool, category: :write, tags: [:override])

      assert tool.category == :write
      assert tool.tags == [:override]
    end

    test "execute works through the tool function" do
      tool = Tool.from_module(FileReadTool)

      assert {:ok, "contents of /tmp/test.txt"} =
               tool.function.(nil, %{"path" => "/tmp/test.txt"})
    end
  end

  describe "build_json_schema/1" do
    test "builds schema from empty params list" do
      schema = Nous.Tool.Schema.build_json_schema([])

      assert schema == %{
               "type" => "object",
               "properties" => %{},
               "required" => []
             }
    end

    test "omits description key when doc is nil" do
      schema =
        Nous.Tool.Schema.build_json_schema([
          %{name: :query, type: :string, required: true, doc: nil}
        ])

      refute Map.has_key?(schema["properties"]["query"], "description")
    end
  end
end
