# Documentation snippets that are deliberately NOT valid standalone Elixir.
#
# Every entry is `{file, line, reason}` where `line` is the line of the opening
# ```elixir fence. `test/docs/api_reference_test.exs` fails on any fence that
# does not parse and is not listed here, so a new entry is a conscious decision
# that someone else can audit — and the same test fails on an entry that has
# started parsing, so the list cannot silently rot either.
#
# Legitimate reasons are narrow:
#   * a builder fragment shown mid-pipeline, starting with `|>`
#   * a `dep`/keyword tuple shown bare, outside its enclosing list
#   * an option value shown on its own to contrast right and wrong forms
#
# "It is easier than fixing the snippet" is NOT a reason. If a reader is meant
# to paste it, it has to parse.
[
  {"docs/guides/custom_providers.md", 278,
   "bare `base_url:` option values contrasting correct vs missing /v1"},
  {"docs/guides/hooks.md", 125, "bare `matcher:` option values, one per matching mode"},
  {"docs/guides/observability.md", 351, "bare mix.exs dep tuples, shown outside the deps list"},
  {"docs/guides/research.md", 128,
   "bare `search_tool:` option value, shown outside its opts list"},
  {"docs/guides/workflows.md", 62, "leading-`|>` Workflow builder fragment"},
  {"docs/guides/workflows.md", 96, "leading-`|>` Workflow builder fragment"},
  {"docs/guides/workflows.md", 109, "leading-`|>` Workflow builder fragment"},
  {"docs/guides/workflows.md", 142, "leading-`|>` Workflow builder fragment"},
  {"docs/guides/workflows.md", 188, "leading-`|>` Workflow builder fragment"}
]
