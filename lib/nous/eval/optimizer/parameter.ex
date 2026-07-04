defmodule Nous.Eval.Optimizer.Parameter do
  @moduledoc """
  Defines optimizable parameters for agent configuration.

  Parameters define the search space for optimization. Each parameter
  specifies a name, type, and valid range of values.

  ## Parameter Types

  - `:float` - Continuous floating point values
  - `:integer` - Discrete integer values
  - `:choice` - Categorical choices from a list
  - `:bool` - Boolean true/false

  ## Examples

      # Temperature from 0.0 to 1.0 in steps of 0.1
      Parameter.float(:temperature, 0.0, 1.0, step: 0.1)

      # Max tokens from 100 to 2000 in steps of 100
      Parameter.integer(:max_tokens, 100, 2000, step: 100)

      # Model selection
      Parameter.choice(:model, [
        "lmstudio:ministral-3-14b",
        "lmstudio:qwen-7b",
        "openai:gpt-4"
      ])

      # Enable/disable a feature
      Parameter.bool(:use_cot)

  ## Conditional Parameters

  Parameters can be conditional on other parameter values:

      Parameter.float(:top_p, 0.0, 1.0,
        condition: {:temperature, &(&1 > 0.5)}
      )

  """

  alias __MODULE__

  @type param_type :: :float | :integer | :choice | :bool

  @type t :: %Parameter{
          name: atom(),
          type: param_type(),
          min: number() | nil,
          max: number() | nil,
          step: number() | nil,
          choices: [term()] | nil,
          default: term() | nil,
          condition: {atom(), function()} | nil,
          log_scale: boolean()
        }

  defstruct [
    :name,
    :type,
    :min,
    :max,
    :step,
    :choices,
    :default,
    :condition,
    log_scale: false
  ]

  @doc """
  Create a float parameter.

  ## Options

    * `:step` - Step size for grid search (default: calculated)
    * `:default` - Default value
    * `:log_scale` - Use log scale for sampling
    * `:condition` - Conditional on another parameter

  ## Examples

      Parameter.float(:temperature, 0.0, 1.0)
      Parameter.float(:temperature, 0.0, 1.0, step: 0.1)
      Parameter.float(:learning_rate, 1.0e-5, 1.0e-2, log_scale: true)

  """
  @spec float(atom(), number(), number(), keyword()) :: t()
  def float(name, min, max, opts \\ []) do
    %Parameter{
      name: name,
      type: :float,
      min: min,
      max: max,
      step: Keyword.get(opts, :step),
      default: Keyword.get(opts, :default),
      condition: Keyword.get(opts, :condition),
      log_scale: Keyword.get(opts, :log_scale, false)
    }
  end

  @doc """
  Create an integer parameter.

  ## Options

    * `:step` - Step size (default: 1)
    * `:default` - Default value
    * `:condition` - Conditional on another parameter

  ## Examples

      Parameter.integer(:max_tokens, 100, 4000)
      Parameter.integer(:max_tokens, 100, 4000, step: 100)

  """
  @spec integer(atom(), integer(), integer(), keyword()) :: t()
  def integer(name, min, max, opts \\ []) do
    %Parameter{
      name: name,
      type: :integer,
      min: min,
      max: max,
      step: Keyword.get(opts, :step, 1),
      default: Keyword.get(opts, :default),
      condition: Keyword.get(opts, :condition)
    }
  end

  @doc """
  Create a categorical choice parameter.

  ## Options

    * `:default` - Default value
    * `:condition` - Conditional on another parameter

  ## Examples

      Parameter.choice(:model, ["gpt-4", "gpt-3.5-turbo", "claude-3"])
      Parameter.choice(:strategy, [:greedy, :sampling, :beam_search])

  """
  @spec choice(atom(), [term()], keyword()) :: t()
  def choice(name, choices, opts \\ []) when is_list(choices) do
    %Parameter{
      name: name,
      type: :choice,
      choices: choices,
      default: Keyword.get(opts, :default, hd(choices)),
      condition: Keyword.get(opts, :condition)
    }
  end

  @doc """
  Create a boolean parameter.

  ## Options

    * `:default` - Default value (default: false)
    * `:condition` - Conditional on another parameter

  ## Examples

      Parameter.bool(:use_cot)
      Parameter.bool(:stream, default: true)

  """
  @spec bool(atom(), keyword()) :: t()
  def bool(name, opts \\ []) do
    %Parameter{
      name: name,
      type: :bool,
      choices: [true, false],
      default: Keyword.get(opts, :default, false),
      condition: Keyword.get(opts, :condition)
    }
  end

  @doc """
  Build a parameter from a plain data map (e.g. decoded from YAML/JSON).

  This is the safe alternative to evaluating an `.exs` parameter file: it
  constructs parameters from pure data, never executing code. Keys may be
  strings or atoms. The `:condition` feature (which needs a function) is NOT
  supported here — declare conditional parameters in code if you need them.

  ## Expected shape

      %{"type" => "float", "name" => "temperature", "min" => 0.0, "max" => 1.0,
        "step" => 0.1}
      %{"type" => "integer", "name" => "max_tokens", "min" => 256, "max" => 2048,
        "step" => 256}
      %{"type" => "choice", "name" => "model", "choices" => ["gpt-4", "gpt-4o"]}
      %{"type" => "bool", "name" => "use_cot", "default" => true}

  Returns `{:ok, t()}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    get = fn key -> map[key] || map[to_string(key)] end

    with {:ok, type} <- fetch_type(get.(:type)),
         {:ok, name} <- fetch_name(get.(:name)) do
      build_from_data(type, name, get)
    end
  end

  def from_map(other), do: {:error, "expected a parameter map, got: #{inspect(other)}"}

  defp fetch_type(type) when type in ["float", "integer", "choice", "bool"],
    do: {:ok, String.to_existing_atom(type)}

  defp fetch_type(type) when type in [:float, :integer, :choice, :bool], do: {:ok, type}
  defp fetch_type(other), do: {:error, "invalid parameter type: #{inspect(other)}"}

  # Parameter names are config keys (e.g. :temperature, :max_tokens) matched
  # against agent settings; resolving only existing atoms keeps a hostile
  # params file from minting arbitrary atoms while accepting the known knobs.
  defp fetch_name(name) when is_binary(name) do
    case Nous.Util.safe_existing_atom(name) do
      nil -> {:error, "unknown parameter name: #{inspect(name)}"}
      atom -> {:ok, atom}
    end
  end

  defp fetch_name(name) when is_atom(name) and not is_nil(name), do: {:ok, name}
  defp fetch_name(other), do: {:error, "invalid parameter name: #{inspect(other)}"}

  defp build_from_data(:float, name, get) do
    opts = data_opts(get, [:step, :default, :log_scale])
    {:ok, float(name, get.(:min), get.(:max), opts)}
  end

  defp build_from_data(:integer, name, get) do
    opts = data_opts(get, [:step, :default])
    {:ok, integer(name, get.(:min), get.(:max), opts)}
  end

  defp build_from_data(:choice, name, get) do
    case get.(:choices) do
      choices when is_list(choices) and choices != [] ->
        {:ok, choice(name, choices, data_opts(get, [:default]))}

      other ->
        {:error,
         "choice parameter #{inspect(name)} needs a non-empty :choices list, got: #{inspect(other)}"}
    end
  end

  defp build_from_data(:bool, name, get) do
    {:ok, bool(name, data_opts(get, [:default]))}
  end

  defp data_opts(get, keys) do
    Enum.flat_map(keys, fn key ->
      case get.(key) do
        nil -> []
        val -> [{key, val}]
      end
    end)
  end

  @doc """
  Get all possible values for a parameter (for grid search).
  """
  @spec values(t()) :: [term()]
  def values(%Parameter{type: :float, min: min, max: max, step: nil}) do
    # Default to 10 steps
    step = (max - min) / 10
    generate_range(min, max, step)
  end

  def values(%Parameter{type: :float, min: min, max: max, step: step, log_scale: false}) do
    generate_range(min, max, step)
  end

  def values(%Parameter{type: :float, min: min, max: max, step: step, log_scale: true}) do
    # Log scale: generate in log space then convert back
    log_min = :math.log10(min)
    log_max = :math.log10(max)
    log_step = (log_max - log_min) / ((max - min) / step)

    generate_range(log_min, log_max, log_step)
    |> Enum.map(&:math.pow(10, &1))
    |> Enum.map(&Float.round(&1, 6))
  end

  def values(%Parameter{type: :integer, min: min, max: max, step: step}) do
    Enum.to_list(min..max//step)
  end

  def values(%Parameter{type: :choice, choices: choices}), do: choices
  def values(%Parameter{type: :bool}), do: [true, false]

  @doc """
  Sample a random value from the parameter space.
  """
  @spec sample(t()) :: term()
  def sample(%Parameter{type: :float, min: min, max: max, log_scale: false}) do
    min + :rand.uniform() * (max - min)
  end

  def sample(%Parameter{type: :float, min: min, max: max, log_scale: true}) do
    log_min = :math.log10(min)
    log_max = :math.log10(max)
    log_val = log_min + :rand.uniform() * (log_max - log_min)
    :math.pow(10, log_val)
  end

  def sample(%Parameter{type: :integer, min: min, max: max}) do
    min + :rand.uniform(max - min + 1) - 1
  end

  def sample(%Parameter{type: :choice, choices: choices}) do
    Enum.random(choices)
  end

  def sample(%Parameter{type: :bool}) do
    :rand.uniform() > 0.5
  end

  @doc """
  Check if a parameter is active given current config.
  """
  @spec active?(t(), map()) :: boolean()
  def active?(%Parameter{condition: nil}, _config), do: true

  def active?(%Parameter{condition: {param_name, check_fn}}, config) do
    case Map.get(config, param_name) do
      nil -> false
      value -> check_fn.(value)
    end
  end

  # Private helpers

  defp generate_range(min, max, step) do
    count = trunc((max - min) / step) + 1

    Enum.map(0..(count - 1), fn i ->
      val = min + i * step
      if val > max, do: max, else: Float.round(val, 6)
    end)
    |> Enum.uniq()
  end
end
