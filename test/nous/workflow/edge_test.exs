defmodule Nous.Workflow.EdgeTest do
  use ExUnit.Case, async: true

  alias Nous.Workflow.Edge

  describe "new/1" do
    test "creates a sequential edge by default" do
      edge = Edge.new(%{from_id: "a", to_id: "b"})

      assert edge.from_id == "a"
      assert edge.to_id == "b"
      assert edge.type == :sequential
      assert edge.condition == nil
      assert is_binary(edge.id)
    end

    test "creates a conditional edge with condition function" do
      condition = fn _state -> true end

      edge =
        Edge.new(%{
          from_id: "a",
          to_id: "b",
          type: :conditional,
          condition: condition
        })

      assert edge.type == :conditional
      assert edge.condition == condition
    end

    test "creates a default edge" do
      edge = Edge.new(%{from_id: "a", to_id: "b", type: :default})
      assert edge.type == :default
    end

    test "converts atom IDs to strings" do
      edge = Edge.new(%{from_id: :start, to_id: :end})
      assert edge.from_id == "start"
      assert edge.to_id == "end"
    end

    test "generates unique IDs" do
      edge1 = Edge.new(%{from_id: "a", to_id: "b"})
      edge2 = Edge.new(%{from_id: "a", to_id: "b"})
      assert edge1.id != edge2.id
    end

    test "accepts optional label and metadata" do
      edge =
        Edge.new(%{
          from_id: "a",
          to_id: "b",
          label: "on success",
          metadata: %{weight: 1}
        })

      assert edge.label == "on success"
      assert edge.metadata == %{weight: 1}
    end
  end
end
