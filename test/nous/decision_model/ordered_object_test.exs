defmodule Nous.DecisionModel.OrderedObjectTest do
  use ExUnit.Case, async: true

  alias Nous.DecisionModel.OrderedObject

  # Key order a map would scramble: maps iterate in sorted key order.
  @object OrderedObject.new([
            {"zeta", 1},
            {"alpha", OrderedObject.new([{"safe", "ok"}, {"blocked", nil}])},
            {"mid", ["b", "a"]},
            {"empty", OrderedObject.new([])}
          ])

  @expected ~s({"zeta":1,"alpha":{"safe":"ok","blocked":null},"mid":["b","a"],"empty":{}})

  test "Jason (Req's encoder) keeps insertion order, nested objects included" do
    assert Jason.encode!(@object) == @expected
  end

  test "JSON (the Hackney backend's encoder) keeps insertion order, nested objects included" do
    assert JSON.encode!(@object) == @expected
  end
end
