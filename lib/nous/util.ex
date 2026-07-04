defmodule Nous.Util do
  @moduledoc """
  Small shared helpers used across Nous internals.
  """

  @doc """
  Convert a binary to an already-existing atom, returning `fallback` when no
  such atom exists.

  Never calls `String.to_atom/1`: these values are routinely
  attacker-controllable (persisted state, YAML files, provider responses),
  and minting atoms from them would exhaust the global atom table (atoms are
  not GC'd; node-wide DoS).

  Atoms (including `nil`) pass through unchanged; any other input returns
  `fallback`.

  ## Examples

      iex> Nous.Util.safe_existing_atom("ok")
      :ok

      iex> Nous.Util.safe_existing_atom("no_such_atom_xyz", "no_such_atom_xyz")
      "no_such_atom_xyz"

  """
  @spec safe_existing_atom(term(), term()) :: atom() | term()
  def safe_existing_atom(value, fallback \\ nil)

  def safe_existing_atom(value, _fallback) when is_atom(value), do: value

  def safe_existing_atom(value, fallback) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> fallback
  end

  def safe_existing_atom(_value, fallback), do: fallback

  @doc """
  Split a keyword list into `{gen_opts, init_opts}` for `GenServer.start_link/3`.

  `:name` (when present and non-nil) goes to the GenServer options; everything
  else is passed through as init options.

  ## Examples

      iex> Nous.Util.split_gen_opts(name: MyServer, foo: 1)
      {[name: MyServer], [foo: 1]}

  """
  @spec split_gen_opts(keyword()) :: {keyword(), keyword()}
  def split_gen_opts(opts) when is_list(opts) do
    case Keyword.pop(opts, :name) do
      {nil, rest} -> {[], rest}
      {name, rest} -> {[name: name], rest}
    end
  end

  @doc """
  Convert a map's top-level binary keys to already-existing atoms; keys with
  no existing atom stay binaries (downstream casts simply ignore them).

  Same atom-safety guarantees as `safe_existing_atom/2`.

  ## Examples

      iex> Nous.Util.atomize_keys(%{"name" => "a"})
      %{name: "a"}

  """
  @spec atomize_keys(map()) :: map()
  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_existing_atom(k, k), v}
      {k, v} -> {k, v}
    end)
  end
end
