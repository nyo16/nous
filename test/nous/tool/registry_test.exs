defmodule Nous.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias Nous.Tool
  alias Nous.Tool.Registry

  # Schema-based tools for testing
  defmodule ReadFileTool do
    use Nous.Tool.Schema

    tool "read_file",
      description: "Read a file",
      category: :read,
      tags: [:file] do
      param(:path, :string, required: true, doc: "File path")
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, _args), do: {:ok, "file contents"}
  end

  defmodule WriteFileTool do
    use Nous.Tool.Schema

    tool "write_file",
      description: "Write a file",
      category: :write,
      tags: [:file] do
      param(:path, :string, required: true, doc: "File path")
      param(:content, :string, required: true, doc: "Content to write")
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, _args), do: {:ok, "written"}
  end

  defmodule GitStatusTool do
    use Nous.Tool.Schema

    tool "git_status",
      description: "Show git status",
      category: :read,
      tags: [:git] do
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, _args), do: {:ok, "clean"}
  end

  defmodule SendMessageTool do
    use Nous.Tool.Schema

    tool "send_message",
      description: "Send a message",
      category: :communicate,
      tags: [:team] do
      param(:recipient, :string, required: true, doc: "Recipient name")
      param(:content, :string, required: true, doc: "Message content")
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, _args), do: {:ok, "sent"}
  end

  # A plain behaviour module (no Schema DSL) for backwards compat testing
  defmodule PlainBehaviourTool do
    @behaviour Nous.Tool.Behaviour

    @impl true
    def metadata do
      %{
        name: "plain_tool",
        description: "A plain behaviour tool",
        parameters: %{
          "type" => "object",
          "properties" => %{"input" => %{"type" => "string"}},
          "required" => ["input"]
        }
      }
    end

    @impl true
    def execute(_ctx, _args), do: {:ok, "plain result"}
  end

  @all_modules [ReadFileTool, WriteFileTool, GitStatusTool, SendMessageTool]

  describe "from_modules/2" do
    test "builds a list of Tool structs from modules" do
      tools = Registry.from_modules(@all_modules)

      assert length(tools) == 4
      assert Enum.all?(tools, &match?(%Tool{}, &1))
    end

    test "preserves metadata from each module" do
      tools = Registry.from_modules(@all_modules)
      names = Enum.map(tools, & &1.name)

      assert "read_file" in names
      assert "write_file" in names
      assert "git_status" in names
      assert "send_message" in names
    end

    test "passes opts to each tool" do
      tools = Registry.from_modules(@all_modules, timeout: 60_000, retries: 3)

      assert Enum.all?(tools, &(&1.timeout == 60_000))
      assert Enum.all?(tools, &(&1.retries == 3))
    end

    test "preserves category and tags" do
      tools = Registry.from_modules(@all_modules)
      read_file = Enum.find(tools, &(&1.name == "read_file"))

      assert read_file.category == :read
      assert read_file.tags == [:file]
    end
  end

  describe "filter/2" do
    setup do
      %{tools: Registry.from_modules(@all_modules)}
    end

    test "filters by category", %{tools: tools} do
      read_tools = Registry.filter(tools, category: :read)

      assert length(read_tools) == 2
      assert Enum.all?(read_tools, &(&1.category == :read))

      names = Enum.map(read_tools, & &1.name)
      assert "read_file" in names
      assert "git_status" in names
    end

    test "filters by single tag", %{tools: tools} do
      file_tools = Registry.filter(tools, tags: [:file])

      assert length(file_tools) == 2
      names = Enum.map(file_tools, & &1.name)
      assert "read_file" in names
      assert "write_file" in names
    end

    test "filters by multiple tags (OR semantics)", %{tools: tools} do
      mixed = Registry.filter(tools, tags: [:file, :git])

      assert length(mixed) == 3
      names = Enum.map(mixed, & &1.name)
      assert "read_file" in names
      assert "write_file" in names
      assert "git_status" in names
    end

    test "filters by both category and tags (AND)", %{tools: tools} do
      read_files = Registry.filter(tools, category: :read, tags: [:file])

      assert length(read_files) == 1
      assert hd(read_files).name == "read_file"
    end

    test "returns empty list when no matches", %{tools: tools} do
      assert [] == Registry.filter(tools, category: :search)
      assert [] == Registry.filter(tools, tags: [:nonexistent])
    end

    test "returns all tools with no filters", %{tools: tools} do
      assert length(Registry.filter(tools, [])) == 4
    end
  end

  describe "lookup/2" do
    setup do
      %{tools: Registry.from_modules(@all_modules)}
    end

    test "finds a tool by name", %{tools: tools} do
      assert {:ok, tool} = Registry.lookup(tools, "read_file")
      assert tool.name == "read_file"
      assert tool.category == :read
    end

    test "returns error for missing tool", %{tools: tools} do
      assert {:error, :not_found} = Registry.lookup(tools, "nonexistent")
    end
  end

  describe "backwards compatibility" do
    test "Tool.from_module/2 still works for plain behaviour modules" do
      tool = Tool.from_module(PlainBehaviourTool)

      assert tool.name == "plain_tool"
      assert tool.description == "A plain behaviour tool"
      assert tool.category == nil
      assert tool.tags == []
      assert tool.module == PlainBehaviourTool
    end

    test "from_modules works with plain behaviour modules" do
      tools = Registry.from_modules([PlainBehaviourTool])

      assert length(tools) == 1
      assert hd(tools).name == "plain_tool"
    end

    test "mixed schema and plain modules work together" do
      tools = Registry.from_modules([ReadFileTool, PlainBehaviourTool])

      assert length(tools) == 2
      names = Enum.map(tools, & &1.name)
      assert "read_file" in names
      assert "plain_tool" in names
    end
  end
end
