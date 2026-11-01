defmodule Nous.Eval.Scorers.Args do
  @moduledoc false
  # Tool-argument comparison shared by Trajectory and ToolArgs
  # (research/scorers.md §4.5).
  #
  #   * expected keys: atom keys become strings (atom -> string is safe; the
  #     reverse never happens); atom values other than booleans, nil and
  #     `:any` become strings too, so `%{unit: :celsius}` matches the JSON
  #     `"celsius"`
  #   * `:any` as an expected value matches any present value
  #   * an actual string is JSON-decoded when the expected value is a map or
  #     list (models sometimes send nested arguments as encoded JSON)
  #   * `:subset` is recursive for maps, positional for lists; `:exact`
  #     also rejects extra keys
  #   * numbers compare with `==` (so 1 == 1.0) or a tolerance; a string
  #     never equals a number
  #
  # `diff/4` returns the paths that differ ("$" is the root,
  # "items[0].sku" a nested path), `[]` on a match. Paths only: the
  # expected values stay out of score details.

  alias Nous.Eval.Scorers.Options

  @modes [:exact, :subset, :ignore]

  def modes, do: @modes

  @doc "Parses an `args` option: a mode, its string name, or a 2-arity function."
  def parse_mode(scorer, key, value) do
    if is_function(value, 2), do: {:ok, value}, else: Options.enum(scorer, key, value, @modes)
  end

  @doc "Parses `numbers`: `:exact` or a tolerance (`{:tolerance, abs: _, rel: _}`)."
  def parse_numbers(_scorer, value) when value in [:exact, "exact"], do: {:ok, :exact}

  def parse_numbers(scorer, {:tolerance, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:abs, :rel] == [],
      do: tolerance(scorer, Keyword.get(opts, :abs, 0), Keyword.get(opts, :rel, 0)),
      else: Options.invalid(scorer, "numbers tolerance takes abs: and rel:, got #{inspect(opts)}")
  end

  def parse_numbers(scorer, %{"tolerance" => %{} = opts}) do
    if Map.keys(opts) -- ["abs", "rel"] == [],
      do: tolerance(scorer, Map.get(opts, "abs", 0), Map.get(opts, "rel", 0)),
      else: Options.invalid(scorer, "numbers tolerance takes abs and rel, got #{inspect(opts)}")
  end

  def parse_numbers(scorer, other),
    do:
      Options.invalid(
        scorer,
        "numbers must be :exact or {:tolerance, abs: _, rel: _}, got #{inspect(other)}"
      )

  defp tolerance(_scorer, abs, rel)
       when is_number(abs) and abs >= 0 and is_number(rel) and rel >= 0,
       do: {:ok, {:tolerance, abs, rel}}

  defp tolerance(scorer, abs, rel),
    do:
      Options.invalid(
        scorer,
        "numbers tolerance must be non-negative, got abs #{inspect(abs)} rel #{inspect(rel)}"
      )

  @doc "Compiles `ignore_args` globs (`*` matches any run of characters)."
  def parse_ignore(_scorer, nil), do: {:ok, []}
  def parse_ignore(_scorer, []), do: {:ok, []}

  def parse_ignore(scorer, globs) when is_list(globs) do
    if Enum.all?(globs, &is_binary/1) do
      {:ok, Enum.map(globs, &glob/1)}
    else
      Options.invalid(scorer, "ignore_args must be a list of strings, got #{inspect(globs)}")
    end
  end

  def parse_ignore(scorer, other),
    do: Options.invalid(scorer, "ignore_args must be a list of strings, got #{inspect(other)}")

  defp glob(pattern) do
    source = pattern |> Regex.escape() |> String.replace("\\*", ".*")
    Regex.compile!("\\A" <> source <> "\\z")
  end

  @doc "Parses `arg_defaults`: tool name => default argument map."
  def parse_defaults(_scorer, nil), do: {:ok, %{}}

  def parse_defaults(scorer, %{} = defaults) do
    if Enum.all?(defaults, fn {tool, map} -> is_binary(tool) and is_map(map) end),
      do: {:ok, Map.new(defaults, fn {tool, map} -> {tool, normalize_expected(map)} end)},
      else: Options.invalid(scorer, "arg_defaults must map tool names to argument maps")
  end

  def parse_defaults(scorer, other),
    do: Options.invalid(scorer, "arg_defaults must be a map, got #{inspect(other)}")

  @doc "Parses `args_overrides`: tool name => mode, function, or a list of keys to compare."
  def parse_overrides(_scorer, nil), do: {:ok, %{}}

  def parse_overrides(scorer, %{} = overrides) do
    Enum.reduce_while(overrides, {:ok, %{}}, fn {tool, value}, {:ok, acc} ->
      parsed =
        cond do
          not is_binary(tool) ->
            Options.invalid(
              scorer,
              "args_overrides keys must be tool names, got #{inspect(tool)}"
            )

          is_list(value) and value != [] ->
            keys = Enum.map(value, &key/1)

            if Enum.all?(keys, &is_binary/1),
              do: {:ok, {:keys, keys}},
              else: Options.invalid(scorer, "args_overrides #{tool}: invalid key list")

          true ->
            parse_mode(scorer, "args_overrides #{tool}", value)
        end

      case parsed do
        {:ok, mode} -> {:cont, {:ok, Map.put(acc, tool, mode)}}
        error -> {:halt, error}
      end
    end)
  end

  def parse_overrides(scorer, other),
    do: Options.invalid(scorer, "args_overrides must be a map, got #{inspect(other)}")

  @doc "Normalizes Elixir-authored expected values to the JSON shape of actual arguments."
  def normalize_expected(:any), do: :any

  def normalize_expected(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {key(k), normalize_expected(v)} end)

  def normalize_expected(list) when is_list(list), do: Enum.map(list, &normalize_expected/1)

  def normalize_expected(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  def normalize_expected(other), do: other

  defp normalize_actual(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {key(k), normalize_actual(v)} end)

  defp normalize_actual(list) when is_list(list), do: Enum.map(list, &normalize_actual/1)
  defp normalize_actual(other), do: other

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: k

  @doc """
  The paths where `actual` arguments of `tool` fail to match `expected`
  under `config` (`%{args:, overrides:, ignore:, defaults:, numbers:}`).
  """
  def diff(tool, actual, expected, config) do
    mode = Map.get(config.overrides, tool, config.args)
    defaults = Map.get(config.defaults, tool, %{})
    actual = actual |> normalize_actual() |> prepare(config.ignore, defaults)
    expected = prepare(expected, config.ignore, defaults)

    case mode do
      :ignore ->
        []

      fun when is_function(fun, 2) ->
        if fun.(actual, expected), do: [], else: ["$"]

      {:keys, keys} ->
        compare(take(actual, keys), take(expected, keys), :exact, config.numbers, [])

      mode ->
        compare(actual, expected, mode, config.numbers, [])
    end
  end

  def match?(tool, actual, expected, config), do: diff(tool, actual, expected, config) == []

  @doc "The `diff/4` config from a scorer's parsed options."
  def config(options) do
    %{
      args: Map.get(options, :args, :subset),
      overrides: Map.get(options, :args_overrides, %{}),
      ignore: Map.get(options, :ignore_args, []),
      defaults: Map.get(options, :arg_defaults, %{}),
      numbers: Map.get(options, :numbers, :exact)
    }
  end

  defp take(%{} = map, keys), do: Map.take(map, keys)
  defp take(other, _keys), do: other

  defp prepare(%{} = args, ignore, defaults) when not is_struct(args) do
    args
    |> Enum.reject(fn {k, v} ->
      (is_binary(k) and Enum.any?(ignore, &Regex.match?(&1, k))) or
        (is_map_key(defaults, k) and Map.fetch!(defaults, k) == v)
    end)
    |> Map.new()
  end

  defp prepare(other, _ignore, _defaults), do: other

  defp compare(_actual, :any, _mode, _numbers, _path), do: []

  defp compare(actual, expected, mode, numbers, path)
       when is_binary(actual) and (is_map(expected) or is_list(expected)) do
    case JSON.decode(actual) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        compare(decoded, expected, mode, numbers, path)

      _ ->
        [render(path)]
    end
  end

  defp compare(%{} = actual, %{} = expected, mode, numbers, path)
       when not is_struct(actual) and not is_struct(expected) do
    missing_or_different =
      Enum.flat_map(expected, fn {k, v} ->
        case Map.fetch(actual, k) do
          {:ok, a} -> compare(a, v, mode, numbers, [k | path])
          :error -> [render([k | path])]
        end
      end)

    extra =
      if mode == :exact,
        do: for(k <- Map.keys(actual), not is_map_key(expected, k), do: render([k | path])),
        else: []

    missing_or_different ++ extra
  end

  defp compare(actual, expected, mode, numbers, path)
       when is_list(actual) and is_list(expected) do
    if length(actual) == length(expected) do
      actual
      |> Enum.zip(expected)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{a, e}, i} -> compare(a, e, mode, numbers, [{:index, i} | path]) end)
    else
      [render(path)]
    end
  end

  defp compare(actual, expected, _mode, numbers, path)
       when is_number(actual) and is_number(expected) do
    if number_equal?(actual, expected, numbers), do: [], else: [render(path)]
  end

  defp compare(actual, expected, _mode, _numbers, path) do
    if actual === expected, do: [], else: [render(path)]
  end

  defp number_equal?(a, e, :exact), do: a == e

  defp number_equal?(a, e, {:tolerance, abs, rel}),
    do: Kernel.abs(a - e) <= max(abs, rel * Kernel.abs(e))

  defp render([]), do: "$"

  defp render(path) do
    path
    |> Enum.reverse()
    |> Enum.reduce("", fn
      {:index, i}, acc -> acc <> "[#{i}]"
      k, "" -> to_string(k)
      k, acc -> acc <> "." <> to_string(k)
    end)
  end
end
