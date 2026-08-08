defmodule Nous.DocumentedTestTools do
  @moduledoc """
  Tool functions with and without `@doc`, for `Nous.Tool.from_function/2`.

  Lives in `test/support` rather than inside a test file on purpose: `mix`
  compiles this path to a real beam carrying a docs chunk, while ExUnit compiles
  test modules in memory, where `Code.fetch_docs/1` returns
  `{:error, :module_not_found}` and doc extraction cannot be observed at all.
  """

  @doc """
  Look up a customer record by email address.
  """
  def documented(_ctx, _args), do: {:ok, "found"}

  def undocumented(_ctx, _args), do: {:ok, "found"}
end
