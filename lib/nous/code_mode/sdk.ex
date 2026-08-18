defmodule Nous.CodeMode.Sdk do
  @moduledoc """
  Renders the typed SDK a Code Mode program is written against.

  Under `mode: :code` this text is the model's **only** declaration of the
  tools — there is no native tool schema alongside it — which is what drives
  every rule below.

  ## Byte stability

  Tools are sorted lexicographically by name and every map is walked in a
  sorted order, so the same tool set renders to the same bytes on every call.
  The SDK travels in the `run_code` tool's description, i.e. in the prompt
  prefix of every request; an unstable ordering would invalidate the provider's
  KV cache each turn and silently double the cost of a run. Assert
  `render(lang, tools) == render(lang, Enum.shuffle(tools))` when you change
  anything here.

  ## Total, never raising, on schemas

  `json_schema_to_type/2` is total over arbitrary input. Any node it cannot
  express — a `$ref` it cannot resolve, an unknown `type`, a malformed map, a
  nesting deeper than a dozen levels — becomes the language's escape hatch
  (`unknown` for JS/TS, `Any` for Python). An exotic schema costs that node its
  type; it must never cost the SDK its parseability, because a program written
  against an unparseable SDK cannot call any tool at all.

  ## Addressing

  `tools` is an object/mapping indexed by each tool's **exact** name, so
  `tools["my-tool"](args)` works with no alias table and no name mangling.
  Names are emitted as JSON string literals, which are valid string literals in
  both target languages.

  ## Languages

  `:javascript` and `:typescript` render the same TypeScript declaration —
  under JavaScript it is read as documentation, not executed. `:python` renders
  a stub module. Structural fidelity differs by language and that is deliberate:
  Python has no intersection type and no anonymous nested record type, so
  `allOf` and nested objects degrade there while JS/TS keeps them.
  """

  alias Nous.Tool

  @typedoc """
  A language this generator can render. Providers report their language as a
  string via `c:Nous.CodeRuntime.language/1`; both forms are accepted.
  """
  @type language :: :javascript | :typescript | :python

  @languages [:javascript, :typescript, :python]

  # Deeper than any tool schema Nous emits. A cap makes the walk total against
  # a pathological hand-written schema instead of trusting the stack.
  @max_depth 12

  @global "tools"
  @error_class "ToolError"

  @ts_unknown "unknown"
  @py_any "Any"

  # Python's TypedDict describing the `tools` mapping.
  @py_type_name "Tools"

  @ts_header """
  // Tool SDK (generated). These declarations are the only description of the
  // tools your program may call.
  //
  //     const out = await #{@global}["<tool name>"]({ /* arguments */ });
  //
  // `#{@global}` is indexed by each tool's EXACT name, so a name that is not a
  // valid identifier needs no alias. Every tool takes a single arguments
  // object. Calls go through the same permission policy as a direct tool call:
  // one that is denied or fails raises `#{@error_class}` carrying only the tool
  // name and a message.
  """

  @py_header """
  # Tool SDK (generated). These declarations are the only description of the
  # tools your program may call.
  #
  #     out = #{@global}["<tool name>"]({"argument": ...})
  #
  # `#{@global}` is indexed by each tool's EXACT name, so a name that is not a
  # valid identifier needs no alias. Every tool takes a single arguments
  # mapping. Calls go through the same permission policy as a direct tool call:
  # one that is denied or fails raises `#{@error_class}` carrying only the tool
  # name and a message.

  from typing import Any, Callable, Literal, NotRequired, TypedDict
  """

  @doc """
  Every language `render/2` can generate.
  """
  @spec languages() :: [language()]
  def languages, do: @languages

  @doc """
  Resolve a language given as an atom or a string.

  Returns `:error` rather than raising, so a caller holding a language it read
  from provider configuration can fall back instead of failing a run.

  ## Examples

      iex> Nous.CodeMode.Sdk.coerce_language("typescript")
      {:ok, :typescript}

      iex> Nous.CodeMode.Sdk.coerce_language(:ruby)
      :error

  """
  # Never String.to_atom/1: a provider's `language/1` is configuration that may
  # come from an env var, and the atom table is finite.
  @spec coerce_language(term()) :: {:ok, language()} | :error
  def coerce_language(language) when language in @languages, do: {:ok, language}
  def coerce_language("javascript"), do: {:ok, :javascript}
  def coerce_language("typescript"), do: {:ok, :typescript}
  def coerce_language("python"), do: {:ok, :python}
  def coerce_language(_other), do: :error

  @doc """
  The name of the global the program calls tools through.

  The bindings a provider is handed must use this same global, or the SDK
  describes something the program cannot reach.
  """
  @spec global() :: String.t()
  def global, do: @global

  @doc """
  The exception class name the SDK tells the program to expect from a failed
  call. Bindings carry the same name in `Nous.CodeRuntime.Binding.error_class`.
  """
  @spec error_class() :: String.t()
  def error_class, do: @error_class

  @doc """
  The type a node gets when the generator cannot express it.

  ## Examples

      iex> Nous.CodeMode.Sdk.escape_hatch(:typescript)
      "unknown"

      iex> Nous.CodeMode.Sdk.escape_hatch(:python)
      "Any"

  """
  @spec escape_hatch(language() | String.t()) :: String.t()
  def escape_hatch(language) do
    case coerce_language!(language) do
      :python -> @py_any
      _js_or_ts -> @ts_unknown
    end
  end

  @doc """
  Render the SDK declaring `tools`.

  Tools are deduplicated by name (first occurrence wins, matching the runner's
  own lookup) and sorted lexicographically, so output depends on the tool
  *set*, never on the order it arrived in.

  Raises `ArgumentError` for a language this generator does not know; that is
  provider configuration, not model input.

  ## Examples

      iex> tool = %Nous.Tool{
      ...>   name: "greet",
      ...>   description: "Say hi",
      ...>   function: fn _ctx, _args -> {:ok, "hi"} end,
      ...>   parameters: %{
      ...>     "type" => "object",
      ...>     "properties" => %{"name" => %{"type" => "string"}},
      ...>     "required" => ["name"]
      ...>   }
      ...> }
      iex> sdk = Nous.CodeMode.Sdk.render("javascript", [tool])
      iex> sdk =~ ~s|"greet"(args: {|
      true

  """
  @spec render(language() | String.t(), [Tool.t()]) :: String.t()
  def render(language, tools) when is_list(tools) do
    lang = coerce_language!(language)

    tools =
      tools
      |> Enum.filter(&is_binary(&1.name))
      |> Enum.uniq_by(& &1.name)
      |> Enum.sort_by(& &1.name)

    case lang do
      :python -> render_python(tools)
      _js_or_ts -> render_typescript(tools)
    end
  end

  @doc """
  Convert one JSON Schema node to a `language` type expression.

  Total: any node the generator cannot express returns `escape_hatch/1` rather
  than raising. Accepts string- or atom-keyed schema maps.

  ## Examples

      iex> Nous.CodeMode.Sdk.json_schema_to_type(:typescript, %{"type" => "integer"})
      "number"

      iex> Nous.CodeMode.Sdk.json_schema_to_type(:python, %{"type" => "array"})
      "list[Any]"

      iex> Nous.CodeMode.Sdk.json_schema_to_type(:typescript, %{"$ref" => "#/definitions/x"})
      "unknown"

  """
  @spec json_schema_to_type(language() | String.t(), term()) :: String.t()
  def json_schema_to_type(language, schema) do
    case coerce_language!(language) do
      :python -> py_type(schema, 0)
      _js_or_ts -> ts_type(schema, 0)
    end
  end

  # --- TypeScript ------------------------------------------------------------

  defp render_typescript(tools) do
    members = Enum.map_join(tools, "\n\n", &ts_member/1)
    body = if members == "", do: "", else: "\n" <> members <> "\n"

    @ts_header <> "\ndeclare const #{@global}: {" <> body <> "};\n"
  end

  defp ts_member(%Tool{} = tool) do
    ts_doc(tool.description, "  ") <>
      "  #{literal(tool.name)}(args: #{ts_args(tool.parameters)}): Promise<#{@ts_unknown}>;"
  end

  # The top-level arguments object is the one place a parameter's own
  # description can reach the model, so it is rendered multi-line with doc
  # comments. Nested types stay single-line to keep the prefix small.
  defp ts_args(parameters) do
    case classify(parameters, 0) do
      {:object, [_ | _] = props, _additional} ->
        "{\n" <> Enum.map_join(props, "\n", &ts_documented_prop/1) <> "\n  }"

      _other ->
        ts_type(parameters, 0)
    end
  end

  defp ts_documented_prop({name, node, required?}) do
    doc =
      case description_of(node) do
        nil -> ""
        text -> "    /** #{close_safe(one_line(text))} */\n"
      end

    doc <> "    #{ts_prop({name, node, required?}, 1)};"
  end

  defp ts_prop({name, node, required?}, depth) do
    "#{literal(name)}#{if required?, do: "", else: "?"}: #{ts_type(node, depth)}"
  end

  defp ts_type(node, depth) do
    case classify(node, depth) do
      :escape -> @ts_unknown
      {:scalar, scalar} -> ts_scalar(scalar)
      {:enum, values} -> ts_enum(values)
      {:union, nodes} -> ts_combine(nodes, " | ", depth)
      {:intersection, nodes} -> ts_combine(nodes, " & ", depth)
      {:array, nil} -> "Array<#{@ts_unknown}>"
      {:array, items} -> "Array<#{ts_type(items, depth + 1)}>"
      {:tuple, nodes} -> "[" <> Enum.map_join(nodes, ", ", &ts_type(&1, depth + 1)) <> "]"
      {:object, [], additional} -> "Record<string, #{ts_additional(additional, depth)}>"
      {:object, props, _} -> "{ " <> Enum.map_join(props, "; ", &ts_prop(&1, depth + 1)) <> " }"
    end
  end

  defp ts_scalar("string"), do: "string"
  defp ts_scalar("integer"), do: "number"
  defp ts_scalar("number"), do: "number"
  defp ts_scalar("boolean"), do: "boolean"
  defp ts_scalar("null"), do: "null"

  defp ts_additional(additional, depth) when is_map(additional),
    do: ts_type(additional, depth + 1)

  defp ts_additional(_additional, _depth), do: @ts_unknown

  defp ts_combine([], _joiner, _depth), do: @ts_unknown

  defp ts_combine(nodes, joiner, depth) do
    nodes
    |> Enum.map(&ts_type(&1, depth + 1))
    |> Enum.uniq()
    |> Enum.join(joiner)
  end

  defp ts_enum(values) do
    case literals(values, &ts_literal/1) do
      [] -> @ts_unknown
      rendered -> Enum.join(rendered, " | ")
    end
  end

  defp ts_literal(value) when is_binary(value), do: literal(value)
  defp ts_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp ts_literal(value) when is_float(value), do: Float.to_string(value)
  defp ts_literal(true), do: "true"
  defp ts_literal(false), do: "false"
  defp ts_literal(nil), do: "null"
  defp ts_literal(_other), do: :error

  # A tool description is the only place the model reads what a tool is for, so
  # it is kept verbatim apart from closing the comment: an unescaped `*/` in a
  # description would end the block early and leave the rest as broken code.
  defp ts_doc(nil, _indent), do: ""

  defp ts_doc(description, indent) when is_binary(description) do
    case String.trim(description) do
      "" ->
        ""

      text ->
        lines =
          text
          |> close_safe()
          |> String.split(~r/\r?\n/)
          |> Enum.map_join("\n", &"#{indent} * #{String.trim_trailing(&1)}")

        "#{indent}/**\n#{lines}\n#{indent} */\n"
    end
  end

  defp ts_doc(_description, _indent), do: ""

  # --- Python ----------------------------------------------------------------

  defp render_python(tools) do
    {aliases, members} =
      tools
      |> Enum.with_index(1)
      |> Enum.map(fn {tool, index} ->
        {alias_block, arg_type} = py_args(tool, index)
        {alias_block, "    #{literal(tool.name)}: Callable[[#{arg_type}], #{@py_any}],"}
      end)
      |> Enum.unzip()

    alias_text =
      case Enum.reject(aliases, &(&1 == "")) do
        [] -> ""
        blocks -> Enum.join(blocks, "\n") <> "\n"
      end

    body =
      case members do
        [] -> ""
        _ -> "\n" <> Enum.join(members, "\n") <> "\n"
      end

    @py_header <>
      "\n" <>
      alias_text <>
      "\n#{@py_type_name} = TypedDict(#{literal(@py_type_name)}, {" <>
      body <> "})\n\n#{@global}: #{@py_type_name}\n"
  end

  # Python has no anonymous record type, so an object schema with properties
  # becomes a named TypedDict alias numbered by the tool's position in the
  # sorted list — deterministic, and free of any name mangling that two tools
  # could collide on. Everything else is inlined.
  defp py_args(%Tool{} = tool, index) do
    case classify(tool.parameters, 0) do
      {:object, [_ | _] = props, _additional} ->
        name = "Args#{index}"
        fields = Enum.map_join(props, ", ", &py_field/1)
        {py_comment(tool, props) <> "#{name} = TypedDict(#{literal(name)}, {#{fields}})\n", name}

      _other ->
        {"", py_type(tool.parameters, 0)}
    end
  end

  defp py_field({name, node, true}), do: "#{literal(name)}: #{py_type(node, 1)}"
  defp py_field({name, node, false}), do: "#{literal(name)}: NotRequired[#{py_type(node, 1)}]"

  defp py_comment(%Tool{} = tool, props) do
    header =
      case tool.description do
        text when is_binary(text) ->
          case String.trim(text) do
            "" -> "# #{tool.name}\n"
            trimmed -> "# #{tool.name} — #{one_line(trimmed)}\n"
          end

        _ ->
          "# #{tool.name}\n"
      end

    params =
      props
      |> Enum.map(fn {name, node, _required?} -> {name, description_of(node)} end)
      |> Enum.reject(fn {_name, doc} -> is_nil(doc) end)
      |> Enum.map_join("", fn {name, doc} -> "#   #{name}: #{one_line(doc)}\n" end)

    header <> params
  end

  defp py_type(node, depth) do
    case classify(node, depth) do
      :escape -> @py_any
      {:scalar, scalar} -> py_scalar(scalar)
      {:enum, values} -> py_enum(values)
      {:union, nodes} -> py_union(nodes, depth)
      # Python has no intersection type.
      {:intersection, _nodes} -> @py_any
      {:array, nil} -> "list[#{@py_any}]"
      {:array, items} -> "list[#{py_type(items, depth + 1)}]"
      {:tuple, nodes} -> "tuple[" <> Enum.map_join(nodes, ", ", &py_type(&1, depth + 1)) <> "]"
      {:object, [], additional} -> "dict[str, #{py_additional(additional, depth)}]"
      # A nested record would need a name; only the top level gets a TypedDict.
      {:object, _props, _additional} -> "dict[str, #{@py_any}]"
    end
  end

  defp py_scalar("string"), do: "str"
  defp py_scalar("integer"), do: "int"
  defp py_scalar("number"), do: "float"
  defp py_scalar("boolean"), do: "bool"
  defp py_scalar("null"), do: "None"

  defp py_additional(additional, depth) when is_map(additional),
    do: py_type(additional, depth + 1)

  defp py_additional(_additional, _depth), do: @py_any

  defp py_union([], _depth), do: @py_any

  defp py_union(nodes, depth) do
    nodes
    |> Enum.map(&py_type(&1, depth + 1))
    |> Enum.uniq()
    |> Enum.join(" | ")
  end

  defp py_enum(values) do
    case literals(values, &py_literal/1) do
      [] -> @py_any
      rendered -> "Literal[" <> Enum.join(rendered, ", ") <> "]"
    end
  end

  defp py_literal(value) when is_binary(value), do: literal(value)
  defp py_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp py_literal(true), do: "True"
  defp py_literal(false), do: "False"
  defp py_literal(nil), do: "None"
  # `Literal[]` admits str/int/bool/None/enum only — a float member is not a
  # Python literal type, so the whole enum degrades.
  defp py_literal(_other), do: :error

  # --- Schema classification -------------------------------------------------

  # One classifier, two formatters. Everything here is defensive: schemas reach
  # us from tool authors and, through `parameters:`, from callers, so every
  # field is checked for shape before it is used.
  @typep prop :: {String.t(), term(), boolean()}

  @typep classified ::
           :escape
           | {:scalar, String.t()}
           | {:enum, [term()]}
           | {:union, [term()]}
           | {:intersection, [term()]}
           | {:array, term() | nil}
           | {:tuple, [term()]}
           | {:object, [prop()], term()}

  @spec classify(term(), non_neg_integer()) :: classified()
  defp classify(_node, depth) when depth > @max_depth, do: :escape
  defp classify(node, _depth) when not is_map(node), do: :escape

  defp classify(node, depth) do
    cond do
      # No resolver, so a reference is a node we cannot express.
      not is_nil(get(node, "$ref")) -> :escape
      is_list(get(node, "enum")) -> {:enum, get(node, "enum")}
      is_list(get(node, "oneOf")) -> {:union, get(node, "oneOf")}
      is_list(get(node, "anyOf")) -> {:union, get(node, "anyOf")}
      is_list(get(node, "allOf")) -> {:intersection, get(node, "allOf")}
      is_list(get(node, "type")) -> {:union, split_type_union(node)}
      true -> classify_type(node, get(node, "type"), depth)
    end
  end

  defp classify_type(node, "object", _depth), do: classify_object(node)
  defp classify_type(node, "array", _depth), do: classify_array(node)

  defp classify_type(_node, type, _depth) when type in ~w(string number integer boolean null),
    do: {:scalar, type}

  # A schema with no `type` but a recognisable body is still expressible; JSON
  # Schema does not require `type` and hand-written tool schemas often omit it.
  defp classify_type(node, nil, _depth) do
    cond do
      is_map(get(node, "properties")) -> classify_object(node)
      not is_nil(get(node, "items")) -> classify_array(node)
      true -> :escape
    end
  end

  defp classify_type(_node, _type, _depth), do: :escape

  defp classify_object(node) do
    props = get(node, "properties")
    additional = get(node, "additionalProperties")

    if is_map(props) do
      {:object, prop_list(props, required_set(node)), additional}
    else
      {:object, [], additional}
    end
  end

  defp classify_array(node) do
    case get(node, "items") do
      items when is_map(items) -> {:array, items}
      # Draft-4 tuple form.
      items when is_list(items) -> {:tuple, items}
      _other -> {:array, nil}
    end
  end

  # Sorted so a large map (which iterates in hash order, not insertion order)
  # cannot make the rendered SDK depend on how the schema was built.
  defp prop_list(props, required) do
    props
    |> Enum.map(fn {name, node} -> {key_to_string(name), node} end)
    |> Enum.reject(fn {name, _node} -> is_nil(name) end)
    |> Enum.sort_by(fn {name, _node} -> name end)
    |> Enum.map(fn {name, node} -> {name, node, MapSet.member?(required, name)} end)
  end

  defp required_set(node) do
    case get(node, "required") do
      list when is_list(list) ->
        list
        |> Enum.map(&key_to_string/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      _other ->
        MapSet.new()
    end
  end

  defp split_type_union(node) do
    node
    |> get("type")
    |> Enum.map(fn type -> node |> Map.delete(:type) |> Map.put("type", type) end)
  end

  # --- Shared helpers --------------------------------------------------------

  # Schema maps reach us with string keys (everything Nous generates) or atom
  # keys (hand-written `parameters:`). The atom side is a fixed compile-time
  # table: no atom is ever created from input.
  @atom_keys %{
    "type" => :type,
    "properties" => :properties,
    "required" => :required,
    "items" => :items,
    "enum" => :enum,
    "oneOf" => :oneOf,
    "anyOf" => :anyOf,
    "allOf" => :allOf,
    "$ref" => :"$ref",
    "additionalProperties" => :additionalProperties,
    "description" => :description
  }

  defp get(node, key) when is_map(node) do
    case Map.fetch(node, key) do
      {:ok, value} -> value
      :error -> Map.get(node, Map.fetch!(@atom_keys, key))
    end
  end

  defp description_of(node) when is_map(node) do
    case get(node, "description") do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: text
      _other -> nil
    end
  end

  defp description_of(_node), do: nil

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp key_to_string(_key), do: nil

  # Render every literal or none: a single unrepresentable member would make
  # the union silently narrower than the schema, which is worse than no type.
  defp literals(values, formatter) do
    result =
      Enum.reduce_while(values, [], fn value, acc ->
        case formatter.(value) do
          :error -> {:halt, :error}
          rendered -> {:cont, [rendered | acc]}
        end
      end)

    case result do
      :error -> []
      rendered -> Enum.reverse(rendered)
    end
  end

  # JSON string literals are valid string literals in both target languages,
  # and escape the quote, backslash, control character or newline that a hostile
  # or merely careless tool name would otherwise use to break out.
  defp literal(value) when is_binary(value), do: JSON.encode!(value)

  defp one_line(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  # An unescaped `*/` in a description would close the block comment early and
  # leave the rest of the SDK as broken code.
  defp close_safe(text), do: String.replace(text, "*/", "*\\/")

  defp coerce_language!(language) do
    case coerce_language(language) do
      {:ok, lang} ->
        lang

      :error ->
        raise ArgumentError,
              "unsupported SDK language #{inspect(language)}; expected one of " <>
                Enum.map_join(@languages, ", ", &inspect/1)
    end
  end
end
