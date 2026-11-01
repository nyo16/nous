defmodule Nous.Eval.CanonicalJSON do
  @moduledoc """
  Deterministic JSON encoding for content hashes.

  Dataset hashes and run fingerprints are `"sha256:" <> hex` digests of this
  encoding. The format is documented so other tools can recompute a hash
  from the same data:

    * object keys sorted by their UTF-8 bytes, at every depth
    * no insignificant whitespace
    * strings: UTF-8, only `"`, `\\` and control characters below U+0020 are
      escaped (`\\b \\f \\n \\r \\t`, otherwise `\\u00XX` in lowercase hex); no
      Unicode normalization (the bytes are the content)
    * integers in decimal; a float with an integral value below 2^53 encodes
      as that integer (`1.0` -> `1`), other floats in the shortest form that
      round-trips (`0.1`), so `1` from YAML and `1.0` from a Python-written
      JSONL file hash the same
    * `nil`, `true`, `false` as `null`, `true`, `false`; any other atom as its
      string (`:superset` -> `"superset"`, `MyApp.Scorer` -> `"Elixir.MyApp.Scorer"`)
    * map keys may be strings or atoms (atoms become strings); two keys with
      the same string form (`:a` and `"a"`) are an error

  Structs, tuples, functions, pids and other terms have no JSON form and
  raise `ArgumentError`: callers turn them into plain data first, so the
  hash never depends on how a struct happens to be laid out.

  Elixir's `JSON.encode!/1` is not used because it does not sort the keys of
  maps with more than 32 entries.
  """

  # Largest integer a float holds exactly; integral floats below it encode as
  # integers.
  @max_exact_float 9_007_199_254_740_992

  @doc """
  Encodes `term` as canonical JSON.

  Raises `ArgumentError` for a term with no JSON form (see the moduledoc).

  ## Examples

      iex> Nous.Eval.CanonicalJSON.encode(%{"b" => [1, 2.5, nil], a: "x"})
      ~s({"a":"x","b":[1,2.5,null]})

      iex> Nous.Eval.CanonicalJSON.encode(1.0)
      "1"
  """
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> do_encode() |> IO.iodata_to_binary()

  @doc """
  The content hash of `term`: `"sha256:"` followed by the lowercase hex
  SHA-256 of `encode/1`.
  """
  @spec hash(term()) :: String.t()
  def hash(term), do: digest(encode(term))

  @doc false
  # Shared by the dataset and fingerprint modules for raw text (instructions),
  # which is hashed as bytes, not as a JSON string.
  @spec digest(iodata()) :: String.t()
  def digest(data), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"
  defp do_encode(atom) when is_atom(atom), do: encode_string(Atom.to_string(atom))
  defp do_encode(binary) when is_binary(binary), do: encode_string(binary)
  defp do_encode(int) when is_integer(int), do: Integer.to_string(int)

  defp do_encode(float) when is_float(float) do
    if float == Float.round(float) and abs(float) < @max_exact_float do
      Integer.to_string(trunc(float))
    else
      :erlang.float_to_binary(float, [:short])
    end
  end

  defp do_encode(list) when is_list(list) do
    [?[, list |> Enum.map(&do_encode/1) |> Enum.intersperse(?,), ?]]
  end

  defp do_encode(%module{}) do
    raise ArgumentError,
          "canonical JSON has no encoding for structs (got %#{inspect(module)}{}); " <>
            "convert it to a plain map first"
  end

  defp do_encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {key, value} -> {key_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))

    check_unique_keys!(pairs)

    members =
      Enum.map(pairs, fn {key, value} -> [encode_string(key), ?:, do_encode(value)] end)

    [?{, Enum.intersperse(members, ?,), ?}]
  end

  defp do_encode(other) do
    raise ArgumentError, "canonical JSON has no encoding for #{inspect(other)}"
  end

  defp key_string(key) when is_binary(key), do: key

  defp key_string(key) when is_atom(key) and key not in [nil, true, false],
    do: Atom.to_string(key)

  defp key_string(key) do
    raise ArgumentError,
          "canonical JSON object keys must be strings or atoms, got #{inspect(key)}"
  end

  defp check_unique_keys!(sorted_pairs) do
    sorted_pairs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn
      [{key, _}, {key, _}] ->
        raise ArgumentError, "canonical JSON object has the key #{inspect(key)} twice"

      _ ->
        :ok
    end)
  end

  defp encode_string(string) do
    if String.valid?(string) do
      [?", escape(string, []), ?"]
    else
      raise ArgumentError, "canonical JSON strings must be valid UTF-8, got #{inspect(string)}"
    end
  end

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])

  defp escape(<<char, rest::binary>>, acc) when char < 0x20 do
    hex = char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    escape(rest, ["\\u" <> hex | acc])
  end

  defp escape(<<char, rest::binary>>, acc), do: escape(rest, [char | acc])
end
