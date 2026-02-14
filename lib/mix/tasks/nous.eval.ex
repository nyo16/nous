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
    cond do
      opts[:suite] ->
        # Load specific suite
        case Nous.Eval.Suite.from_yaml(opts[:suite]) do
          {:ok, suite} ->
            [suite]

          {:error, reason} ->
            Mix.shell().error("Failed to load suite: #{inspect(reason)}")
            []
        end

      true ->
        # Load from directory
        dir = opts[:dir] || "test/eval/suites"

        if File.dir?(dir) do
          case Nous.Eval.Suite.from_directory(dir) do
            {:ok, suites} ->
              suites

            {:error, reason} ->
              Mix.shell().error("Failed to load suites: #{inspect(reason)}")
              []
          end
        else
          Mix.shell().info("Creating evaluation directory: #{dir}")
          File.mkdir_p!(dir)
          []
        end
    end
  end

  defp build_run_opts(opts) do
    run_opts = []

    run_opts =
      if opts[:tags] do
        tags = opts[:tags] |> String.split(",") |> Enum.map(&String.to_atom/1)
        Keyword.put(run_opts, :tags, tags)
      else
        run_opts
      end

    run_opts =
      if opts[:exclude] do
        tags = opts[:exclude] |> String.split(",") |> Enum.map(&String.to_atom/1)
        Keyword.put(run_opts, :exclude_tags, tags)
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
    output_path = opts[:output]
    verbose = opts[:verbose] || false

    case format do
      "console" ->
        Enum.each(results, fn {_name, result} ->
          if verbose do
            Nous.Eval.Reporter.print_detailed(result)
          else
            Nous.Eval.Reporter.print(result)
          end
        end)

      "json" ->
        json_output =
          results
          |> Enum.map(fn {name, result} -> {name, Nous.Eval.Reporter.Json.to_map(result)} end)
          |> Enum.into(%{})
          |> Map.put(:generated_at, DateTime.to_iso8601(DateTime.utc_now()))
          |> Jason.encode!(pretty: true)

        if output_path do
          File.write!(output_path, json_output)
          Mix.shell().info("Results written to: #{output_path}")
        else
          IO.puts(json_output)
        end

      "markdown" ->
        md_output =
          Enum.map_join(results, "\n\n---\n\n", fn {_name, result} ->
            Nous.Eval.Reporter.to_markdown(result)
          end)

        if output_path do
          File.write!(output_path, md_output)
          Mix.shell().info("Results written to: #{output_path}")
        else
          IO.puts(md_output)
        end

      _ ->
        Mix.shell().error("Unknown format: #{format}")
    end
  end
end
