defmodule Nous.ToolFromModuleTest do
  use ExUnit.Case, async: true

  alias Nous.Tool

  defmodule ApprovalTool do
    @behaviour Nous.Tool.Behaviour

    @impl true
    def metadata do
      %{
        name: "approval_tool",
        description: "needs approval",
        requires_approval: true,
        parameters: %{"type" => "object", "properties" => %{}}
      }
    end

    @impl true
    def execute(_ctx, _args), do: {:ok, "ran"}
  end

  describe "Tool.from_module/2 preserves metadata.requires_approval" do
    test "carries requires_approval: true from a tool's metadata" do
      # Regression: from_module hardcoded `false` here, silently disabling the
      # agent_runner approval gate for tools like Bash/FileWrite.
      assert %Tool{requires_approval: true} = Tool.from_module(ApprovalTool)
    end

    test "the built-in Bash tool keeps requires_approval: true through from_module" do
      assert %Tool{requires_approval: true} = Tool.from_module(Nous.Tools.Bash)
    end

    test "an explicit opts override still wins" do
      assert %Tool{requires_approval: false} =
               Tool.from_module(ApprovalTool, requires_approval: false)
    end

    test "defaults to false when metadata omits the flag" do
      assert %Tool{requires_approval: false} = Tool.from_module(Nous.Tools.FileRead)
    end
  end

  describe "Agent.new/2 accepts bare tool modules" do
    test "a bare behaviour module is converted via from_module and keeps its flag" do
      agent = Nous.Agent.new("openai:gpt-4o", tools: [Nous.Tools.Bash])
      assert [%Tool{name: "bash", requires_approval: true}] = agent.tools
    end
  end
end
