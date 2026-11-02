defmodule Mix.Tasks.Nous.Profile.Seal do
  @shortdoc "Pins a hand-written Nous profile to an agent's base text"

  @moduledoc """
  Fills a hand-written profile's manifest and id with
  `Nous.Profile.seal/2`, and writes the result as canonical JSON.

      mix nous.profile.seal --agent MyApp.Agents.support priv/profiles/support.yaml
      #=> writes priv/profiles/support.json

  A profile file may be written without `id` and `manifest`. Sealing hashes
  the agent's base text that each component replaces, so from then on any
  change to that base makes the profile `:stale` (see
  `mix nous.profile.check`). Every other check of `Nous.Profile.validate/2`
  runs first: a component addressing a tool or parameter the agent does not
  have is refused.

  To refresh an already sealed profile after its base changed, use
  `mix nous.profile.rebase`, which records the old profile as the parent.

  ## Options

    * `--agent Mod.fun` - a public 0-arity function returning the
      `%Nous.Agent{}` the profile is for (required)
    * `--out PATH` - where to write (default: `PATH` with a `.json`
      extension, so a `.json` input is rewritten in place)

  ## Exit status

    * `0` - sealed and written
    * `1` - the profile is invalid or does not apply to the agent
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
    CLI.run("nous.profile.seal", fn -> execute(argv) end)
  end

  defp execute(argv) do
    with {:ok, opts, [path]} <- CLI.parse(argv, @switches, 1),
         {:ok, agent} <- CLI.agent(opts[:agent]),
         {:ok, profile} <- load(path),
         {:ok, sealed} <- seal(profile, agent),
         out = opts[:out] || CLI.default_out(path),
         :ok <- CLI.write(out, sealed) do
      if profile.manifest != %{} and profile.manifest != sealed.manifest do
        Mix.shell().info(
          "note: the manifest changed; the profile's base text moved since it was sealed " <>
            "(mix nous.profile.rebase records the old profile as the parent)"
        )
      end

      Mix.shell().info("sealed #{sealed.id} -> #{out}")
    end
  end

  defp load(path) do
    case CLI.load(path, nil) do
      {:ok, profile} -> {:ok, profile}
      {:invalid, message} -> {:fail, message}
      {:error, message} -> {:error, message}
    end
  end

  defp seal(profile, agent) do
    case Profile.seal(profile, agent) do
      {:ok, sealed} -> {:ok, sealed}
      {:error, e} -> {:fail, "cannot seal: " <> CLI.describe(e)}
    end
  end
end
