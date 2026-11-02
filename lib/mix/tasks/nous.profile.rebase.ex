defmodule Mix.Tasks.Nous.Profile.Rebase do
  @shortdoc "Re-pins a stale Nous profile to an agent's current base text"

  @moduledoc """
  Refreshes a profile whose base text changed (`:stale` in
  `mix nous.profile.check`): when every component still has a target in the
  current agent, re-seals the manifest against the current base text and
  writes a child profile whose `parent_id` is the old profile's id.

      mix nous.profile.rebase --agent MyApp.Agents.support priv/profiles/support.json

  The task prints which bases changed, with the current base text of each
  affected component, so a reviewer can judge whether the profile's text
  still fits. Rebasing keeps the profile's text exactly: it only accepts the
  new base. The evaluation evidence behind the old profile was measured
  against the old base, so re-run the eval before promoting the child.

  A profile is refused (exit 1), and nothing is written, when a component's
  target is gone (`:unknown_tool`, `:unknown_param`, `:ambiguous_tool`,
  `:builtin_tool`, `:dynamic_instructions`) or the profile is otherwise
  invalid: such a profile needs a human edit, not a re-pin. A profile that
  already applies is left alone.

  ## Options

    * `--agent Mod.fun` - a public 0-arity function returning the current
      `%Nous.Agent{}` (required)
    * `--out PATH` - where to write the child (default: `PROFILE` with a
      `.json` extension, so a `.json` input is rewritten in place)

  ## Exit status

    * `0` - rebased and written, or already current
    * `1` - the profile cannot be rebased
    * `2` - an operational error: bad arguments, the agent factory failed,
      an unreadable or unwritable file
  """

  use Mix.Task

  alias Nous.Eval.Profiles.CLI
  alias Nous.Profile

  @switches [agent: :string, out: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.run("nous.profile.rebase", fn -> execute(argv) end)
  end

  defp execute(argv) do
    with {:ok, opts, [path]} <- CLI.parse(argv, @switches, 1),
         {:ok, agent} <- CLI.agent(opts[:agent]),
         {:ok, profile} <- load(path) do
      case Profile.validate(profile, agent) do
        :ok ->
          Mix.shell().info("#{path} already applies (#{profile.id}); nothing to rebase")

        {:error, %{reason: reason}} when reason in [:stale, :missing_manifest] ->
          rebase(profile, agent, opts[:out] || CLI.default_out(path))

        {:error, e} ->
          {:fail, "cannot rebase #{path}: " <> CLI.describe(e)}
      end
    end
  end

  defp load(path) do
    case CLI.load(path, nil) do
      {:ok, profile} -> {:ok, profile}
      {:invalid, message} -> {:fail, message}
      {:error, message} -> {:error, message}
    end
  end

  defp rebase(profile, agent, out) do
    case Profile.seal(profile, agent) do
      {:ok, sealed} ->
        child = %{sealed | parent_id: profile.id, version: nil}
        report_changes(profile, child, agent)

        with :ok <- CLI.write(out, child) do
          Mix.shell().info("rebased #{profile.id} -> #{child.id} (parent recorded) -> #{out}")
        end

      {:error, e} ->
        {:fail, "cannot rebase: " <> CLI.describe(e)}
    end
  end

  # Only hashes of the old bases are known, so the old text cannot be
  # shown; the current base text of every component under a changed base
  # is.
  defp report_changes(old, new, agent) do
    {:ok, base_agent} = Profile.apply(nil, agent)
    base_text = Profile.components(base_agent)
    shell = Mix.shell()

    for {base, hash} <- Enum.sort(new.manifest), Map.get(old.manifest, base) != hash do
      previous = Map.get(old.manifest, base, "no manifest entry")
      shell.info("base changed: #{base}  #{CLI.short(previous)} -> #{CLI.short(hash)}")

      for key <- old.components |> Map.keys() |> Enum.sort(), base_of(key) == base do
        shell.info("  current base of #{key}:")

        base_text
        |> Map.get(key, "(none)")
        |> String.split("\n")
        |> Enum.each(&shell.info("    | " <> printable(&1)))
      end
    end

    :ok
  end

  defp base_of("instructions"), do: "instructions"
  defp base_of("tool:" <> rest), do: "tool:" <> (rest |> String.split("#", parts: 2) |> hd())

  defp printable(line), do: String.replace(line, ~r/[\x{00}-\x{1f}\x{7f}-\x{9f}]/u, "?")
end
