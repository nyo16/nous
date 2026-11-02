defmodule Mix.Tasks.Nous.Eval.Promote do
  @shortdoc "Promotes stored online-eval samples into a dataset file, or labels a promoted guard case"

  @moduledoc """
  Promotes samples captured by `Nous.Eval.Online` into a JSONL dataset
  (`Nous.Eval.promote/3`), re-applying a redactor first.

      mix nous.eval.promote --store file:/var/lib/myapp/nous-online \\
        --ids 4bf92f3577b34da6a3ce929d0e0e4736,0af7651916cd43dd8448eb211c80319c \\
        --to test/eval/datasets/support.jsonl --redactor MyApp.TraceRedactor \\
        --reviewer alice

      mix nous.eval.promote --store file:/var/lib/myapp/nous-online --ids-file ids.txt \\
        --to guards/online.jsonl --as guard_case:user_input --redactor MyApp.TraceRedactor

  Promoted guard cases enter with `"label": null`. Label one after review
  (`Nous.Eval.Online.Review.label/5`):

      mix nous.eval.promote --to guards/online.jsonl --label online-4bf9...-user_input=block \\
        --reviewer alice

  ## Options

    * `--store SPEC` - `file:DIR` (default `file:.nous/eval`), `sqlite:PATH`
      or `duckdb:PATH`: the online instance's store
    * `--ids ID,ID` / `--ids-file PATH` - trace ids to promote (one per line
      in the file)
    * `--to PATH` - the dataset file (required)
    * `--as case | guard_case:SURFACE` - what to write (default `case`);
      `SURFACE` is `user_input`, `tool_call`, `tool_result` or
      `model_output`
    * `--redactor MODULE` - a loaded module implementing
      `Nous.Eval.Online.Redactor` (required to promote). The name must
      refer to an existing module; it is never turned into a new atom
    * `--reviewer NAME` - recorded in the provenance (required with
      `--label`)
    * `--instance NAME` - the online instance (default `default`)
    * `--label ID=block|allow` - label a promoted guard case instead of
      promoting

  ## Exit status

  0 on success (skipped samples are listed, not errors), 2 on an
  operational error.
  """

  use Mix.Task

  alias Nous.Eval.CLI
  alias Nous.Eval.Online.Review

  @switches [
    store: :string,
    ids: :string,
    ids_file: :string,
    to: :string,
    as: :string,
    redactor: :string,
    reviewer: :string,
    instance: :string,
    label: :string
  ]

  @surfaces ["user_input", "tool_call", "tool_result", "model_output"]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.finish("nous.eval.promote", execute(argv))
  end

  @doc false
  # The task without the exit, for tests: `{:ok, 0} | {:error, message}`.
  @spec execute([String.t()]) :: {:ok, 0} | {:error, String.t()}
  def execute(argv) do
    with {:ok, opts, []} <- CLI.parse(argv, @switches),
         {:ok, to} <- required(opts[:to], "--to") do
      if opts[:label], do: label(to, opts), else: promote(to, opts)
    else
      {:ok, _opts, [_ | _] = args} -> {:error, "unexpected arguments #{Enum.join(args, " ")}"}
      error -> error
    end
  end

  defp promote(to, opts) do
    with {:ok, ids} <- ids(opts),
         {:ok, as} <- as(opts[:as]),
         {:ok, redactor} <- redactor(opts[:redactor]),
         {:ok, {module, state, _spec}} <- CLI.open_store(opts[:store]) do
      promote_opts =
        [to: to, as: as, redact: redactor, reviewer: opts[:reviewer]]
        |> Keyword.merge(if opts[:instance], do: [instance: opts[:instance]], else: [])

      case Nous.Eval.promote({module, state}, ids, promote_opts) do
        {:ok, %{promoted: promoted, skipped: skipped}} ->
          Mix.shell().info("Promoted #{promoted} sample(s) to #{to}")

          Enum.each(skipped, fn {id, reason} -> Mix.shell().info("  skipped #{id}: #{reason}") end)

          {:ok, 0}

        {:error, reason} ->
          {:error, "promotion failed: #{CLI.describe(reason)}"}
      end
    end
  end

  defp label(to, opts) do
    with {:ok, reviewer} <- required(opts[:reviewer], "--reviewer"),
         [id, label] <- String.split(opts[:label], "=", parts: 2) do
      case Review.label(to, id, label, reviewer) do
        :ok ->
          Mix.shell().info("Labelled #{id} #{label} in #{to}")
          {:ok, 0}

        {:error, reason} ->
          {:error, "cannot label #{id}: #{CLI.describe(reason)}"}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "--label expects ID=block or ID=allow"}
    end
  end

  defp required(nil, flag), do: {:error, "missing #{flag}"}
  defp required(value, _flag), do: {:ok, value}

  defp ids(opts) do
    from_flag = if opts[:ids], do: String.split(opts[:ids], ",", trim: true), else: []

    with {:ok, from_file} <- ids_file(opts[:ids_file]) do
      case Enum.map(from_flag ++ from_file, &String.trim/1) |> Enum.reject(&(&1 == "")) do
        [] -> {:error, "missing --ids or --ids-file"}
        ids -> {:ok, Enum.uniq(ids)}
      end
    end
  end

  defp ids_file(nil), do: {:ok, []}

  defp ids_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, String.split(text, "\n", trim: true)}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp as(nil), do: {:ok, :case}
  defp as("case"), do: {:ok, :case}

  defp as("guard_case:" <> surface) when surface in @surfaces,
    do: {:ok, {:guard_case, surface: surface}}

  defp as(other),
    do: {:error, "invalid --as #{inspect(other)}: expected case or guard_case:SURFACE"}

  # Only an existing atom is ever looked up (`Module.safe_concat/1`): a name
  # typed on the command line must not grow the atom table.
  defp redactor(nil), do: {:error, "missing --redactor MODULE"}

  defp redactor(name) do
    module = Module.safe_concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, :redact, 1),
      do: {:ok, module},
      else: {:error, "#{name} is not a redactor (no redact/1)"}
  rescue
    ArgumentError -> {:error, "unknown redactor module #{name}"}
  end
end
