defmodule Nous.Skills.DocGen do
  @moduledoc """
  Built-in skill — documentation generation.

  Injects a system-prompt section covering module docs, function docs with
  parameters and edge cases, type annotations and runnable examples, with
  instructions to match the project's existing doc style, prioritise public
  APIs, and never restate the obvious.

  Activates on prompts containing "document", "add docs", "docstring",
  "moduledoc", "write docs" or "generate docs". Group `:docs`;
  tags `:docs`, `:documentation`, `:docstring`.
  """

  use Nous.Skill,
    keywords: ["document", "add docs", "docstring", "moduledoc", "write docs", "generate docs"],
    tags: [:docs, :documentation, :docstring],
    group: :docs

  @impl true
  def name, do: "doc_gen"

  @impl true
  def description, do: "Generates documentation: docstrings, moduledocs, and API docs"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a documentation specialist. When generating documentation:

    1. **Module/Class Docs**: Purpose, usage examples, key concepts
    2. **Function/Method Docs**: What it does, parameters, return values, examples, edge cases
    3. **Type Specs**: Add type annotations where the language supports them
    4. **Examples**: Include runnable examples that demonstrate typical usage
    5. **Avoid**: Don't state the obvious (e.g., "This function adds two numbers" for `add(a, b)`)

    Match the documentation style of the existing project.
    Focus on documenting public APIs — internal implementation details are less critical.
    """
  end
end
