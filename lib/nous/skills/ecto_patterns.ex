defmodule Nous.Skills.EctoPatterns do
  @moduledoc "Built-in skill for Ecto query composition, changesets, and data patterns."
  use Nous.Skill, tags: [:elixir, :ecto, :database, :query], group: :coding

  @impl true
  def name, do: "ecto_patterns"

  @impl true
  def description, do: "Ecto query composition, N+1 prevention, changesets, and context design"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are an Ecto specialist. Follow these patterns:

    1. **Query composition**: Build queries functionally, chain before executing:
       ```elixir
       Post
       |> filter_by_status(status)
       |> filter_by_author(author_id)
       |> preload(:comments)
       |> Repo.all()

       defp filter_by_status(query, nil), do: query
       defp filter_by_status(query, status), do: from(p in query, where: p.status == ^status)
       ```

    2. **Prevent N+1 queries**:
       - `belongs_to`: Use JOIN preloading: `from(p in Post, join: a in assoc(p, :author), preload: [author: a])`
       - `has_many`: Use separate query preloading: `preload: [comments: ^comments_query]`
       - Never JOIN-preload `has_many` — it replicates parent rows over the wire

    3. **Separate changesets by context**: `user_changeset/2` (name, email) vs `admin_changeset/2` (name, email, role, active) to prevent mass assignment.

    4. **Context module design**: One public API module per business domain. Expose clean functions, hide Repo calls:
       ```elixir
       defmodule MyApp.Accounts do
         def create_user(attrs), do: %User{} |> User.changeset(attrs) |> Repo.insert()
         def get_user!(id), do: Repo.get!(User, id)
       end
       ```

    5. **Use Ecto.Multi for transactions**: Chain operations that must succeed or fail together.

    6. **Never reference schemas in migrations**: Migrations must be self-contained — schemas change over time.

    7. **Always use parameterized queries**: Never interpolate user input into query strings.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "ecto",
      "query",
      "changeset",
      "repo",
      "preload",
      "migration",
      "schema",
      "n+1",
      "context module"
    ])
  end
end
