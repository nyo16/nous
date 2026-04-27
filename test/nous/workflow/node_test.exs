defmodule Nous.Workflow.NodeTest do
  use ExUnit.Case, async: true

  alias Nous.Workflow.Node

  describe "new/1" do
    test "creates a node with required fields" do
      node = Node.new(%{id: "step1", type: :transform, label: "Clean data"})

      assert node.id == "step1"
      assert node.type == :transform
      assert node.label == "Clean data"
      assert node.config == %{}
      assert node.error_strategy == :fail_fast
      assert node.timeout == nil
      assert node.metadata == %{}
    end

    test "converts atom id to string" do
      node = Node.new(%{id: :fetch, type: :agent_step, label: "Fetch"})
      assert node.id == "fetch"
    end

    test "accepts all optional fields" do
      node =
        Node.new(%{
          id: "s1",
          type: :agent_step,
          label: "Agent",
          config: %{agent: :mock},
          error_strategy: {:retry, 3, 1000},
          timeout: 5000,
          metadata: %{priority: :high}
        })

      assert node.config == %{agent: :mock}
      assert node.error_strategy == {:retry, 3, 1000}
      assert node.timeout == 5000
      assert node.metadata == %{priority: :high}
    end

    test "raises on missing required fields" do
      # apply/3 hides the literal struct from dialyzer's incompatible-types check.
      assert_raise KeyError, fn -> apply(Node, :new, [%{type: :transform, label: "x"}]) end
      assert_raise KeyError, fn -> apply(Node, :new, [%{id: "x", label: "x"}]) end
      assert_raise KeyError, fn -> apply(Node, :new, [%{id: "x", type: :transform}]) end
    end

    test "raises on invalid node type" do
      assert_raise ArgumentError, ~r/invalid node type/, fn ->
        Node.new(%{id: "x", type: :invalid, label: "x"})
      end
    end
  end

  describe "valid_types/0" do
    test "returns all valid node types" do
      types = Node.valid_types()
      assert :agent_step in types
      assert :tool_step in types
      assert :branch in types
      assert :parallel in types
      assert :parallel_map in types
      assert :transform in types
      assert :human_checkpoint in types
      assert :subworkflow in types
    end
  end
end
