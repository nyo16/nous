defmodule Nous.Eval.YamlLoader do
  @moduledoc """
  Loads evaluation suites and test cases from YAML files.

  ## Example YAML Format

      name: my_suite
      description: Test suite for weather agent
      default_model: lmstudio:ministral-3-14b-reasoning
      default_timeout: 30000
      parallelism: 2

      test_cases:
        - id: basic_query
          name: Basic Weather Query
          input: "What's the weather in Tokyo?"
          expected:
            contains: ["weather", "Tokyo"]
          eval_type: contains
          tags: [basic, weather]
          timeout: 20000

        - id: exact_response
          name: Math Test
          input: "What is 2+2?"
          expected: "4"
          eval_type: exact_match

        - id: quality_check
          name: Explanation Quality
          input: "Explain recursion"
          expected:
            criteria: "Is the explanation clear?"
          eval_type: llm_judge
          eval_config:
            judge_model: lmstudio:ministral-3-14b-reasoning

  """

  alias Nous.Eval.{Suite, TestCase}

  @doc """
  Load a suite from a YAML file.
  """
  @spec load_suite(String.t()) :: {:ok, Suite.t()} | {:error, term()}
  def load_suite(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- parse_yaml(content),
         {:ok, suite} <- build_suite(data, path) do
      {:ok, suite}
    else
      {:error, reason} ->
        {:error, {:yaml_load_error, path, reason}}
    end
  end

  @doc """
  Load all suites from a directory.
  """
  @spec load_directory(String.t()) :: {:ok, [Suite.t()]} | {:error, term()}
  def load_directory(dir) do
    pattern = Path.join(dir, "*.{yaml,yml}")

    files = Path.wildcard(pattern)

    if files == [] do
      {:error, {:no_yaml_files, dir}}
    else
      results =
        Enum.map(files, fn file ->
          case load_suite(file) do
            {:ok, suite} -> {:ok, suite}
            {:error, reason} -> {:error, {file, reason}}
          end
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors == [] do
        suites = Enum.map(results, fn {:ok, suite} -> suite end)
        {:ok, suites}
      else
        {:error, {:load_errors, errors}}
      end
    end
  end

  # Private implementation

  defp parse_yaml(content) do
    try do
      data = YamlElixir.read_from_string!(content)
      {:ok, data}
    rescue
      e in YamlElixir.ParsingError ->
        {:error, {:yaml_parse_error, e.message}}

      e ->
        {:error, {:yaml_error, Exception.message(e)}}
    end
  end

  defp build_suite(data, path) when is_map(data) do
    name = Map.get(data, "name") || Path.basename(path, Path.extname(path))

    # Parse test cases
    test_cases_data = Map.get(data, "test_cases", [])

    test_cases_result =
      Enum.reduce_while(test_cases_data, {:ok, []}, fn tc_data, {:ok, acc} ->
        case TestCase.from_map(tc_data) do
          {:ok, tc} -> {:cont, {:ok, [tc | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case test_cases_result do
      {:ok, test_cases} ->
        suite =
          Suite.new(
            name: name,
            description: Map.get(data, "description"),
            test_cases: Enum.reverse(test_cases),
            default_model: Map.get(data, "default_model"),
            default_instructions: Map.get(data, "default_instructions"),
            default_timeout: Map.get(data, "default_timeout", 30_000),
            parallelism: Map.get(data, "parallelism", 1),
            retry_failed: Map.get(data, "retry_failed", 0),
            metadata: Map.get(data, "metadata", %{})
          )

        {:ok, suite}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_suite(data, _path) do
    {:error, {:invalid_yaml_format, "Expected a map, got: #{inspect(data)}"}}
  end
end
