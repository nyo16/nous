defmodule Mix.Tasks.Nous.Profile.Check do
  @shortdoc "Checks that Nous profiles still apply to an agent (for CI)"

  @moduledoc """
  Loads every given `Nous.Profile` and checks it against the agent with
  `Nous.Profile.validate/2`, the same checks `Nous.new/2` runs at boot.

      mix nous.profile.check --agent MyApp.Agents.support
      mix nous.profile.check --agent MyApp.Agents.support --profile priv/profiles/support.json
      mix nous.profile.check --agent MyApp.Agents.support --store file:priv/eval \\
        --ref support_agent@production

  A profile pins the hash of every base text it replaces, so a changed
  instruction or tool contract makes it `:stale` and the app would refuse
  to boot with it. Run this in CI to find out before deploying; refresh a
  stale profile with `mix nous.profile.rebase`. It also reports profiles
  addressing a tool the agent no longer has (`:unknown_tool`), a parameter
  that no longer exists (`:unknown_param`), and every structural error.

  ## Options

    * `--agent Mod.fun` - a public 0-arity function returning the
      `%Nous.Agent{}` the profiles are for (required)
    * `--profile PATH` - a profile file (`.json`, `.yaml`, `.yml`);
      repeatable. Without `--profile` and `--ref`, every such file in
      `priv/profiles/` is checked
    * `--store SPEC` - `file:DIR`, `sqlite:PATH` or `duckdb:PATH`, for `--ref`
    * `--ref REF` - a stored profile: `sha256:<hex>`, `name@label` or
      `name#version`; repeatable

  ## Exit status

    * `0` - every profile applies
    * `1` - a profile is invalid or does not apply (stale, unknown tool, ...)
    * `2` - an operational error: bad arguments, the agent factory failed,
      an unreadable file or store, a ref that resolves to nothing
  """

  use Mix.Task

  alias Nous.Eval.Profiles.CLI
  alias Nous.Profile

  @switches [agent: :string, profile: :keep, store: :string, ref: :keep]
  @default_glob "priv/profiles/*.{json,yaml,yml}"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.run("nous.profile.check", fn -> execute(argv) end)
  end

  defp execute(argv) do
    with {:ok, opts, []} <- CLI.parse(argv, @switches, 0),
         {:ok, agent} <- CLI.agent(opts[:agent]),
         {:ok, sources} <- sources(opts),
         {:ok, store} <- store(opts) do
      sources
      |> Enum.map(&check(&1, store, agent))
      |> summarize()
    end
  end

  defp sources(opts) do
    paths = Keyword.get_values(opts, :profile)
    refs = Keyword.get_values(opts, :ref)

    with {:ok, refs} <- parse_refs(refs) do
      case {paths, refs} do
        {[], []} ->
          case Path.wildcard(@default_glob) do
            [] -> {:error, "no profiles: give --profile/--ref or add files to priv/profiles/"}
            found -> {:ok, Enum.map(found, &{:path, &1})}
          end

        _ ->
          {:ok, Enum.map(paths, &{:path, &1}) ++ Enum.map(refs, &{:ref, &1})}
      end
    end
  end

  defp parse_refs(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn text, {:ok, acc} ->
      case CLI.parse_ref(text) do
        {:ok, ref} -> {:cont, {:ok, acc ++ [ref]}}
        :error -> {:halt, {:error, "invalid --ref #{inspect(text)}"}}
      end
    end)
  end

  defp store(opts) do
    cond do
      Keyword.has_key?(opts, :store) -> CLI.open_store(opts[:store])
      Keyword.has_key?(opts, :ref) -> {:error, "--ref needs --store"}
      true -> {:ok, nil}
    end
  end

  defp check({:path, path}, _store, agent) do
    case Profile.load(path) do
      {:ok, profile} -> validate(path, profile, agent)
      {:error, %{reason: :file_error} = e} -> {:error, path, CLI.describe(e)}
      {:error, e} -> {:fail, path, CLI.describe(e)}
    end
  end

  defp check({:ref, ref}, store, agent) do
    source = CLI.ref_text(ref)

    case CLI.fetch(store, ref) do
      {:ok, profile} -> validate(source, profile, agent)
      {:invalid, message} -> {:fail, source, message}
      {:error, message} -> {:error, source, message}
    end
  end

  defp validate(source, profile, agent) do
    case Profile.validate(profile, agent) do
      :ok ->
        {:ok, source, profile}

      {:error, %{reason: reason} = e} when reason in [:stale, :missing_manifest] ->
        {:fail, source, CLI.describe(e) <> " (refresh with mix nous.profile.rebase)"}

      {:error, e} ->
        {:fail, source, CLI.describe(e)}
    end
  end

  defp summarize(results) do
    shell = Mix.shell()

    Enum.each(results, fn
      {:ok, source, profile} ->
        shell.info("ok    #{source}  #{label(profile)} #{CLI.short(profile.id)}")

      {:fail, source, message} ->
        shell.info("FAIL  #{source}  #{message}")

      {:error, source, message} ->
        shell.info("ERROR #{source}  #{message}")
    end)

    count = fn tag -> Enum.count(results, &(elem(&1, 0) == tag)) end
    {ok, failed, errors} = {count.(:ok), count.(:fail), count.(:error)}
    summary = "#{ok} ok, #{failed} failed, #{errors} unreadable"

    cond do
      errors > 0 -> {:error, summary}
      failed > 0 -> {:fail, summary}
      true -> shell.info(summary)
    end
  end

  defp label(%Profile{name: nil}), do: "(unnamed)"
  defp label(%Profile{name: name, version: nil}), do: name
  defp label(%Profile{name: name, version: v}), do: "#{name} v#{v}"
end
