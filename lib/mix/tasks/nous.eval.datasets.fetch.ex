defmodule Mix.Tasks.Nous.Eval.Datasets.Fetch do
  @shortdoc "Fetches a registered guard dataset, verified and converted to nous.guard_case/1"

  @moduledoc """
  Downloads a guard dataset from the compiled-in registry
  (`Nous.Eval.Guard.Registry`), verifies its sha256 before parsing, converts
  it to `nous.guard_case/1` JSONL with provenance, deduplicates, groups and
  splits it, and writes it with a manifest and a NOTICE
  (`Nous.Eval.Guard.Fetch`).

      mix nous.eval.datasets.fetch --list
      mix nous.eval.datasets.fetch paul-rottger/xstest --sample 100 --seed s1 --out priv/eval/guard/xstest
      mix nous.eval.datasets.fetch nous_builtin
      mix nous.eval.datasets.fetch ai-safety-institute/AgentHarm --accept-terms ai-safety-institute/AgentHarm

  Only the registry's pinned URLs are requested. Sources with a
  non-commercial, copyleft or missing licence are refused; use-restricted
  ones need `--accept-terms SOURCE`, which is recorded in the manifest.
  Parquet sources need the optional `:duckdbex` dependency.

  ## Options

    * `--list` - print the registry (id, licence, status, surfaces) and exit
    * `--accept-terms SOURCE` - accept a use-restricted source's terms
      (repeatable)
    * `--sample N` - keep N cases, a deterministic proportional sample per
      surface and label
    * `--seed S` - sample and split seed (default `nous-guard-v1`)
    * `--out DIR` - output directory (default
      `<user cache>/nous/eval/datasets/<source>@<revision>`)
    * `--hf-token-env VAR` - environment variable holding a Hugging Face
      token for gated sources (default `HF_TOKEN`)

  Exit status: 0 on success, 2 on any error.
  """

  use Mix.Task

  alias Nous.Eval.Guard.{Fetch, Registry}

  @switches [
    list: :boolean,
    accept_terms: :keep,
    sample: :integer,
    seed: :string,
    out: :string,
    hf_token_env: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    case execute(argv) do
      :ok ->
        :ok

      {:error, message} ->
        Mix.shell().error("mix nous.eval.datasets.fetch: " <> message)
        exit({:shutdown, 2})
    end
  end

  defp execute(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        if opts[:list], do: list(), else: {:error, "expected a SOURCE (see --list)"}

      {opts, [source], []} ->
        fetch(source, opts)

      {_opts, [_, extra | _], []} ->
        {:error, "unexpected argument #{inspect(extra)}"}

      {_opts, _args, [{switch, _} | _]} ->
        {:error, "invalid option #{switch}"}
    end
  end

  defp list do
    for s <- Registry.sources() do
      Mix.shell().info(
        "#{String.pad_trailing(s.id, 40)} #{String.pad_trailing(Atom.to_string(s.status), 8)} " <>
          "#{String.pad_trailing(s.license, 32)} #{Enum.map_join(s.surfaces, ",", &Atom.to_string/1)}"
      )
    end

    :ok
  end

  defp fetch(source, opts) do
    fetch_opts =
      [accept_terms: Keyword.get_values(opts, :accept_terms)]
      |> put(:sample, opts[:sample])
      |> put(:seed, opts[:seed])
      |> put(:out, opts[:out])
      |> put(:hf_token_env, opts[:hf_token_env])

    with {:ok, result} <- Fetch.run(source, fetch_opts) do
      Mix.shell().info("#{result.source}: #{result.cases} cases written to #{result.out}")

      if result.pii_findings > 0,
        do:
          Mix.shell().info(
            "warning: #{result.pii_findings} PII-shaped strings found; review before committing " <>
              "(Nous.Eval.Guard.Dataset.validate(ds, pii: true))"
          )

      :ok
    end
  end

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end
