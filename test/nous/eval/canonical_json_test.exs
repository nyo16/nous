defmodule Nous.Eval.CanonicalJSONTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.CanonicalJSON

  doctest CanonicalJSON

  test "sorts keys at every depth, including maps above 32 keys" do
    big = Map.new(1..40, &{"k#{&1}", &1})

    encoded =
      CanonicalJSON.encode(%{"z" => %{"b" => 1, "a" => [%{"d" => 1, "c" => 2}]}, "big" => big})

    assert encoded =~ ~s({"big":{"k1":1,"k10":10,"k11":11,)
    assert encoded =~ ~s("z":{"a":[{"c":2,"d":1}],"b":1}})

    keys = Regex.scan(~r/"(k\d+)":/, CanonicalJSON.encode(big), capture: :all_but_first)
    assert List.flatten(keys) == big |> Map.keys() |> Enum.sort()

    assert JSON.decode!(encoded) == %{
             "z" => %{"b" => 1, "a" => [%{"d" => 1, "c" => 2}]},
             "big" => big
           }
  end

  test "is independent of map construction order" do
    a = Enum.reduce(1..50, %{}, &Map.put(&2, "key#{&1}", &1))
    b = Enum.reduce(50..1//-1, %{}, &Map.put(&2, "key#{&1}", &1))
    assert CanonicalJSON.encode(a) == CanonicalJSON.encode(b)
  end

  test "escapes only quotes, backslashes and control characters" do
    assert CanonicalJSON.encode("a\"b\\c\n\t\r\b\f\u0001é/€") ==
             ~S("a\"b\\c\n\t\r\b\f\u0001é/€")

    assert JSON.decode!(CanonicalJSON.encode("x\u001fy")) == "x\u001fy"
  end

  test "numbers: integral floats as integers, others in shortest round-trip form" do
    assert CanonicalJSON.encode([1, 1.0, -0.0, 2.5, 0.1, 1.0e300, -3]) ==
             "[1,1,0,2.5,0.1,1.0e300,-3]"

    assert CanonicalJSON.hash(%{"w" => 2}) == CanonicalJSON.hash(%{"w" => 2.0})
  end

  test "atoms encode as strings; nil and booleans as JSON literals" do
    assert CanonicalJSON.encode(%{mode: :superset, mod: Nous.Agent, n: nil, t: true, f: false}) ==
             ~s({"f":false,"mod":"Elixir.Nous.Agent","mode":"superset","n":null,"t":true})
  end

  test "rejects terms without a JSON form" do
    assert_raise ArgumentError, ~r/structs/, fn -> CanonicalJSON.encode(%URI{}) end
    assert_raise ArgumentError, ~r/no encoding/, fn -> CanonicalJSON.encode({1, 2}) end
    assert_raise ArgumentError, ~r/no encoding/, fn -> CanonicalJSON.encode(&Map.new/0) end
    assert_raise ArgumentError, ~r/UTF-8/, fn -> CanonicalJSON.encode(<<255>>) end
    assert_raise ArgumentError, ~r/twice/, fn -> CanonicalJSON.encode(%{"a" => 1, a: 2}) end

    assert_raise ArgumentError, ~r/keys must be strings or atoms/, fn ->
      CanonicalJSON.encode(%{1 => 2})
    end
  end

  test "hash is sha256 of the encoding" do
    term = %{"b" => [1, "two"], "a" => nil}
    expected = :crypto.hash(:sha256, ~s({"a":null,"b":[1,"two"]})) |> Base.encode16(case: :lower)
    assert CanonicalJSON.hash(term) == "sha256:" <> expected
  end
end
