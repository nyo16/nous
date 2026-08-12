defmodule Nous.Docs.ApiReferenceTest do
  @moduledoc """
  Regression guard against semantic documentation drift.

  `mix docs` and `mix compile` both pass on documentation that names functions
  which no longer exist: nothing in the toolchain reads `examples/` or the
  ```elixir fences in the guides. That is how a release ships `result.usage`
  fields, `AgentServer.subscribe/1` calls and `generate_output/2` snippets that
  raise the moment a reader runs them.

  This test closes that hole statically. It does not evaluate any snippet — it
  parses them and resolves every `Nous.*` remote call and struct literal against
  the loaded beam.
  """
  use ExUnit.Case, async: true

  alias Nous.DocSnippets

  @allowlist_path Path.join(__DIR__, "fixtures/doc_snippet_allowlist.exs")
  @external_resource @allowlist_path

  setup_all do
    {allowlist, _} = Code.eval_file(@allowlist_path)
    %{allowlist: MapSet.new(allowlist, fn {file, line, _reason} -> {file, line} end)}
  end

  test "every documented snippet parses, or is allowlisted with a reason", %{
    allowlist: allowlist
  } do
    failures =
      for snippet <- DocSnippets.snippets(),
          {:parse_error, message} <- [DocSnippets.check(snippet)],
          not MapSet.member?(allowlist, {snippet.file, snippet.line}) do
        %{file: snippet.file, line: snippet.line, message: message}
      end

    assert failures == [],
           DocSnippets.format(
             "Documentation snippets that do not parse and are not allowlisted",
             failures
           )
  end

  test "every Nous.* symbol used in docs and examples exists", %{allowlist: allowlist} do
    issues =
      for snippet <- DocSnippets.snippets(),
          not MapSet.member?(allowlist, {snippet.file, snippet.line}),
          {:ok, snippet_issues} <- [DocSnippets.check(snippet)],
          issue <- snippet_issues do
        issue
      end

    assert issues == [],
           DocSnippets.format("Unresolved Nous.* symbols in documentation", issues)
  end

  test "every relative markdown link and anchor resolves" do
    issues = Enum.flat_map(DocSnippets.markdown_files(), &DocSnippets.link_issues/1)

    assert issues == [], DocSnippets.format("Broken markdown links", issues)
  end

  test "the allowlist has no stale entries" do
    {allowlist, _} = Code.eval_file(@allowlist_path)

    parse_failures =
      for snippet <- DocSnippets.snippets(),
          {:parse_error, _} <- [DocSnippets.check(snippet)],
          into: MapSet.new(),
          do: {snippet.file, snippet.line}

    stale =
      for {file, line, reason} <- allowlist,
          not MapSet.member?(parse_failures, {file, line}),
          do: %{file: file, line: line, message: "allowlisted but parses fine — #{reason}"}

    assert stale == [],
           DocSnippets.format("Stale doc_snippet_allowlist.exs entries", stale)
  end
end
