defmodule Nous.Skills.CodeReview do
  @moduledoc "Built-in skill for code review."
  use Nous.Skill, tags: [:code, :quality, :review], group: :review

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

  @impl true
  def match?(input) do
    input = String.downcase(input)
    String.contains?(input, ["review", "code review", "check this code", "review my"])
  end
end
