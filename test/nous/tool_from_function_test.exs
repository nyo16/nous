defmodule Nous.ToolFromFunctionTest do
  use ExUnit.Case, async: true

  alias Nous.{RunContext, Tool, ToolExecutor}

  import ExUnit.CaptureLog

  # Declares the approval gate in its metadata, then has execute/2 captured as a
  # plain function — exactly what `tools: [&Mod.execute/2]` does.
  defmodule GatedTool do
    use Nous.Tool.Schema

    tool "gated_tool", description: "needs approval", requires_approval: true do
      param(:probe, :string, doc: "ignored")
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, _args), do: {:ok, "ran"}
  end

  defmodule UngatedTool do
    use Nous.Tool.Schema

    tool "ungated_tool", description: "no approval needed" do
      param(:probe, :string, doc: "ignored")
    end

    @impl Nous.Tool.Behaviour
    def execute(_ctx, _args), do: {:ok, "ran"}
  end

  describe "Tool.from_function/2 inherits the owning module's requires_approval" do
    test "a captured approval-gated function stays gated" do
      # Regression: from_function/2 hardcoded `false`, so the capture form the
      # guides use produced an ungated tool while from_module/2 — the sibling
      # fixed one cycle earlier — gated the very same tool correctly.
      assert %Tool{requires_approval: true} = Tool.from_function(&GatedTool.execute/2)
    end

    test "the built-in Bash tool stays gated when captured" do
      assert %Tool{requires_approval: true} = Tool.from_function(&Nous.Tools.Bash.execute/2)
    end

    test "a captured tool passed via :tools keeps the flag through Agent.new/2" do
      agent = Nous.Agent.new("openai:gpt-4o", tools: [&Nous.Tools.Bash.execute/2])

      assert [%Tool{requires_approval: true}] = agent.tools
    end

    test "a module declaring no approval requirement is not gated" do
      assert %Tool{requires_approval: false} = Tool.from_function(&UngatedTool.execute/2)
    end

    test "an anonymous function is not gated" do
      assert %Tool{requires_approval: false} =
               Tool.from_function(fn _ctx, _args -> {:ok, "ran"} end)
    end

    test "an explicit opts override still wins" do
      assert %Tool{requires_approval: false} =
               Tool.from_function(&GatedTool.execute/2, requires_approval: false)
    end
  end

  describe "the inherited flag reaches the gate" do
    test "a captured gated function is rejected with no approval handler" do
      tool = Tool.from_function(&GatedTool.execute/2)

      log =
        capture_log(fn ->
          assert {:error, _} = ToolExecutor.execute(tool, %{}, RunContext.new(%{}))
        end)

      assert log =~ "requires_approval: true but the RunContext has no"
    end

    test "a captured gated function runs once a handler approves" do
      tool = Tool.from_function(&GatedTool.execute/2)
      ctx = RunContext.new(%{}, approval_handler: fn _call -> :approve end)

      assert {:ok, "ran"} = ToolExecutor.execute(tool, %{}, ctx)
    end
  end

  describe "Tool.from_function/2 extracts the captured function's @doc" do
    # Regression: extract_function_docs/1 matched Function.info/1 against an
    # exact THREE-element keyword list while the BIF returns five keys
    # (module, name, arity, env, type). The clause never matched, so the whole
    # extraction path was dead and every tool built this way silently got an
    # empty description — contradicting the moduledoc's promise of automatic
    # doc extraction. Nous.DocumentedTestTools lives in test/support because
    # only a disk-compiled beam carries the docs chunk this reads.
    alias Nous.DocumentedTestTools

    test "a documented function's @doc becomes the description" do
      tool = Tool.from_function(&DocumentedTestTools.documented/2)

      assert tool.description =~ "Look up a customer record by email address."
    end

    test "an undocumented function falls back to the empty default" do
      assert Tool.from_function(&DocumentedTestTools.undocumented/2).description == ""
    end

    test "an explicit :description still wins over the @doc" do
      tool = Tool.from_function(&DocumentedTestTools.documented/2, description: "override")

      assert tool.description == "override"
    end

    test "an anonymous function is never looked up" do
      assert Tool.from_function(fn _ctx, _args -> {:ok, "ran"} end).description == ""
    end

    test "the parameter schema stays the permissive default" do
      # parse_param_schema/1 still has no real inference; the fix restores the
      # description, not a schema. Pinning this stops a future change from
      # silently advertising a misleading contract to the model (L-8).
      tool = Tool.from_function(&DocumentedTestTools.documented/2)

      assert tool.parameters == %{"type" => "object", "properties" => %{}, "required" => []}
    end
  end
end
