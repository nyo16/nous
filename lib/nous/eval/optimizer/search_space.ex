defmodule Nous.Eval.Optimizer.SearchSpace do
  @moduledoc """
  Defines and manages the search space for optimization.

  A search space is a collection of parameters that define all possible
  configurations to explore during optimization.

  ## Example

      params = [
        Parameter.float(:temperature, 0.0, 1.0, step: 0.1),
        Parameter.integer(:max_tokens, 100, 1000, step: 100),
        Parameter.choice(:model, ["gpt-4", "gpt-3.5-turbo"])
      ]

      space = SearchSpace.from_parameters(params)

      # Get total number of combinations (for grid search)
      SearchSpace.size(space)  # => 110 * 10 * 2 = 2200

      # Generate all combinations
      SearchSpace.grid(space)  # => [%{temperature: 0.0, max_tokens: 100, model: "gpt-4"}, ...]

      # Sample a random configuration
      SearchSpace.sample(space)  # => %{temperature: 0.7, max_tokens: 500, model: "gpt-4"}

  """

  alias Nous.Eval.Optimizer.Parameter

  @type t :: %__MODULE__{
          parameters: [Parameter.t()],
          size: non_neg_integer() | :infinite
        }

  defstruct parameters: [],
            size: 0

  @doc """
  Create a search space from a list of parameters.
  """
  @spec from_parameters([Parameter.t()]) :: t()
  def from_parameters(parameters) when is_list(parameters) do
    size = calculate_size(parameters)

    %__MODULE__{
      parameters: parameters,
      size: size
    }
  end

  @doc """
  Get the total number of configurations in the search space.

  Returns `:infinite` if any parameter has continuous range without step.
  """
  @spec size(t()) :: non_neg_integer() | :infinite
  def size(%__MODULE__{size: size}), do: size

  @doc """
  Generate all configurations for grid search.

  Only works for finite search spaces. Returns a list of configuration maps.
  """
  @spec grid(t()) :: [map()]
  def grid(%__MODULE__{size: :infinite}) do
    raise ArgumentError,
          "Cannot generate grid for infinite search space. Add step sizes to parameters."
  end

  def grid(%__MODULE__{parameters: parameters}) do
    parameters
    |> Enum.map(fn param -> {param.name, Parameter.values(param)} end)
    |> cartesian_product()
    |> Enum.map(&Map.new/1)
  end

  @doc """
  Sample a random configuration from the search space.
  """
  @spec sample(t()) :: map()
  def sample(%__MODULE__{parameters: parameters}) do
    parameters
    |> Enum.map(fn param -> {param.name, Parameter.sample(param)} end)
    |> Map.new()
  end

  @doc """
  Sample n random configurations from the search space.
  """
  @spec sample_n(t(), non_neg_integer()) :: [map()]
  def sample_n(space, n) do
    Enum.map(1..n, fn _ -> sample(space) end)
  end

  @doc """
  Sample configurations using Latin Hypercube Sampling for better coverage.
  """
  @spec latin_hypercube_sample(t(), non_neg_integer()) :: [map()]
  def latin_hypercube_sample(%__MODULE__{parameters: parameters}, n) do
    # For each parameter, divide range into n equal intervals
    # and sample one point from each interval
    param_samples =
      Enum.map(parameters, fn param ->
        samples = latin_hypercube_for_param(param, n)
        {param.name, Enum.shuffle(samples)}
      end)

    # Combine samples from each parameter
    Enum.map(0..(n - 1), fn i ->
      param_samples
      |> Enum.map(fn {name, samples} -> {name, Enum.at(samples, i)} end)
      |> Map.new()
    end)
  end

  @doc """
  Get parameter by name.
  """
  @spec get_parameter(t(), atom()) :: Parameter.t() | nil
  def get_parameter(%__MODULE__{parameters: parameters}, name) do
    Enum.find(parameters, fn p -> p.name == name end)
  end

  @doc """
  Check if a configuration is valid (all required parameters present).
  """
  @spec valid_config?(t(), map()) :: boolean()
  def valid_config?(%__MODULE__{parameters: parameters}, config) do
    Enum.all?(parameters, fn param ->
      # Check if parameter is active given current config
      if Parameter.active?(param, config) do
        Map.has_key?(config, param.name)
      else
        true
      end
    end)
  end

  # Private helpers

  defp calculate_size(parameters) do
    Enum.reduce(parameters, 1, fn param, acc ->
      case acc do
        :infinite ->
          :infinite

        n ->
          param_size = length(Parameter.values(param))

          if param_size == 0 do
            :infinite
          else
            n * param_size
          end
      end
    end)
  end

  defp cartesian_product([]), do: [[]]

  defp cartesian_product([{name, values} | rest]) do
    for value <- values, tail <- cartesian_product(rest) do
      [{name, value} | tail]
    end
  end

  defp latin_hypercube_for_param(%Parameter{type: :float, min: min, max: max}, n) do
    interval_size = (max - min) / n

    Enum.map(0..(n - 1), fn i ->
      low = min + i * interval_size
      high = low + interval_size
      low + :rand.uniform() * (high - low)
    end)
  end

  defp latin_hypercube_for_param(%Parameter{type: :integer, min: min, max: max}, n) do
    interval_size = (max - min + 1) / n

    Enum.map(0..(n - 1), fn i ->
      low = min + trunc(i * interval_size)
      high = min + trunc((i + 1) * interval_size) - 1
      high = min(high, max)
      low + :rand.uniform(max(1, high - low + 1)) - 1
    end)
  end

  defp latin_hypercube_for_param(%Parameter{type: :choice, choices: choices}, n) do
    # For categorical, just repeat choices to fill n samples
    choices
    |> Stream.cycle()
    |> Enum.take(n)
  end

  defp latin_hypercube_for_param(%Parameter{type: :bool}, n) do
    # Alternate true/false
    [true, false]
    |> Stream.cycle()
    |> Enum.take(n)
  end
end
