defmodule Mix.Tasks.Nous.Optimize do
  @shortdoc "Optimizes an agent's instructions and tool descriptions into a Nous.Profile"

  @moduledoc """
  Runs `Nous.Eval.Optimizer` on an eval task and prints the profile report.

      mix nous.optimize --task MyApp.Evals.Support --reflector openai:gpt-4o \\
        --budget-cost 5 --components instructions,tool:search_orders \\
        --store file:.nous/eval --name support_agent --out priv/profiles/candidate.json

  The task's cases need train, val and test splits (see `Nous.Eval.Dataset`).
  The search uses train (reflection) and val (selection); test decides once
  whether the best candidate is accepted. Nothing is deployed: an accepted
  profile is written to `--out` and, with `--store`, stored under `--name`;
  promote it with `mix nous.profile.promote`.

  ## Options

    * `--task MODULE` - the eval task (`use Nous.Eval`) (required)
    * `--reflector MODEL` - the model that proposes new text (required)
    * `--strategy gepa|opro` - default `gepa`
    * `--components KEYS` - comma-separated component keys (default: the
      instructions and every app tool description)
    * `--budget-cost USD`, `--budget-tokens N`, `--budget-calls N` - the
      optimization budget; at least one is required (`--budget-calls` caps
      samples run)
    * `--max-steps N` - search steps (default 20)
    * `--k N` - samples per case (default 3)
    * `--seed N` - default 0
    * `--feedback diagnostic|with_expected` - what the reflector sees
      (default `diagnostic`; `with_expected` adds train cases' expected
      values and is recorded in the profile's provenance)
    * `--store SPEC` - `file:DIR`, `sqlite:PATH` or `duckdb:PATH`, to store
      an accepted profile
    * `--name NAME` - the profile name
    * `--out PATH` - write the accepted profile (canonical JSON)
    * `--format console|markdown` - the report format (default `console`)

  ## Exit status

    * `0` - a profile was accepted
    * `1` - the optimization ran and no profile was accepted
    * `2` - an operational error: bad arguments, an unknown task or model
      price, a budget too small for the seed evaluations, a failed write
  """

  use Mix.Task

  alias Nous.Eval.{CLI, ProfileReport}
  alias Nous.Eval.Optimizer
  alias Nous.Eval.Optimizer.Result

  @switches [
    task: :string,
    reflector: :string,
    strategy: :string,
    components: :string,
    budget_cost: :float,
    budget_tokens: :integer,
    budget_calls: :integer,
    max_steps: :integer,
    k: :integer,
    seed: :integer,
    feedback: :string,
    store: :string,
    name: :string,
    out: :string,
    format: :string
  ]

  @strategies %{"gepa" => :gepa, "opro" => :opro}
  @feedback %{"diagnostic" => :diagnostic, "with_expected" => :with_expected}
  @formats %{"console" => :console, "markdown" => :markdown}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.finish("nous.optimize", execute(argv))
  end

  defp execute(argv) do
    with {:ok, opts, []} <- CLI.parse(argv, @switches),
         {:ok, task} <- CLI.task_module(opts[:task]),
         {:ok, reflector} <- required(opts[:reflector], "--reflector MODEL"),
         {:ok, strategy} <- pick(@strategies, opts[:strategy] || "gepa", "--strategy"),
         {:ok, feedback} <- pick(@feedback, opts[:feedback] || "diagnostic", "--feedback"),
         {:ok, format} <- pick(@formats, opts[:format] || "console", "--format"),
         {:ok, budget} <- budget(opts),
         {:ok, store} <- store(opts[:store]) do
      optimizer_opts =
        [
          reflector: reflector,
          strategy: strategy,
          feedback: feedback,
          budget: budget,
          components: components(opts[:components]),
          max_steps: opts[:max_steps],
          k: opts[:k],
          seed: opts[:seed],
          store: store,
          name: opts[:name]
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Optimizer.run(task, optimizer_opts) do
        {:ok, %Result{} = result} -> finish(result, format, opts[:out])
        {:error, reason} -> {:error, describe(reason)}
      end
    else
      {:ok, _opts, args} -> {:error, "unexpected arguments #{inspect(args)}"}
      {:error, message} -> {:error, message}
    end
  end

  defp finish(result, format, out) do
    shell = Mix.shell()

    if result.report, do: shell.info(ProfileReport.render(result.report, format: format))

    shell.info("Verdict: #{result.verdict}")
    Enum.each(result.reasons, &shell.info("  - " <> &1))

    shell.info(
      "Steps: #{result.steps} (#{inspect(result.stop_reason)}), " <>
        "candidates: #{length(result.candidates)}, rejected proposals: #{length(result.rejections)}"
    )

    with :ok <- write(result, out) do
      {:ok, if(result.verdict == :accepted, do: 0, else: 1)}
    end
  end

  defp write(%Result{verdict: :accepted, profile: profile}, path) when is_binary(path) do
    case File.write(path, Nous.Profile.encode(profile)) do
      :ok ->
        Mix.shell().info("Profile written to #{path}")
        :ok

      {:error, reason} ->
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp write(_result, _path), do: :ok

  defp required(nil, what), do: {:error, "missing #{what}"}
  defp required(value, _what), do: {:ok, value}

  defp pick(table, value, flag) do
    case Map.fetch(table, value) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         "invalid #{flag} #{inspect(value)}: expected one of #{Enum.join(Map.keys(table), ", ")}"}
    end
  end

  defp budget(opts) do
    case [
           max_cost: opts[:budget_cost],
           max_tokens: opts[:budget_tokens],
           max_metric_calls: opts[:budget_calls]
         ]
         |> Enum.reject(fn {_key, value} -> is_nil(value) end) do
      [] -> {:error, "a budget is required: --budget-cost, --budget-tokens or --budget-calls"}
      budget -> {:ok, budget}
    end
  end

  defp store(nil), do: {:ok, nil}
  defp store(spec), do: CLI.store_spec(spec)

  defp components(nil), do: nil

  defp components(text) do
    case text
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      keys -> keys
    end
  end

  defp describe({:budget_too_small, details}),
    do: "the budget cannot cover the seed's evaluations: #{inspect(details)}"

  defp describe({:missing_split, split}),
    do: "the task has no #{split} cases (every case needs a split)"

  defp describe({:unknown_components, keys}), do: "unknown components #{Enum.join(keys, ", ")}"
  defp describe(:no_components), do: "the agent has no text a profile can change"
  defp describe(reason), do: CLI.describe(reason)
end
