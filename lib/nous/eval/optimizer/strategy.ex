defmodule Nous.Eval.Optimizer.Strategy do
  @moduledoc """
  Behaviour for optimization strategies.

  Strategies define how to explore the search space to find optimal configurations.

  ## Implementing a Custom Strategy

      defmodule MyStrategy do
        @behaviour Nous.Eval.Optimizer.Strategy

        @impl true
        def run(suite, search_space, metric, maximize, opts) do
          # Your optimization logic here
          # Return {:ok, [trial, ...]} or {:error, reason}
        end
      end

  ## Built-in Strategies

  - `Nous.Eval.Optimizer.Strategies.GridSearch` - Exhaustive grid search
  - `Nous.Eval.Optimizer.Strategies.Random` - Random search
  - `Nous.Eval.Optimizer.Strategies.Bayesian` - Bayesian optimization (TPE-inspired)

  """

  alias Nous.Eval.{Suite, Optimizer}
  alias Nous.Eval.Optimizer.SearchSpace

  @type trial :: Optimizer.trial()

  @doc """
  Run the optimization strategy.

  ## Parameters

    * `suite` - The evaluation suite to optimize
    * `search_space` - The parameter search space
    * `metric` - The metric to optimize
    * `maximize` - Whether to maximize (true) or minimize (false)
    * `opts` - Strategy-specific options

  ## Returns

    * `{:ok, trials}` - List of all trials run
    * `{:error, reason}` - If optimization fails

  """
  @callback run(
              suite :: Suite.t(),
              search_space :: SearchSpace.t(),
              metric :: Optimizer.metric(),
              maximize :: boolean(),
              opts :: keyword()
            ) :: {:ok, [trial()]} | {:error, term()}
end
