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

  @type param_type :: :float | :integer | :choice | :bool

  @type t :: %__MODULE__{
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
    %__MODULE__{
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
    %__MODULE__{
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
    %__MODULE__{
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
    %__MODULE__{
      name: name,
      type: :bool,
      choices: [true, false],
      default: Keyword.get(opts, :default, false),
      condition: Keyword.get(opts, :condition)
    }
  end

  @doc """
  Get all possible values for a parameter (for grid search).
  """
  @spec values(t()) :: [term()]
  def values(%__MODULE__{type: :float, min: min, max: max, step: nil}) do
    # Default to 10 steps
    step = (max - min) / 10
    generate_range(min, max, step)
  end

  def values(%__MODULE__{type: :float, min: min, max: max, step: step, log_scale: false}) do
    generate_range(min, max, step)
  end

  def values(%__MODULE__{type: :float, min: min, max: max, step: step, log_scale: true}) do
    # Log scale: generate in log space then convert back
    log_min = :math.log10(min)
    log_max = :math.log10(max)
    log_step = (log_max - log_min) / ((max - min) / step)

    generate_range(log_min, log_max, log_step)
    |> Enum.map(&:math.pow(10, &1))
    |> Enum.map(&Float.round(&1, 6))
  end

  def values(%__MODULE__{type: :integer, min: min, max: max, step: step}) do
    Enum.to_list(min..max//step)
  end

  def values(%__MODULE__{type: :choice, choices: choices}), do: choices
  def values(%__MODULE__{type: :bool}), do: [true, false]

  @doc """
  Sample a random value from the parameter space.
  """
  @spec sample(t()) :: term()
  def sample(%__MODULE__{type: :float, min: min, max: max, log_scale: false}) do
    min + :rand.uniform() * (max - min)
  end

  def sample(%__MODULE__{type: :float, min: min, max: max, log_scale: true}) do
    log_min = :math.log10(min)
    log_max = :math.log10(max)
    log_val = log_min + :rand.uniform() * (log_max - log_min)
    :math.pow(10, log_val)
  end

  def sample(%__MODULE__{type: :integer, min: min, max: max}) do
    min + :rand.uniform(max - min + 1) - 1
  end

  def sample(%__MODULE__{type: :choice, choices: choices}) do
    Enum.random(choices)
  end

  def sample(%__MODULE__{type: :bool}) do
    :rand.uniform() > 0.5
  end

  @doc """
  Check if a parameter is active given current config.
  """
  @spec active?(t(), map()) :: boolean()
  def active?(%__MODULE__{condition: nil}, _config), do: true

  def active?(%__MODULE__{condition: {param_name, check_fn}}, config) do
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
