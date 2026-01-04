defmodule Nous.Eval.Config do
  @moduledoc """
  Configuration for the evaluation framework.

  Configuration can be set via:
  - Application environment
  - Environment variables
  - Explicit options passed to functions

  ## Application Configuration

      config :nous, Nous.Eval,
        default_model: "lmstudio:ministral-3-14b-reasoning",
        default_timeout: 30_000,
        parallelism: 4,
        results_path: "priv/eval_results"

  ## Environment Variables

      NOUS_EVAL_DEFAULT_MODEL=lmstudio:model
      NOUS_EVAL_DEFAULT_TIMEOUT=60000

  ## Cost Configuration

  Provider pricing for cost estimation (per 1K tokens):

      config :nous, Nous.Eval,
        cost_config: %{
          "lmstudio" => %{input: 0.0, output: 0.0},
          "openai" => %{input: 0.01, output: 0.03},
          "anthropic" => %{input: 0.015, output: 0.075}
        }

  """

  @type t :: %__MODULE__{
          default_model: String.t() | nil,
          default_timeout: non_neg_integer(),
          default_instructions: String.t() | nil,
          parallelism: non_neg_integer(),
          store_results: boolean(),
          results_path: String.t(),
          cost_config: map()
        }

  defstruct default_model: nil,
            default_timeout: 60_000,
            default_instructions: nil,
            parallelism: 1,
            store_results: true,
            results_path: "priv/eval_results",
            cost_config: %{
              # Local inference is free
              "lmstudio" => %{input: 0.0, output: 0.0},
              "ollama" => %{input: 0.0, output: 0.0},
              "vllm" => %{input: 0.0, output: 0.0},
              "sglang" => %{input: 0.0, output: 0.0},
              # Cloud providers (per 1K tokens, approximate)
              "openai" => %{input: 0.01, output: 0.03},
              "anthropic" => %{input: 0.015, output: 0.075},
              "groq" => %{input: 0.0005, output: 0.001},
              "gemini" => %{input: 0.0005, output: 0.0015},
              "mistral" => %{input: 0.002, output: 0.006},
              "openrouter" => %{input: 0.01, output: 0.03},
              "together" => %{input: 0.005, output: 0.015}
            }

  @doc """
  Get configuration from application environment and env vars.

  Merges configuration from:
  1. Defaults
  2. Application config
  3. Environment variables
  4. Explicit options
  """
  @spec get(keyword()) :: t()
  def get(opts \\ []) do
    app_config = Application.get_env(:nous, Nous.Eval, [])

    %__MODULE__{
      default_model:
        opts[:default_model] ||
          env_string("NOUS_EVAL_DEFAULT_MODEL") ||
          app_config[:default_model],
      default_timeout:
        opts[:default_timeout] ||
          env_integer("NOUS_EVAL_DEFAULT_TIMEOUT") ||
          app_config[:default_timeout] ||
          60_000,
      default_instructions:
        opts[:default_instructions] ||
          app_config[:default_instructions],
      parallelism:
        opts[:parallelism] ||
          env_integer("NOUS_EVAL_PARALLELISM") ||
          app_config[:parallelism] ||
          1,
      store_results:
        opts[:store_results] ||
          app_config[:store_results] ||
          true,
      results_path:
        opts[:results_path] ||
          env_string("NOUS_EVAL_RESULTS_PATH") ||
          app_config[:results_path] ||
          "priv/eval_results",
      cost_config: merge_cost_config(app_config[:cost_config])
    }
  end

  @doc """
  Get LM Studio configuration from environment.
  """
  @spec lmstudio_config() :: keyword()
  def lmstudio_config do
    [
      base_url:
        System.get_env("LMSTUDIO_BASE_URL") ||
          System.get_env("LMSTUDIO_URL") ||
          "http://localhost:1234/v1"
    ]
  end

  @doc """
  Get model for a test, with fallback chain.
  """
  @spec get_model(Nous.Eval.TestCase.t() | nil, Nous.Eval.Suite.t() | nil, keyword()) ::
          String.t() | nil
  def get_model(test_case, suite, opts \\ []) do
    config = get(opts)

    cond do
      opts[:model] -> opts[:model]
      test_case && test_case.agent_config[:model] -> test_case.agent_config[:model]
      suite && suite.default_model -> suite.default_model
      config.default_model -> config.default_model
      true -> nil
    end
  end

  @doc """
  Estimate cost for token usage.

  Returns cost in USD.
  """
  @spec estimate_cost(String.t(), non_neg_integer(), non_neg_integer()) :: float()
  def estimate_cost(provider, input_tokens, output_tokens) do
    config = get()
    provider_key = extract_provider(provider)
    rates = Map.get(config.cost_config, provider_key, %{input: 0.0, output: 0.0})

    input_cost = input_tokens / 1000 * rates.input
    output_cost = output_tokens / 1000 * rates.output

    Float.round(input_cost + output_cost, 6)
  end

  # Private helpers

  defp env_string(key), do: System.get_env(key)

  defp env_integer(key) do
    case System.get_env(key) do
      nil -> nil
      val -> String.to_integer(val)
    end
  end

  defp merge_cost_config(nil), do: %__MODULE__{}.cost_config

  defp merge_cost_config(custom) do
    Map.merge(%__MODULE__{}.cost_config, custom)
  end

  defp extract_provider(model_string) when is_binary(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider | _] -> provider
      _ -> "unknown"
    end
  end

  defp extract_provider(_), do: "unknown"
end
