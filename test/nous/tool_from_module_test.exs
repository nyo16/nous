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

  defmodule DeclaredTimeoutTool do
    use Nous.Tool.Schema

    tool "declared_timeout",
      description: "declares its own deadline",
      timeout: 50 do
      param(:input, :string)
    end

    @impl Nous.Tool.Behaviour
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

  describe "Tool.from_module/2 preserves metadata.timeout" do
    test "carries a declared timeout from a tool's metadata" do
      # Same defect as requires_approval above: a hardcoded default here meant a
      # tool could not declare its own deadline at all.
      assert %Tool{timeout: 50} = Tool.from_module(DeclaredTimeoutTool)
    end

    test "falls back to the struct default when the tool declares nothing" do
      assert %Tool{timeout: 30_000} = Tool.from_module(Nous.Tools.FileRead)
    end

    test "falls back to the struct default when metadata omits the key entirely" do
      # ApprovalTool hand-writes its metadata map, so :timeout is absent rather
      # than nil — the other half of the fallback.
      assert %Tool{timeout: 30_000} = Tool.from_module(ApprovalTool)
    end

    test "an explicit opts override beats the declared timeout" do
      assert %Tool{timeout: 1234} = Tool.from_module(DeclaredTimeoutTool, timeout: 1234)
    end

    test "Bash's deadline sits above the command budget it grants NetRunner" do
      # Ordering, not magic numbers: the inner timeout must fire first so the
      # model gets "Command timed out after Nms" instead of the executor's
      # opaque kill. Asserted for the default budget and for the largest one a
      # model can ask for, since the argument may only lower it.
      deadline = Tool.from_module(Nous.Tools.Bash).timeout

      assert deadline > Nous.Tools.Bash.command_timeout(%{})
      assert deadline > Nous.Tools.Bash.command_timeout(%{"timeout" => 10_000_000})
    end
  end

  describe "Agent.new/2 accepts bare tool modules" do
    test "a bare behaviour module is converted via from_module and keeps its flag" do
      agent = Nous.Agent.new("openai:gpt-4o", tools: [Nous.Tools.Bash])
      assert [%Tool{name: "bash", requires_approval: true}] = agent.tools
    end
  end
end
