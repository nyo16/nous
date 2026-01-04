defmodule Nous.Eval.Suite do
  @moduledoc """
  A collection of test cases with shared configuration.

  Suites group related test cases and provide shared defaults for model,
  timeout, and other settings.

  ## Example

      suite = Suite.new(
        name: "weather_agent_tests",
        description: "Tests for the weather agent",
        default_model: "lmstudio:ministral-3-14b-reasoning",
        test_cases: [
          TestCase.new(id: "basic", input: "What's the weather?", ...),
          TestCase.new(id: "city", input: "Weather in Tokyo?", ...)
        ]
      )

  ## Loading from YAML

      {:ok, suite} = Suite.from_yaml("test/eval/suites/weather.yaml")

  ## Filtering

      # Filter by tags
      filtered = Suite.filter_by_tags(suite, [:basic, :tool])

      # Exclude tags
      filtered = Suite.exclude_tags(suite, [:slow])

  """

  alias Nous.Eval.TestCase

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          test_cases: [TestCase.t()],
          default_model: String.t() | nil,
          default_instructions: String.t() | nil,
          default_timeout: non_neg_integer(),
          parallelism: non_neg_integer(),
          retry_failed: non_neg_integer(),
          setup: (-> map()) | nil,
          teardown: (map() -> :ok) | nil,
          metadata: map()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :description,
    :default_instructions,
    :setup,
    :teardown,
    test_cases: [],
    default_model: nil,
    default_timeout: 30_000,
    parallelism: 1,
    retry_failed: 0,
    metadata: %{}
  ]

  @doc """
  Create a new test suite.

  ## Options

    * `:name` - Suite name (required)
    * `:description` - Human-readable description
    * `:test_cases` - List of TestCase structs
    * `:default_model` - Default model for all test cases
    * `:default_instructions` - Default system instructions
    * `:default_timeout` - Default timeout in ms (default: 30_000)
    * `:parallelism` - Number of concurrent tests (default: 1)
    * `:retry_failed` - Retry count for failed tests (default: 0)
    * `:setup` - Function called before suite runs
    * `:teardown` - Function called after suite runs
    * `:metadata` - Additional metadata

  ## Example

      suite = Suite.new(
        name: "my_tests",
        default_model: "lmstudio:ministral-3-14b-reasoning",
        test_cases: [
          TestCase.new(id: "test1", input: "Hello"),
          TestCase.new(id: "test2", input: "World")
        ]
      )

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)

    %__MODULE__{
      name: to_string(name),
      description: Keyword.get(opts, :description),
      test_cases: Keyword.get(opts, :test_cases, []),
      default_model: Keyword.get(opts, :default_model),
      default_instructions: Keyword.get(opts, :default_instructions),
      default_timeout: Keyword.get(opts, :default_timeout, 30_000),
      parallelism: Keyword.get(opts, :parallelism, 1),
      retry_failed: Keyword.get(opts, :retry_failed, 0),
      setup: Keyword.get(opts, :setup),
      teardown: Keyword.get(opts, :teardown),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Add a test case to the suite.
  """
  @spec add_case(t(), TestCase.t()) :: t()
  def add_case(%__MODULE__{} = suite, %TestCase{} = test_case) do
    %{suite | test_cases: suite.test_cases ++ [test_case]}
  end

  @doc """
  Add multiple test cases to the suite.
  """
  @spec add_cases(t(), [TestCase.t()]) :: t()
  def add_cases(%__MODULE__{} = suite, test_cases) when is_list(test_cases) do
    %{suite | test_cases: suite.test_cases ++ test_cases}
  end

  @doc """
  Filter test cases by tags (include only cases with ANY of the specified tags).
  """
  @spec filter_by_tags(t(), [atom()]) :: t()
  def filter_by_tags(%__MODULE__{} = suite, tags) when is_list(tags) do
    filtered =
      Enum.filter(suite.test_cases, fn tc ->
        Enum.any?(tc.tags, &(&1 in tags))
      end)

    %{suite | test_cases: filtered}
  end

  @doc """
  Exclude test cases with any of the specified tags.
  """
  @spec exclude_tags(t(), [atom()]) :: t()
  def exclude_tags(%__MODULE__{} = suite, tags) when is_list(tags) do
    filtered =
      Enum.reject(suite.test_cases, fn tc ->
        Enum.any?(tc.tags, &(&1 in tags))
      end)

    %{suite | test_cases: filtered}
  end

  @doc """
  Get test case by ID.
  """
  @spec get_case(t(), String.t()) :: TestCase.t() | nil
  def get_case(%__MODULE__{test_cases: cases}, id) do
    Enum.find(cases, fn tc -> tc.id == id end)
  end

  @doc """
  Get number of test cases.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{test_cases: cases}), do: length(cases)

  @doc """
  Load a suite from a YAML file.

  ## Example YAML

      name: my_suite
      default_model: lmstudio:ministral-3-14b-reasoning
      default_timeout: 30000

      test_cases:
        - id: greeting
          input: "Say hello"
          expected:
            contains: ["hello"]
          eval_type: contains
          tags: [basic]

        - id: math
          input: "What is 2+2?"
          expected: "4"
          eval_type: exact_match

  """
  @spec from_yaml(String.t()) :: {:ok, t()} | {:error, term()}
  def from_yaml(path) do
    Nous.Eval.YamlLoader.load_suite(path)
  end

  @doc """
  Load a suite from a YAML file, raising on error.
  """
  @spec from_yaml!(String.t()) :: t()
  def from_yaml!(path) do
    case from_yaml(path) do
      {:ok, suite} -> suite
      {:error, reason} -> raise "Failed to load suite: #{inspect(reason)}"
    end
  end

  @doc """
  Load all suites from a directory.

  Loads all .yaml and .yml files from the directory.
  """
  @spec from_directory(String.t()) :: {:ok, [t()]} | {:error, term()}
  def from_directory(dir) do
    Nous.Eval.YamlLoader.load_directory(dir)
  end

  @doc """
  Validate a suite and all its test cases.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = suite) do
    cond do
      is_nil(suite.name) or suite.name == "" ->
        {:error, "Suite name is required"}

      suite.test_cases == [] ->
        {:error, "Suite must have at least one test case"}

      true ->
        validate_test_cases(suite.test_cases)
    end
  end

  defp validate_test_cases([]), do: :ok

  defp validate_test_cases([tc | rest]) do
    case TestCase.validate(tc) do
      :ok -> validate_test_cases(rest)
      {:error, reason} -> {:error, "Test case #{tc.id}: #{reason}"}
    end
  end

  @doc """
  Get all unique tags used in the suite.
  """
  @spec all_tags(t()) :: [atom()]
  def all_tags(%__MODULE__{test_cases: cases}) do
    cases
    |> Enum.flat_map(& &1.tags)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
