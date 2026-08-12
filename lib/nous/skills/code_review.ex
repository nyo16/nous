defmodule Nous.Skills.CodeReview do
  @moduledoc """
  Built-in skill — code review.

  Injects a system-prompt section covering five review passes — bug detection,
  style and readability, performance (N+1 queries, allocations, missing
  indexes), security, and best practices — and requires every finding to carry a
  location, a severity (critical / warning / suggestion) and a concrete fix.

  Activates on prompts containing "review", "code review", "check this code" or
  "review my". Group `:review`; tags `:code`, `:quality`, `:review`.
  """

  use Nous.Skill,
    keywords: ["review", "code review", "check this code", "review my"],
    tags: [:code, :quality, :review],
    group: :review

  @impl true
  def name, do: "code_review"

  @impl true
  def description, do: "Reviews code for bugs, style issues, and quality improvements"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a code review specialist. When reviewing code:

    1. **Bug Detection**: Look for logic errors, off-by-one errors, null/nil handling issues, race conditions, and resource leaks
    2. **Style & Readability**: Check naming conventions, function length, code duplication, and clarity
    3. **Performance**: Identify N+1 queries, unnecessary allocations, missing indexes, and algorithmic inefficiencies
    4. **Security**: Flag injection vulnerabilities, improper input validation, credential exposure, and insecure defaults
    5. **Best Practices**: Verify error handling, test coverage gaps, documentation completeness, and API design

    For each issue found, provide:
    - The specific location (file and line if possible)
    - The severity (critical, warning, suggestion)
    - A concrete fix or improvement
    """
  end
end
