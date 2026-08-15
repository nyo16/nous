defmodule Nous.CodeMode.SdkTest do
  use ExUnit.Case, async: true

  alias Nous.CodeMode.Sdk
  alias Nous.Tool

  doctest Nous.CodeMode.Sdk

  defp tool(name, opts \\ []) do
    %Tool{
      name: name,
      description: Keyword.get(opts, :description, "Does #{name}."),
      function: fn _ctx, _args -> {:ok, name} end,
      parameters:
        Keyword.get(opts, :parameters, %{
          "type" => "object",
          "properties" => %{"q" => %{"type" => "string"}},
          "required" => ["q"]
        })
    }
  end

  # A cheap structural stand-in for "a parser would accept this": every opening
  # delimiter is closed, and nothing leaked an Elixir term into the output.
  defp assert_wellformed(sdk) do
    for {open, close} <- [{"{", "}"}, {"[", "]"}, {"(", ")"}] do
      assert count(sdk, open) == count(sdk, close),
             "unbalanced #{open}#{close} in generated SDK:\n#{sdk}"
    end

    refute sdk =~ "%{"
    refute sdk =~ "#Function"
    refute sdk =~ ":error"
    sdk
  end

  defp count(string, char), do: string |> String.graphemes() |> Enum.count(&(&1 == char))

  describe "byte stability (KV-cache)" do
    test "the same tool set renders to identical bytes every time" do
      tools = [tool("b"), tool("a"), tool("c")]

      first = Sdk.render(:javascript, tools)

      for _ <- 1..25 do
        assert Sdk.render(:javascript, tools) == first
      end
    end

    test "input order does not change a single byte" do
      tools = Enum.map(~w(delta alpha charlie bravo), &tool/1)
      expected = Sdk.render(:javascript, tools)

      for permutation <- permutations(tools) do
        assert Sdk.render(:javascript, permutation) == expected
      end
    end

    test "a property map big enough to be a hashmap still renders stably" do
      # >32 keys: Erlang switches map representation and iteration stops
      # following insertion order. Two maps built in different orders must still
      # render identically.
      keys = for i <- 1..40, do: "field_#{i}"

      build = fn order ->
        properties = Map.new(order, fn key -> {key, %{"type" => "string"}} end)
        tool("wide", parameters: %{"type" => "object", "properties" => properties})
      end

      assert Sdk.render(:javascript, [build.(keys)]) ==
               Sdk.render(:javascript, [build.(Enum.reverse(keys))])
    end

    test "changing the tool set changes the output" do
      base = [tool("a"), tool("b")]

      refute Sdk.render(:javascript, base) == Sdk.render(:javascript, [tool("a")])
      refute Sdk.render(:javascript, base) == Sdk.render(:javascript, base ++ [tool("c")])

      refute Sdk.render(:javascript, base) ==
               Sdk.render(:javascript, [tool("a"), tool("b", description: "changed")])
    end

    test "a duplicate name renders once, keeping the first occurrence" do
      sdk = Sdk.render(:javascript, [tool("dup", description: "first"), tool("dup")])

      assert sdk =~ "first"
      refute sdk =~ "Does dup."
      assert count(sdk, "(") == count(sdk, ")")
    end
  end

  describe "ordering" do
    test "tools are lexicographic regardless of input order" do
      names = ~w(zeta Alpha _underscore mid 9nine)
      sdk = Sdk.render(:javascript, Enum.map(names, &tool/1))

      positions = Enum.map(names, fn name -> {name, index_of(sdk, ~s|"#{name}"(|)} end)
      rendered_order = positions |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

      assert rendered_order == Enum.sort(names)
    end
  end

  describe "addressing by exact name" do
    test "names that are not identifiers are addressable" do
      names = ["my-tool", "a.b", "with space", "日本語", "emoji-🙂", ~s(quote"inside)]
      sdk = Sdk.render(:javascript, Enum.map(names, &tool/1))

      assert sdk =~ ~s|"my-tool"(args:|
      assert sdk =~ ~s|"a.b"(args:|
      assert sdk =~ ~s|"with space"(args:|
      assert sdk =~ ~s|"日本語"(args:|
      assert sdk =~ ~s|"emoji-🙂"(args:|
      # The quote is escaped rather than closing the literal early.
      assert sdk =~ ~S|"quote\"inside"(args:|
      assert_wellformed(sdk)
    end

    test "python indexes by the same exact names" do
      sdk = Sdk.render(:python, [tool("my-tool"), tool("a.b")])

      assert sdk =~ ~s|"my-tool": Callable[|
      assert sdk =~ ~s|"a.b": Callable[|
      assert sdk =~ "tools: Tools"
    end
  end

  describe "descriptions" do
    test "the tool description is carried into the SDK" do
      sdk = Sdk.render(:javascript, [tool("t", description: "Reads a file, carefully.")])

      assert sdk =~ "Reads a file, carefully."
    end

    test "a description containing */ cannot close the comment early" do
      sdk = Sdk.render(:javascript, [tool("t", description: "glob **/*.ex then stop")])

      refute sdk =~ "*/ then stop"
      assert sdk =~ "*\\/*.ex"
      assert_wellformed(sdk)
    end

    test "parameter descriptions survive, since the SDK is the only declaration" do
      parameters = %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string", "description" => "Absolute path"}},
        "required" => ["path"]
      }

      assert Sdk.render(:javascript, [tool("t", parameters: parameters)]) =~
               "/** Absolute path */"

      assert Sdk.render(:python, [tool("t", parameters: parameters)]) =~ "#   path: Absolute path"
    end
  end

  describe "json_schema_to_type/2 — supported nodes" do
    test "scalars" do
      assert Sdk.json_schema_to_type(:typescript, %{"type" => "string"}) == "string"
      assert Sdk.json_schema_to_type(:typescript, %{"type" => "number"}) == "number"
      assert Sdk.json_schema_to_type(:typescript, %{"type" => "integer"}) == "number"
      assert Sdk.json_schema_to_type(:typescript, %{"type" => "boolean"}) == "boolean"
      assert Sdk.json_schema_to_type(:typescript, %{"type" => "null"}) == "null"

      assert Sdk.json_schema_to_type(:python, %{"type" => "string"}) == "str"
      assert Sdk.json_schema_to_type(:python, %{"type" => "integer"}) == "int"
      assert Sdk.json_schema_to_type(:python, %{"type" => "number"}) == "float"
      assert Sdk.json_schema_to_type(:python, %{"type" => "boolean"}) == "bool"
      assert Sdk.json_schema_to_type(:python, %{"type" => "null"}) == "None"
    end

    test "objects carry properties and required" do
      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "integer"}},
        "required" => ["a"]
      }

      assert Sdk.json_schema_to_type(:typescript, schema) == ~s({ "a": string; "b"?: number })
    end

    test "an object with no properties keeps its value type" do
      assert Sdk.json_schema_to_type(:typescript, %{"type" => "object"}) ==
               "Record<string, unknown>"

      assert Sdk.json_schema_to_type(:typescript, %{
               "type" => "object",
               "additionalProperties" => %{"type" => "string"}
             }) == "Record<string, string>"

      assert Sdk.json_schema_to_type(:python, %{"type" => "object"}) == "dict[str, Any]"
    end

    test "arrays and draft-4 tuples" do
      assert Sdk.json_schema_to_type(:typescript, %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }) == "Array<string>"

      assert Sdk.json_schema_to_type(:typescript, %{"type" => "array"}) == "Array<unknown>"

      assert Sdk.json_schema_to_type(:typescript, %{
               "type" => "array",
               "items" => [%{"type" => "string"}, %{"type" => "integer"}]
             }) == "[string, number]"

      assert Sdk.json_schema_to_type(:python, %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }) == "list[str]"
    end

    test "enums become literal unions" do
      schema = %{"enum" => ["a", "b", 1, true, nil]}

      assert Sdk.json_schema_to_type(:typescript, schema) == ~s("a" | "b" | 1 | true | null)
      assert Sdk.json_schema_to_type(:python, schema) == ~s(Literal["a", "b", 1, True, None])
    end

    test "oneOf/anyOf become unions, allOf an intersection" do
      parts = [%{"type" => "string"}, %{"type" => "integer"}]

      assert Sdk.json_schema_to_type(:typescript, %{"oneOf" => parts}) == "string | number"
      assert Sdk.json_schema_to_type(:typescript, %{"anyOf" => parts}) == "string | number"
      assert Sdk.json_schema_to_type(:typescript, %{"allOf" => parts}) == "string & number"

      assert Sdk.json_schema_to_type(:python, %{"anyOf" => parts}) == "str | int"
      # Python has no intersection type — it degrades rather than lying.
      assert Sdk.json_schema_to_type(:python, %{"allOf" => parts}) == "Any"
    end

    test "a type list is a union" do
      assert Sdk.json_schema_to_type(:typescript, %{"type" => ["string", "null"]}) ==
               "string | null"
    end

    test "atom-keyed schemas are read too" do
      assert Sdk.json_schema_to_type(:typescript, %{type: "array", items: %{type: "string"}}) ==
               "Array<string>"
    end
  end

  describe "json_schema_to_type/2 — the escape hatch" do
    test "every unsupported node yields the hatch instead of raising" do
      unsupported = [
        %{"$ref" => "#/definitions/thing"},
        %{"type" => "somethingelse"},
        %{"type" => 42},
        %{},
        %{"description" => "no type at all"},
        %{"enum" => "not a list", "type" => "mystery"},
        %{"enum" => "not a list"},
        %{"enum" => [%{"unrepresentable" => true}]},
        %{"oneOf" => []},
        "a bare string",
        nil,
        42,
        [1, 2, 3],
        {:tuple, :not, :json}
      ]

      for node <- unsupported do
        assert Sdk.json_schema_to_type(:typescript, node) == "unknown",
               "expected the escape hatch for #{inspect(node)}"

        assert Sdk.json_schema_to_type(:python, node) == "Any",
               "expected the escape hatch for #{inspect(node)}"
      end
    end

    test "a malformed sub-field costs that field, not the whole node" do
      # The node's kind is still known; only its detail is unreadable. Widening
      # to `Record`/`list` says exactly that, and says more than `unknown` does.
      assert Sdk.json_schema_to_type(:typescript, %{
               "type" => "object",
               "properties" => "not a map",
               "required" => "not a list"
             }) == "Record<string, unknown>"

      assert Sdk.json_schema_to_type(:typescript, %{
               "type" => "array",
               "items" => "not a schema"
             }) == "Array<unknown>"

      assert Sdk.json_schema_to_type(:python, %{"type" => "array", "items" => 42}) ==
               "list[Any]"
    end

    test "nesting deeper than the cap degrades rather than blowing the stack" do
      deep =
        Enum.reduce(1..80, %{"type" => "string"}, fn _i, acc ->
          %{"type" => "array", "items" => acc}
        end)

      rendered = Sdk.json_schema_to_type(:typescript, deep)

      assert rendered =~ "unknown"
      assert String.starts_with?(rendered, "Array<")
    end

    test "an exotic schema still yields a parseable SDK" do
      exotic = %{
        "type" => "object",
        "properties" => %{
          "ref" => %{"$ref" => "#/definitions/loop"},
          "mystery" => %{"type" => "quantum"},
          "malformed" => "this is not a schema node at all",
          "empty" => %{},
          "deep" =>
            Enum.reduce(1..40, %{"type" => "string"}, fn _i, acc ->
              %{"type" => "array", "items" => acc}
            end),
          "combo" => %{"allOf" => [%{"type" => "object"}, %{"$ref" => "#/x"}]}
        },
        "required" => ["ref", "mystery"]
      }

      sdk =
        Sdk.render(:javascript, [
          tool("exotic", parameters: exotic),
          tool("normal")
        ])

      assert sdk =~ "unknown"
      # The healthy tool alongside it is untouched.
      assert sdk =~ ~s|"normal"(args: {|
      assert_wellformed(sdk)

      assert_wellformed(Sdk.render(:python, [tool("exotic", parameters: exotic)]))
    end

    test "a tool with no parameters at all is still declared" do
      no_params = %Tool{
        name: "bare",
        description: nil,
        function: fn _ctx, _args -> {:ok, :done} end,
        parameters: nil
      }

      sdk = Sdk.render(:javascript, [no_params])

      assert sdk =~ ~s|"bare"(args: unknown): Promise<unknown>;|
      assert_wellformed(sdk)
    end

    test "an empty tool set renders a valid, empty SDK" do
      assert_wellformed(Sdk.render(:javascript, []))
      assert Sdk.render(:javascript, []) =~ "declare const tools: {};"

      assert_wellformed(Sdk.render(:python, []))
      assert Sdk.render(:python, []) =~ ~s|Tools = TypedDict("Tools", {})|
    end
  end

  describe "languages" do
    test "javascript and typescript render the same declarations" do
      tools = [tool("a")]
      assert Sdk.render(:javascript, tools) == Sdk.render(:typescript, tools)
      assert Sdk.render("javascript", tools) == Sdk.render(:javascript, tools)
    end

    test "coerce_language/1 accepts strings and refuses the rest without raising" do
      assert Sdk.coerce_language("python") == {:ok, :python}
      assert Sdk.coerce_language(:typescript) == {:ok, :typescript}
      assert Sdk.coerce_language("ruby") == :error
      assert Sdk.coerce_language(nil) == :error
    end

    test "an unknown language is a configuration error, and never creates an atom" do
      assert_raise ArgumentError, ~r/unsupported SDK language/, fn ->
        Sdk.render("brainfuck_sdk_language", [])
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom("brainfuck_sdk_language") end
    end

    test "the global and error class the bindings must match are exposed" do
      assert Sdk.global() == "tools"
      assert Sdk.error_class() == "ToolError"
      assert Sdk.render(:javascript, []) =~ "declare const #{Sdk.global()}"
      assert Sdk.render(:javascript, []) =~ Sdk.error_class()
    end
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {position, _length} -> position
      :nomatch -> flunk("#{inspect(needle)} missing from generated SDK")
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for element <- list, rest <- permutations(list -- [element]), do: [element | rest]
  end
end
