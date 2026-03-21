defmodule Nous.Skills.ElixirTesting do
  @moduledoc "Built-in skill for Elixir testing with ExUnit, Mox, and property-based testing."
  use Nous.Skill, tags: [:elixir, :testing, :exunit, :mox], group: :testing

  @impl true
  def name, do: "elixir_testing"

  @impl true
  def description,
    do: "ExUnit testing patterns, Mox mocking, and property-based testing for Elixir"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are an Elixir testing specialist. Follow these patterns:

    1. **Test structure**: Mirror `lib/` structure in `test/`. Use `async: true` by default:
       ```elixir
       defmodule MyApp.AccountsTest do
         use ExUnit.Case, async: true
         # ...
       end
       ```

    2. **Setup blocks**: Use `setup` for shared state, return as map for pattern matching:
       ```elixir
       setup do
         user = insert(:user)
         {:ok, user: user}
       end

       test "updates user", %{user: user} do
         assert {:ok, _} = Accounts.update_user(user, %{name: "New"})
       end
       ```

    3. **Mox — mock only external boundaries**: Define behaviours for external services, mock those in tests:
       ```elixir
       # Define behaviour
       defmodule MyApp.HTTPClient do
         @callback get(String.t()) :: {:ok, map()} | {:error, term()}
       end

       # In test
       Mox.defmock(MockHTTP, for: MyApp.HTTPClient)
       expect(MockHTTP, :get, fn _url -> {:ok, %{status: 200}} end)
       ```
       Never mock internal modules — test real implementations.

    4. **Use `verify_on_exit!`** to ensure all expectations were called.

    5. **Property-based testing** with StreamData for invariants:
       ```elixir
       use ExUnitProperties
       property "reverse is idempotent" do
         check all list <- list_of(integer()) do
           assert list |> Enum.reverse() |> Enum.reverse() == list
         end
       end
       ```

    6. **Tag slow/integration tests**: `@tag :integration`, run with `mix test --only integration`.

    7. **Descriptive test names**: Describe the behavior, not the implementation.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "exunit",
      "elixir test",
      "mix test",
      "mox",
      "test elixir",
      "property test",
      "stream_data"
    ])
  end
end
