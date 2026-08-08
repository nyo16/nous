defmodule Mix.Tasks.Nous.Eval do
  @moduledoc """
  Run evaluation suites for Nous agents.

  ## Usage

      # Run all suites from default directory (test/eval/suites)
      mix nous.eval

      # Run a specific suite file
      mix nous.eval --suite test/eval/suites/basic.yaml

      # Run from a different directory
      mix nous.eval --dir priv/eval

      # Filter by tags
      mix nous.eval --tags basic,tool

      # Exclude tags
      mix nous.eval --exclude slow,stress

      # Override model
      mix nous.eval --model lmstudio:ministral-3-14b-reasoning

      # Set parallelism
      mix nous.eval --parallel 4

      # Output format
      mix nous.eval --format json
      mix nous.eval --format json --output results.json

      # Verbose mode
      mix nous.eval --verbose

  ## Options

    * `--suite` - Path to a specific suite file (YAML)
    * `--dir` - Directory containing suite files (default: test/eval/suites)
    * `--tags` - Only run test cases with these tags (comma-separated)
    * `--exclude` - Exclude test cases with these tags (comma-separated)
    * `--model` - Override default model for all tests
    * `--parallel` - Number of concurrent tests (default: 1)
    * `--timeout` - Default timeout in ms (default: 30000)
    * `--format` - Output format: console, json, markdown (default: console)
    * `--output` - Output file path (for json/markdown formats)
    * `--verbose` - Show detailed output including passed tests
    * `--retry` - Number of retries for failed tests (default: 0)

  ## Configuration

  You can also configure defaults in your config:

      config :nous, Nous.Eval,
        default_model: "lmstudio:ministral-3-14b-reasoning",
        default_timeout: 30_000,
        parallelism: 4

  """

  use Mix.Task

  @shortdoc "Run Nous agent evaluation suites"

  @switches [
    suite: :string,
    dir: :string,
    tags: :string,
    exclude: :string,
    model: :string,
    parallel: :integer,
    timeout: :integer,
    format: :string,
    output: :string,
    verbose: :boolean,
    retry: :integer
  ]

  @impl Mix.Task
  def run(args) do
    # Start the application
    {:ok, _} = Application.ensure_all_started(:nous)

    {opts, _remaining, _invalid} = OptionParser.parse(args, switches: @switches)

    # Load suites
    suites = load_suites(opts)

    if suites == [] do
      Mix.shell().error("No evaluation suites found!")
      exit({:shutdown, 1})
    end

    # Build run options
    run_opts = build_run_opts(opts)

    # Run evaluations
    results = run_suites(suites, run_opts, opts)

    # Output results
    output_results(results, opts)

    # Exit with appropriate code
    all_passed = Enum.all?(results, fn {_, result} -> result.pass_rate == 1.0 end)

    unless all_passed do
      exit({:shutdown, 1})
    end
  end

  defp load_suites(opts) do
    if opts[:suite] do
      load_suite_file(opts[:suite])
    else
      load_suite_dir(opts[:dir] || "test/eval/suites")
    end
  end

  defp load_suite_file(path) do
    case Nous.Eval.Suite.from_yaml(path) do
      {:ok, suite} ->
        [suite]

      {:error, reason} ->
        Mix.shell().error("Failed to load suite: #{inspect(reason)}")
        []
    end
  end

  defp load_suite_dir(dir) do
    if File.dir?(dir) do
      read_suite_dir(dir)
    else
      Mix.shell().info("Creating evaluation directory: #{dir}")
      File.mkdir_p!(dir)
      []
    end
  end

  defp read_suite_dir(dir) do
    case Nous.Eval.Suite.from_directory(dir) do
      {:ok, suites} ->
        suites

      {:error, reason} ->
        Mix.shell().error("Failed to load suites: #{inspect(reason)}")
        []
    end
  end

  defp build_run_opts(opts) do
    run_opts = []

    run_opts =
      if opts[:tags] do
        Keyword.put(run_opts, :tags, parse_tags(opts[:tags]))
      else
        run_opts
      end

    run_opts =
      if opts[:exclude] do
        Keyword.put(run_opts, :exclude_tags, parse_tags(opts[:exclude]))
      else
        run_opts
      end

    run_opts =
      if opts[:model] do
        Keyword.put(run_opts, :model, opts[:model])
      else
        run_opts
      end

    run_opts =
      if opts[:parallel] do
        Keyword.put(run_opts, :parallelism, opts[:parallel])
      else
        run_opts
      end

    run_opts =
      if opts[:timeout] do
        Keyword.put(run_opts, :timeout, opts[:timeout])
      else
        run_opts
      end

    run_opts =
      if opts[:retry] do
        Keyword.put(run_opts, :retry_failed, opts[:retry])
      else
        run_opts
      end

    run_opts
  end

  # Parse a comma-separated tag list from CLI input.
  # NEVER use String.to_atom/1 on CLI args - a CI invocation that takes
  # repo-supplied filenames or env vars could exhaust the BEAM atom table.
  # Tags that don't already exist as atoms can't match any registered test
  # case anyway, so skipping them is safe.
  defp parse_tags(arg) when is_binary(arg) do
    arg
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn tag ->
      try do
        String.to_existing_atom(tag)
      rescue
        ArgumentError ->
          Mix.shell().info("Skipping unknown tag: #{tag}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp run_suites(suites, run_opts, opts) do
    verbose = opts[:verbose] || false

    Enum.map(suites, fn suite ->
      if verbose do
        Mix.shell().info("\nRunning suite: #{suite.name}")
        Mix.shell().info("Test cases: #{Nous.Eval.Suite.count(suite)}")
      end

      case Nous.Eval.run(suite, run_opts) do
        {:ok, result} ->
          {suite.name, result}

        {:error, reason} ->
          Mix.shell().error("Suite #{suite.name} failed: #{inspect(reason)}")
          {suite.name, nil}
      end
    end)
    |> Enum.reject(fn {_, result} -> is_nil(result) end)
  end

  defp output_results(results, opts) do
    format = opts[:format] || "console"

    case format do
      "console" -> print_console(results, opts[:verbose] || false)
      "json" -> write_output(json_report(results), opts[:output])
      "markdown" -> write_output(markdown_report(results), opts[:output])
      _ -> Mix.shell().error("Unknown format: #{format}")
    end
  end

  defp print_console(results, verbose) do
    Enum.each(results, fn {_name, result} ->
      if verbose do
        Nous.Eval.Reporter.print_detailed(result)
      else
        Nous.Eval.Reporter.print(result)
      end
    end)
  end

  defp json_report(results) do
    results
    |> Enum.map(fn {name, result} -> {name, Nous.Eval.Reporter.Json.to_map(result)} end)
    |> Enum.into(%{})
    |> Map.put(:generated_at, DateTime.to_iso8601(DateTime.utc_now()))
    |> Nous.JSON.pretty_encode!()
  end

  defp markdown_report(results) do
    Enum.map_join(results, "\n\n---\n\n", fn {_name, result} ->
      Nous.Eval.Reporter.to_markdown(result)
    end)
  end

  defp write_output(content, nil), do: IO.puts(content)

  defp write_output(content, path) do
    File.write!(path, content)
    Mix.shell().info("Results written to: #{path}")
  end
end
