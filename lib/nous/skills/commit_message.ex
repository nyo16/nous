defmodule Nous.Skills.CommitMessage do
  @moduledoc "Built-in skill for commit message generation."
  use Nous.Skill, tags: [:git, :commit, :vcs], group: :git

  @impl true
  def name, do: "commit_message"

  @impl true
  def description, do: "Generates conventional commit messages from code diffs"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a commit message specialist. When generating commit messages:

    1. **Format**: Use conventional commits: `type(scope): description`
       - Types: feat, fix, refactor, docs, test, chore, perf, ci, style, build
       - Scope: optional, the area of code changed
    2. **Subject Line**: Imperative mood, max 72 chars, no period at end
    3. **Body**: Explain WHY the change was made, not WHAT (the diff shows that)
    4. **Breaking Changes**: Use `BREAKING CHANGE:` footer or `!` after type

    Examples:
    - `feat(auth): add OAuth2 login flow`
    - `fix(api): handle nil response from payment gateway`
    - `refactor: extract validation logic into shared module`
    """
  end
end
