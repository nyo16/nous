defmodule Mix.Tasks.Nous.Profile.Diff do
  @shortdoc "Shows what a Nous profile changes relative to another"

  @moduledoc """
  Prints the `Nous.Eval.ProfileReport` of profile `B` against profile `A`,
  without evaluation evidence: the components changed, a line diff of each
  with its estimated token delta, and every removed line (the safety review
  section).

      mix nous.profile.diff priv/profiles/support.json candidate.json
      mix nous.profile.diff --store file:priv/eval support_agent@production support_agent#7
      mix nous.profile.diff --agent MyApp.Agents.support - candidate.json

  Each of `A` and `B` is a profile file, or with `--store` a stored
  profile: `sha256:<hex>`, `name@label` or `name#version`. `A` may be `-`:
  no profile, i.e. the agent's base text.

  ## Options

    * `--store SPEC` - `file:DIR`, `sqlite:PATH` or `duckdb:PATH`, for refs
    * `--agent Mod.fun` - a public 0-arity function returning the
      `%Nous.Agent{}`; components a profile does not set are then compared
      against the agent's base text, so text a profile rewrites shows up as
      changed and its removed lines are listed
    * `--format FORMAT` - `console` (default), `markdown` or `json`

  Exits with status 2 on an operational error (bad arguments, unreadable
  profile or store, invalid profile).
  """

  use Mix.Task

  alias Nous.Eval.ProfileReport
  alias Nous.Eval.Profiles.CLI

  @switches [store: :string, agent: :string, format: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.run("nous.profile.diff", fn -> execute(argv) end)
  end

  defp execute(argv) do
    with {:ok, opts, [a, b]} <- CLI.parse(argv, @switches, 2),
         {:ok, format} <- CLI.format(opts[:format], "console"),
         {:ok, store} <- store(opts[:store]),
         {:ok, report_opts} <- agent_opts(opts[:agent]),
         {:ok, base} <- load(a, store, true),
         {:ok, candidate} <- load(b, store, false),
         {:ok, report} <- build(base, candidate, report_opts) do
      Mix.shell().info(ProfileReport.render(report, format: format))
    end
  end

  defp store(nil), do: {:ok, nil}
  defp store(spec), do: CLI.open_store(spec)

  defp agent_opts(nil), do: {:ok, []}

  defp agent_opts(spec) do
    with {:ok, agent} <- CLI.agent(spec), do: {:ok, [agent: agent]}
  end

  defp load("-", _store, true), do: {:ok, nil}

  defp load(arg, store, _base?) do
    case CLI.load(arg, store) do
      {:ok, profile} -> {:ok, profile}
      {:invalid, message} -> {:error, message}
      {:error, message} -> {:error, message}
    end
  end

  defp build(base, candidate, opts) do
    case ProfileReport.build(base, candidate, nil, opts) do
      {:ok, report} -> {:ok, report}
      {:error, reason} -> {:error, CLI.describe(reason)}
    end
  end
end
