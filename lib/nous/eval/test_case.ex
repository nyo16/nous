defmodule Nous.Eval.TestCase do
  @moduledoc """
  Defines a single test case for agent evaluation.

  A test case specifies an input prompt, expected output, and evaluation criteria.

  ## Example

      test_case = TestCase.new(
        id: "weather_query",
        name: "Weather Query Test",
        input: "What's the weather in Tokyo?",
        expected: %{contains: ["Tokyo", "weather"]},
        eval_type: :contains,
        tags: [:tool, :basic],
        timeout: 30_000
      )

  ## Evaluation Types

  - `:exact_match` - Output must exactly match expected string
  - `:fuzzy_match` - String similarity must exceed threshold
  - `:contains` - Output must contain all expected substrings
  - `:tool_usage` - Verify correct tools were called with correct args
  - `:schema` - Validate output against Ecto schema
  - `:llm_judge` - Use LLM to judge output quality
  - `:custom` - Use custom evaluator module

  ## Expected Formats

  The expected value format depends on the eval_type:

  - `:exact_match` - `"expected string"`
  - `:fuzzy_match` - `"expected string"` (with threshold in eval_config)
  - `:contains` - `%{contains: ["word1", "word2"]}` or `["word1", "word2"]`
  - `:tool_usage` - `%{tools_called: ["tool_name"], output_contains: ["..."]}`
  - `:schema` - `MyApp.Schema` (module name)
  - `:llm_judge` - `%{criteria: "...", rubric: "..."}`
  - `:custom` - Any format understood by your evaluator

  """

  @type eval_type ::
          :exact_match
          | :fuzzy_match
          | :contains
          | :tool_usage
          | :schema
          | :llm_judge
          | :custom

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          input: String.t() | [Nous.Message.t()],
          expected: term(),
          eval_type: eval_type(),
          eval_config: map(),
          tags: [atom()],
          deps: map(),
          tools: [Nous.Tool.t()] | nil,
          agent_config: keyword(),
          timeout: non_neg_integer(),
          metadata: map()
        }

  @enforce_keys [:id, :input]
  defstruct [
    :id,
    :name,
    :description,
    :input,
    :expected,
    eval_type: :contains,
    eval_config: %{},
    tags: [],
    deps: %{},
    tools: nil,
    agent_config: [],
    timeout: 30_000,
    metadata: %{}
  ]

  @doc """
  Create a new test case.

  ## Options

    * `:id` - Unique identifier (required)
    * `:input` - Input prompt or messages (required)
    * `:name` - Human-readable name
    * `:description` - Longer description
    * `:expected` - Expected output (format depends on eval_type)
    * `:eval_type` - Evaluation type (default: :contains)
    * `:eval_config` - Configuration for the evaluator
    * `:tags` - List of tags for filtering
    * `:deps` - Dependencies to pass to agent
    * `:tools` - Tools to provide to the agent
    * `:agent_config` - Additional agent configuration
    * `:timeout` - Timeout in milliseconds (default: 30_000)
    * `:metadata` - Additional metadata

  ## Examples

      # Simple contains check
      TestCase.new(
        id: "greeting",
        input: "Say hello",
        expected: %{contains: ["hello"]}
      )

      # Exact match
      TestCase.new(
        id: "math",
        input: "What is 2+2?",
        expected: "4",
        eval_type: :exact_match
      )

      # Fuzzy match with threshold
      TestCase.new(
        id: "fuzzy",
        input: "What is the capital of France?",
        expected: "Paris is the capital of France",
        eval_type: :fuzzy_match,
        eval_config: %{threshold: 0.7}
      )

      # Tool usage verification
      TestCase.new(
        id: "tool_test",
        input: "What's the weather?",
        expected: %{tools_called: ["get_weather"]},
        eval_type: :tool_usage,
        tools: [weather_tool]
      )

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)
    input = Keyword.fetch!(opts, :input)

    %__MODULE__{
      id: to_string(id),
      name: Keyword.get(opts, :name),
      description: Keyword.get(opts, :description),
      input: input,
      expected: Keyword.get(opts, :expected),
      eval_type: Keyword.get(opts, :eval_type, :contains),
      eval_config: Keyword.get(opts, :eval_config, %{}),
      tags: Keyword.get(opts, :tags, []) |> Enum.map(&safe_to_atom/1) |> Enum.reject(&is_nil/1),
      deps: Keyword.get(opts, :deps, %{}),
      tools: Keyword.get(opts, :tools),
      agent_config: Keyword.get(opts, :agent_config, []),
      timeout: Keyword.get(opts, :timeout, 30_000),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Create a test case from a map (used by YAML loader).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, id} <- fetch_required(map, [:id, "id"]),
         {:ok, input} <- fetch_required(map, [:input, "input"]) do
      test_case = %__MODULE__{
        id: to_string(id),
        name: get_any(map, [:name, "name"]),
        description: get_any(map, [:description, "description"]),
        input: input,
        expected: get_any(map, [:expected, "expected"]),
        eval_type: get_any(map, [:eval_type, "eval_type"], :contains) |> parse_eval_type(),
        eval_config: get_any(map, [:eval_config, "eval_config"], %{}) |> atomize_keys(),
        tags:
          get_any(map, [:tags, "tags"], []) |> Enum.map(&safe_to_atom/1) |> Enum.reject(&is_nil/1),
        deps: get_any(map, [:deps, "deps"], %{}),
        tools: nil,
        agent_config: get_any(map, [:agent_config, "agent_config"], %{}) |> atomize_keys(),
        timeout: get_any(map, [:timeout, "timeout"], 30_000),
        metadata: get_any(map, [:metadata, "metadata"], %{})
      }

      {:ok, test_case}
    end
  end

  # YAML files come from arbitrary user paths (--suite). Whitelist eval_type so
  # untrusted suite files cannot inject arbitrary atoms into the global table.
  @valid_eval_types ~w(exact_match fuzzy_match contains tool_usage schema llm_judge custom)a

  defp parse_eval_type(value) when is_atom(value) do
    if value in @valid_eval_types, do: value, else: :contains
  end

  defp parse_eval_type(value) when is_binary(value) do
    case Enum.find(@valid_eval_types, fn a -> Atom.to_string(a) == value end) do
      nil -> value
      atom -> atom
    end
  end

  defp parse_eval_type(_), do: :contains

  # Convert a YAML scalar to an existing atom; unknown values are dropped.
  # NEVER use String.to_atom/1 here - YAML files are user-controllable input.
  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_atom(_), do: nil

  @doc """
  Validate a test case.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = tc) do
    cond do
      is_nil(tc.id) or tc.id == "" ->
        {:error, "Test case ID is required"}

      is_nil(tc.input) ->
        {:error, "Test case input is required"}

      tc.eval_type not in [
        :exact_match,
        :fuzzy_match,
        :contains,
        :tool_usage,
        :schema,
        :llm_judge,
        :custom
      ] ->
        {:error, "Invalid eval_type: #{inspect(tc.eval_type)}"}

      tc.eval_type == :custom and not Map.has_key?(tc.eval_config, :evaluator) ->
        {:error, "Custom eval_type requires :evaluator in eval_config"}

      true ->
        :ok
    end
  end

  @doc """
  Get display name for the test case.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name, id: id}) do
    name || id
  end

  # Private helpers

  defp fetch_required(map, keys) do
    case Enum.find_value(keys, fn k -> Map.get(map, k) end) do
      nil -> {:error, "Missing required field: #{inspect(hd(keys))}"}
      value -> {:ok, value}
    end
  end

  defp get_any(map, keys, default \\ nil) do
    Enum.find_value(keys, default, fn k -> Map.get(map, k) end)
  end

  # eval_config / agent_config maps come from arbitrary YAML. Convert to atoms
  # ONLY if the atom already exists in the BEAM; unknown keys remain as
  # binaries. This prevents YAML files from exhausting the global atom table.
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {atom_key_or_binary(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  defp atom_key_or_binary(binary) do
    String.to_existing_atom(binary)
  rescue
    ArgumentError -> binary
  end
end
