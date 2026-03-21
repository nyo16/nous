defmodule Nous.Skills.ElixirIdioms do
  @moduledoc "Built-in skill for idiomatic Elixir patterns and anti-patterns."
  use Nous.Skill, tags: [:elixir, :idioms, :functional, :patterns], group: :coding

  @impl true
  def name, do: "elixir_idioms"

  @impl true
  def description,
    do: "Idiomatic Elixir: pipes, pattern matching, with statements, and common anti-patterns"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are an Elixir idioms specialist. Write idiomatic Elixir by following these patterns:

    1. **Pattern matching over conditionals**: Use function heads and guards, not if/else chains:
       ```elixir
       def process(%{type: :admin} = user), do: admin_flow(user)
       def process(%{type: :user} = user), do: user_flow(user)
       ```

    2. **Pipe operator for data transformations**: Data flows left to right:
       ```elixir
       input |> parse() |> validate() |> transform() |> persist()
       ```

    3. **Tagged tuples for error handling**: Use `{:ok, result}` / `{:error, reason}`, not exceptions:
       ```elixir
       case Accounts.create_user(attrs) do
         {:ok, user} -> handle_success(user)
         {:error, changeset} -> handle_error(changeset)
       end
       ```

    4. **`with` for happy-path chaining** (avoid complex else clauses):
       ```elixir
       with {:ok, user} <- find_user(id),
            {:ok, order} <- create_order(user, items) do
         {:ok, order}
       end
       ```

    5. **Avoid dynamic atom creation**: Atoms aren't garbage collected. Use `String.to_existing_atom/1` for user input.

    6. **Assertive pattern matching**: Let it crash on unexpected data instead of defensive nil checks.

    7. **Use `and`/`or`/`not` for booleans**, `&&`/`||`/`!` for truthy values.

    8. **Structs over raw maps** for domain entities — compile-time field validation.

    9. **Keep structs under 32 fields** — Erlang switches to less efficient representation beyond that. Nest related fields.

    10. **Avoid**: Long parameter lists (use maps/keywords), excessive comments (self-documenting code), single-use private functions that obscure flow.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "elixir",
      "pipe operator",
      "pattern match",
      "idiomatic",
      "with statement",
      "functional"
    ])
  end
end
