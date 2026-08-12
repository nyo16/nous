defmodule Nous.DocSnippets do
  @moduledoc false
  # Extraction + static resolution engine behind `test/docs/api_reference_test.exs`.
  #
  # Nothing here compiles or evaluates documentation code: snippets are parsed to
  # AST and every `Nous.*` remote call / struct literal is resolved against the
  # loaded beam. That is deliberately weaker than compiling (no type checking) and
  # deliberately stronger than grep (alias-aware, arity-aware).

  @type snippet :: %{file: String.t(), line: pos_integer(), code: String.t()}
  @type issue :: %{file: String.t(), line: pos_integer(), message: String.t()}

  @markdown_roots ["README.md", "AGENTS.md", "CONTRIBUTING.md"]

  @doc "Every markdown file whose ```elixir fences and relative links are guarded."
  @spec markdown_files() :: [String.t()]
  def markdown_files do
    (@markdown_roots ++ Path.wildcard("docs/**/*.md") ++ Path.wildcard("examples/**/*.md"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  @doc "Every runnable example script."
  @spec example_files() :: [String.t()]
  def example_files, do: Enum.sort(Path.wildcard("examples/**/*.exs"))

  @doc """
  All snippets to check: one per example script, one per ```elixir fence.

  A fence's `:line` is the line of its opening ``` marker, which is what the
  allowlist keys on.
  """
  @spec snippets() :: [snippet()]
  def snippets do
    scripts = Enum.map(example_files(), &%{file: &1, line: 1, code: File.read!(&1)})
    scripts ++ Enum.flat_map(markdown_files(), &elixir_fences/1)
  end

  # ── Fence extraction ──────────────────────────────────────────────────────

  @doc "Extracts ```elixir fences from a markdown file, with 1-based line numbers."
  @spec elixir_fences(String.t()) :: [snippet()]
  def elixir_fences(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, &fence_step(&1, &2, path))
    |> elem(0)
    |> Enum.reverse()
  end

  defp fence_step({line, idx}, {done, nil}, _path) do
    if elixir_fence_open?(line), do: {done, {idx, []}}, else: {done, nil}
  end

  defp fence_step({line, _idx}, {done, {start, acc}}, path) do
    if fence_close?(line) do
      snippet = %{file: path, line: start, code: acc |> Enum.reverse() |> Enum.join("\n")}
      {[snippet | done], nil}
    else
      {done, {start, [line | acc]}}
    end
  end

  defp elixir_fence_open?(line) do
    case String.trim(line) do
      "```elixir" -> true
      "```elixir " <> _ -> true
      _ -> false
    end
  end

  defp fence_close?(line), do: String.trim(line) == "```"

  # ── Static resolution ─────────────────────────────────────────────────────

  @doc """
  Resolves every `Nous.*` remote call and struct literal in `snippet`.

  Returns `{:ok, issues}` for a snippet that parses (`issues` may be empty) or
  `{:parse_error, message}` for one that does not.
  """
  @spec check(snippet()) :: {:ok, [issue()]} | {:parse_error, String.t()}
  def check(%{file: file, line: line, code: code}) do
    case Code.string_to_quoted(code, file: file, line: line) do
      {:ok, ast} -> {:ok, resolve(ast, file, line)}
      {:error, {meta, message, token}} -> {:parse_error, parse_error(meta, message, token)}
    end
  end

  defp parse_error(meta, message, token) do
    detail = message |> to_string() |> String.trim()
    "line #{meta[:line] || "?"}: #{detail}#{token_suffix(token)}"
  end

  defp token_suffix(""), do: ""
  defp token_suffix(token), do: " #{inspect(to_string(token))}"

  defp resolve(ast, file, fallback_line) do
    env = build_env(ast)

    ast
    |> normalize()
    |> collect(env)
    |> Enum.map(fn {line, message} ->
      %{file: file, line: line || fallback_line, message: message}
    end)
  end

  # Rewrites the three forms whose surface arity differs from their call arity,
  # and prunes typespecs (where `Nous.Tool.t()` is a type, not a function).
  defp normalize(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{name, _, _}]} when name in ~w(spec type typep opaque callback macrocallback)a ->
        nil

      # `lhs |> Mod.fun(a)` calls `Mod.fun/2`
      {:|>, _, [lhs, {{:., dot_meta, [target, fun]}, meta, args}]}
      when is_atom(fun) and is_list(args) ->
        {{:., dot_meta, [target, fun]}, meta, [lhs | args]}

      # `&Mod.fun/2` references `Mod.fun/2`, not `Mod.fun/0`
      {:&, _, [{:/, _, [{{:., dot_meta, [target, fun]}, meta, []}, arity]}]}
      when is_atom(fun) and is_integer(arity) ->
        {{:., dot_meta, [target, fun]}, meta, List.duplicate(nil, arity)}

      node ->
        node
    end)
  end

  # ── Pass 1: aliases + inline module definitions ───────────────────────────

  defp build_env(ast) do
    {_, env} =
      Macro.prewalk(ast, %{aliases: %{}, local: MapSet.new()}, fn node, env ->
        {node, env_step(node, env)}
      end)

    env
  end

  defp env_step({:defmodule, _, [{:__aliases__, _, parts} | _]}, env) do
    %{env | local: MapSet.put(env.local, Module.concat(parts))}
  end

  defp env_step({:alias, _, [{:__aliases__, _, parts}]}, env) do
    put_alias(env, List.last(parts), Module.concat(parts))
  end

  defp env_step({:alias, _, [{:__aliases__, _, parts}, opts]}, env) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as]} -> put_alias(env, as, Module.concat(parts))
      _ -> put_alias(env, List.last(parts), Module.concat(parts))
    end
  end

  # `alias Nous.{Agent, Tool}`
  defp env_step({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}, env) do
    Enum.reduce(children, env, fn
      {:__aliases__, _, parts}, acc ->
        put_alias(acc, List.last(parts), Module.concat(base ++ parts))

      _, acc ->
        acc
    end)
  end

  defp env_step(_node, env), do: env

  defp put_alias(env, key, target) when is_atom(key),
    do: %{env | aliases: Map.put(env.aliases, key, target)}

  # ── Pass 2: remote calls and struct literals ──────────────────────────────

  defp collect(ast, env) do
    {_, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, check_node(node, env) ++ acc}
      end)

    Enum.reverse(issues)
  end

  # %Nous.Struct{field: _}
  defp check_node({:%, meta, [{:__aliases__, _, parts}, {:%{}, _, fields}]}, env) do
    with {:ok, mod} <- expand(parts, env),
         :ok <- ensure_loaded(mod) do
      struct_field_issues(mod, fields, meta[:line])
    else
      {:error, message} -> [{meta[:line], message}]
      :skip -> []
    end
  end

  # `alias Nous.{A, B}` parses as a call to `Nous.{}/2` — it is an alias, not a call.
  defp check_node({{:., _, [{:__aliases__, _, _}, :{}]}, _, _}, _env), do: []

  # Nous.Module.function(args)
  defp check_node({{:., meta, [{:__aliases__, _, parts}, fun]}, call_meta, args}, env)
       when is_atom(fun) and is_list(args) do
    line = call_meta[:line] || meta[:line]

    with {:ok, mod} <- expand(parts, env),
         :ok <- ensure_loaded(mod),
         :ok <- ensure_exported(mod, fun, length(args)) do
      []
    else
      {:error, message} -> [{line, message}]
      :skip -> []
    end
  end

  defp check_node(_node, _env), do: []

  defp expand(parts, env) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      [head | rest] = parts
      base = Map.get(env.aliases, head, Module.concat([head]))
      mod = if rest == [], do: base, else: Module.concat([base | rest])

      cond do
        MapSet.member?(env.local, mod) -> :skip
        guarded?(mod) -> {:ok, mod}
        true -> :skip
      end
    else
      :skip
    end
  end

  defp expand(_parts, _env), do: :skip

  # Only the library's own surface is guarded. Elixir/Erlang stdlib and
  # third-party modules in snippets are out of scope.
  defp guarded?(mod) do
    case Module.split(mod) do
      ["Nous" | _] -> true
      _ -> false
    end
  end

  defp ensure_loaded(mod) do
    if Code.ensure_loaded?(mod),
      do: :ok,
      else: {:error, "unknown module #{inspect(mod)}"}
  end

  defp ensure_exported(mod, fun, arity) do
    exports = mod.__info__(:functions) ++ mod.__info__(:macros)

    cond do
      {fun, arity} in exports ->
        :ok

      arities = arities_for(exports, fun) ->
        {:error,
         "#{inspect(mod)}.#{fun}/#{arity} does not exist " <>
           "(defined arities: #{Enum.join(arities, ", ")})"}

      true ->
        {:error, "#{inspect(mod)}.#{fun}/#{arity} does not exist"}
    end
  end

  defp arities_for(exports, fun) do
    case exports |> Enum.filter(&(elem(&1, 0) == fun)) |> Enum.map(&elem(&1, 1)) |> Enum.sort() do
      [] -> nil
      arities -> arities
    end
  end

  defp struct_field_issues(mod, fields, line) do
    with true <- function_exported?(mod, :__struct__, 0),
         {:ok, keys} <- struct_keys(mod) do
      fields
      |> struct_literal_keys()
      |> Enum.reject(&(&1 in keys))
      |> Enum.map(&{line, "%#{inspect(mod)}{} has no field #{inspect(&1)}"})
    else
      _ -> []
    end
  end

  defp struct_keys(mod) do
    {:ok, mod |> struct() |> Map.keys()}
  rescue
    _ -> :error
  end

  # `%Mod{a: 1}` -> [:a]; `%Mod{existing | a: 1}` -> [:a]
  defp struct_literal_keys([{:|, _, [_base, kvs]}]) when is_list(kvs),
    do: struct_literal_keys(kvs)

  defp struct_literal_keys(fields) when is_list(fields) do
    for {key, _value} <- fields, is_atom(key), do: key
  end

  defp struct_literal_keys(_), do: []

  # ── Relative markdown links ───────────────────────────────────────────────

  @link_regex ~r/\[[^\]\n]*\]\(([^)\s]+)\)/

  @doc "Relative-link and anchor issues for a markdown file."
  @spec link_issues(String.t()) :: [issue()]
  def link_issues(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> strip_code_fences()
    |> Enum.flat_map(fn {line, idx} ->
      @link_regex
      |> Regex.scan(line)
      |> Enum.flat_map(fn [_, target] -> link_issue(path, target, idx) end)
    end)
  end

  defp strip_code_fences(numbered_lines) do
    numbered_lines
    |> Enum.reduce({[], false}, fn {line, idx}, {kept, in_fence?} ->
      cond do
        String.starts_with?(String.trim(line), "```") -> {kept, not in_fence?}
        in_fence? -> {kept, in_fence?}
        true -> {[{line, idx} | kept], in_fence?}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp link_issue(path, target, line) do
    cond do
      external?(target) -> []
      String.starts_with?(target, "#") -> anchor_issue(path, path, target, line)
      true -> path_issue(path, target, line)
    end
  end

  defp external?(target) do
    String.starts_with?(target, ["http://", "https://", "mailto:", "<", "data:", "/"])
  end

  defp path_issue(path, target, line) do
    {rel, anchor} = split_anchor(target)
    resolved = path |> Path.dirname() |> Path.join(rel) |> Path.expand() |> relative_to_cwd()

    cond do
      not File.exists?(resolved) ->
        [issue(path, line, "dead relative link #{inspect(target)} -> #{resolved}")]

      anchor == nil or File.dir?(resolved) ->
        []

      true ->
        anchor_issue(path, resolved, "#" <> anchor, line)
    end
  end

  defp split_anchor(target) do
    case String.split(target, "#", parts: 2) do
      [rel] -> {uri_decode(rel), nil}
      [rel, anchor] -> {uri_decode(rel), anchor}
    end
  end

  defp uri_decode(rel), do: URI.decode(rel)

  defp relative_to_cwd(abs), do: Path.relative_to(abs, File.cwd!())

  defp anchor_issue(source, target_path, "#" <> anchor, line) do
    if anchor in headings(target_path) do
      []
    else
      [issue(source, line, "link anchor ##{anchor} has no matching heading in #{target_path}")]
    end
  end

  @doc "GitHub-style heading slugs for a markdown file."
  @spec headings(String.t()) :: [String.t()]
  def headings(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> strip_code_fences()
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&Regex.match?(~r/^\#{1,6}\s+/, &1))
        |> Enum.map(&slug/1)

      _ ->
        []
    end
  end

  # GitHub's algorithm: downcase, drop punctuation other than `-`/`_`, then map
  # each remaining space to a hyphen — runs of spaces are NOT collapsed, which
  # is why "A & B" slugs to "a--b".
  defp slug(heading) do
    heading
    |> String.replace(~r/^#+\s+/, "")
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "")
    |> String.replace(~r/\s/u, "-")
  end

  defp issue(file, line, message), do: %{file: file, line: line, message: message}

  @doc "Formats issues into a readable assertion failure."
  @spec format(String.t(), [issue()]) :: String.t()
  def format(header, issues) do
    body =
      issues
      |> Enum.sort_by(&{&1.file, &1.line})
      |> Enum.map_join("\n", &"  #{&1.file}:#{&1.line} — #{&1.message}")

    "#{header} (#{length(issues)}):\n#{body}\n"
  end
end
