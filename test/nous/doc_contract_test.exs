defmodule Nous.DocContractTest do
  use ExUnit.Case, async: true

  # AGENTS.md states the public-API rule mechanically: "if a module carries a
  # @moduledoc and appears in hexdocs.pm/nous, it is public and covered by
  # semver." ExDoc publishes every compiled module that is not `@moduledoc
  # false`, so the source and `mix.exs`'s `groups_for_modules` must agree in
  # both directions:
  #
  #   * a hidden module listed in a group is an entry ExDoc silently drops;
  #   * a documented module in no group lands in hexdocs' ungrouped "Modules"
  #     bucket and becomes semver-covered by accident, which is exactly what
  #     the 2026-06 and 2026-08 audits both found (arch F-9).
  #
  # Two consecutive audits rediscovered the same drift because nothing
  # enforced it. This test is that enforcement.

  @groups Mix.Project.config()[:docs][:groups_for_modules]

  # Every module ExDoc will consider, i.e. those compiled from `lib/`.
  # `elixirc_paths(:test)` also compiles `test/support`, whose modules land in
  # the same `.app` module list but are never published; filtering on the
  # compile-time source path excludes them without an allowlist that can rot.
  defp library_modules do
    {:ok, modules} = :application.get_key(:nous, :modules)
    lib_root = Path.join(File.cwd!(), "lib") <> "/"

    Enum.filter(modules, fn module ->
      Code.ensure_loaded?(module) and
        case module.module_info(:compile)[:source] do
          nil -> false
          source -> String.starts_with?(List.to_string(source), lib_root)
        end
    end)
  end

  defp moduledoc_visibility(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, :hidden, _, _} -> :hidden
      {:docs_v1, _, _, _, :none, _, _} -> :none
      {:docs_v1, _, _, _, %{}, _, _} -> :documented
      {:error, reason} -> {:error, reason}
    end
  end

  defp by_visibility do
    Enum.group_by(library_modules(), &moduledoc_visibility/1)
  end

  defp group_entries do
    for {group, modules} <- @groups, module <- modules, do: {module, group}
  end

  defp grouped_modules, do: Enum.map(group_entries(), &elem(&1, 0))

  test "every module compiled from lib/ exposes a docs chunk" do
    # Guards the two contract tests below: if `Code.fetch_docs/1` starts
    # erroring, every module silently classifies as neither hidden nor
    # documented and both assertions pass vacuously.
    unreadable =
      by_visibility()
      |> Enum.filter(&match?({{:error, _}, _}, &1))
      |> Enum.flat_map(fn {{:error, reason}, modules} -> Enum.map(modules, &{&1, reason}) end)

    assert unreadable == [],
           "Code.fetch_docs/1 could not read these modules: " <> inspect(unreadable)
  end

  test "the documented set is non-degenerate" do
    # The source-path filter in library_modules/0 is the one way this whole
    # file can go quiet: if it stops matching (renamed checkout, stripped
    # compile info), it returns [] and every contract assertion holds
    # trivially. 150 is a floor, not a ratchet - the real figure is >220.
    documented = Map.get(by_visibility(), :documented, [])

    assert length(documented) > 150,
           "only #{length(documented)} documented lib modules found - " <>
             "library_modules/0 is probably no longer resolving source paths"
  end

  test "no `@moduledoc false` module appears in a doc group" do
    hidden = Map.get(by_visibility(), :hidden, [])
    grouped = MapSet.new(grouped_modules())

    leaked = Enum.filter(hidden, &MapSet.member?(grouped, &1))

    assert leaked == [],
           "these modules are `@moduledoc false` but listed in " <>
             "mix.exs groups_for_modules; ExDoc will drop the entry: " <>
             inspect(leaked)
  end

  test "every documented module appears in exactly one doc group" do
    documented = Map.get(by_visibility(), :documented, [])
    grouped = MapSet.new(grouped_modules())

    ungrouped = documented |> Enum.reject(&MapSet.member?(grouped, &1)) |> Enum.sort()

    assert ungrouped == [],
           "these modules carry a @moduledoc but no doc group, so they are " <>
             "published to hexdocs and semver-covered by accident. Either add " <>
             "each to a groups_for_modules entry or mark it `@moduledoc false`: " <>
             inspect(ungrouped)

    duplicated =
      group_entries()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_module, groups} -> length(groups) > 1 end)
      |> Enum.sort()

    assert duplicated == [],
           "these modules are listed in more than one doc group: " <> inspect(duplicated)
  end

  test "every doc group entry names a module that exists" do
    # Catches the other half of arch F-7: moving or renaming a module without
    # updating mix.exs leaves a group entry ExDoc cannot resolve.
    existing = MapSet.new(library_modules())

    missing = grouped_modules() |> Enum.reject(&MapSet.member?(existing, &1)) |> Enum.sort()

    assert missing == [],
           "mix.exs groups_for_modules names modules that are not compiled " <>
             "from lib/: " <> inspect(missing)
  end
end
