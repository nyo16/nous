defmodule Mix.Tasks.Nous.Profile.Promote do
  @shortdoc "Points a Nous profile label (e.g. production) at a stored profile"

  @moduledoc """
  Points label `LABEL` of profile name `NAME` at a profile, by appending an
  entry to the label's history in the eval store
  (`c:Nous.Eval.Store.put_profile_label/4`).

      mix nous.profile.promote --store file:priv/eval support_agent production 7
      mix nous.profile.promote --store file:priv/eval support_agent production sha256:9f2c…
      mix nous.profile.promote --store file:priv/eval support_agent staging support_agent@production
      mix nous.profile.promote --store file:priv/eval support_agent production priv/profiles/support.json

  `REF` is a version number under `NAME`, `sha256:<hex>`, `name@label`,
  `name#version`, or a profile file, which is stored first (under `NAME`;
  storing is idempotent, so a file already stored keeps its version). The
  profile must be stored under `NAME`.

  Promotion is the human step after reading the profile's
  `Nous.Eval.ProfileReport` (`mix nous.profile.diff`): nothing promotes a
  profile automatically. Labels are append-only, so a rollback is another
  promotion and the history is kept. Apps resolve a label with
  `Nous.Eval.Profiles.fetch/2`; for production, prefer exporting the
  promoted profile to a reviewed file loaded with `Nous.Profile.load!/1`.

  ## Options

    * `--store SPEC` - `file:DIR`, `sqlite:PATH` or `duckdb:PATH` (required)

  Exits with status 2 on an operational error (bad arguments, unknown
  profile, invalid name or label, store failure).
  """

  use Mix.Task

  alias Nous.Eval.Profiles.CLI
  alias Nous.Eval.Store
  alias Nous.Profile

  @switches [store: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.run("nous.profile.promote", fn -> execute(argv) end)
  end

  defp execute(argv) do
    with {:ok, opts, [name, label, ref]} <- CLI.parse(argv, @switches, 3),
         :ok <- check(Store.validate_profile_name(name)),
         :ok <- check(Store.validate_label(label)),
         {:ok, {module, state}} <- CLI.open_store(opts[:store]),
         :ok <- supported(module),
         {:ok, profile, state} <- resolve(module, state, name, ref),
         :ok <- same_name(profile, name),
         {:ok, history} <- history(module, state, name, label),
         {:ok, _state} <- put_label(module, state, name, label, profile.id) do
      Mix.shell().info(
        "#{name}@#{label} -> #{profile.id} (#{name} v#{profile.version})" <>
          previous(history)
      )
    end
  end

  defp check(:ok), do: :ok
  defp check({:error, reason}), do: {:error, CLI.describe(reason)}

  defp supported(module) do
    if function_exported?(module, :put_profile_label, 4),
      do: :ok,
      else: {:error, CLI.describe({:unsupported, module})}
  end

  defp resolve(module, state, name, ref) do
    cond do
      File.regular?(ref) ->
        put_file(module, state, name, ref)

      match?({_, ""}, Integer.parse(ref)) ->
        {version, ""} = Integer.parse(ref)
        fetch(module, state, {:version, name, version})

      true ->
        case CLI.parse_ref(ref) do
          {:ok, parsed} -> fetch(module, state, parsed)
          :error -> {:error, "#{ref}: not a version, ref or profile file"}
        end
    end
  end

  defp fetch(module, state, ref) do
    case CLI.fetch({module, state}, ref) do
      {:ok, profile} -> {:ok, profile, state}
      {:invalid, message} -> {:error, message}
      {:error, message} -> {:error, message}
    end
  end

  defp put_file(module, state, name, path) do
    with {:ok, profile} <- load_file(path),
         :ok <- same_name(profile, name) do
      case module.put_profile(state, %{profile | name: name}) do
        {:ok, stored, state} -> {:ok, stored, state}
        {:error, reason} -> {:error, "cannot store #{path}: #{CLI.describe(reason)}"}
      end
    end
  end

  defp load_file(path) do
    case Profile.load(path) do
      {:ok, profile} -> {:ok, profile}
      {:error, e} -> {:error, "#{path}: #{CLI.describe(e)}"}
    end
  end

  defp same_name(%Profile{name: nil}, _name), do: :ok
  defp same_name(%Profile{name: name}, name), do: :ok

  defp same_name(%Profile{name: other}, name),
    do: {:error, "the profile is named #{inspect(other)}, not #{inspect(name)}"}

  defp history(module, state, name, label) do
    case module.list_profile_labels(state, name, label) do
      {:ok, history} -> {:ok, history}
      {:error, reason} -> {:error, CLI.describe(reason)}
    end
  end

  defp put_label(module, state, name, label, id) do
    case module.put_profile_label(state, name, label, id) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, "cannot set #{name}@#{label}: #{CLI.describe(reason)}"}
    end
  end

  defp previous([]), do: " (new label)"
  defp previous([latest | _]), do: "; previously #{latest.profile_id}"
end
