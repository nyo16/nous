defmodule Nous.Fallback do
  @moduledoc """
  Fallback model chain support.

  Provides automatic failover to alternative models when a primary model
  request fails with a `ProviderError` or `ModelError`.

  ## Usage

      # Build a model chain and try each in order
      models = Fallback.build_model_chain(primary, fallbacks)
      Fallback.with_fallback(models, fn model -> dispatch(model) end)

  Only provider/model-level errors trigger fallback. Errors like
  `ValidationError`, `MaxIterationsExceeded`, `ExecutionCancelled`, and
  `ToolError` are returned immediately since retrying with a different
  model would not help.
  """

  alias Nous.{Model, Errors}

  require Logger

  @doc """
  Returns `true` if the error is eligible for fallback retry.

  Eligible errors (infrastructure/provider failures):
  - `ProviderError` — API call failed (rate limit, server error, timeout, auth)
  - `ModelError` — model-level failure from the provider

  Non-eligible errors (application-level, retrying won't help):
  - `ValidationError` — structured output failed validation
  - `MaxIterationsExceeded` — agent loop limit hit
  - `ExecutionCancelled` — explicitly cancelled
  - `ToolError` / `ToolTimeout` — tool execution failed
  - `UsageLimitExceeded` — usage budget exhausted
  - `ConfigurationError` — misconfiguration
  """
  @spec fallback_eligible?(term()) :: boolean()
  def fallback_eligible?(%Errors.ProviderError{}), do: true
  def fallback_eligible?(%Errors.ModelError{}), do: true
  def fallback_eligible?(_), do: false

  @doc """
  Try each model in the chain until one succeeds or all fail.

  The `request_fn` receives a `Model.t()` and must return
  `{:ok, result}` or `{:error, reason}`.

  On fallback-eligible errors, emits telemetry and tries the next model.
  On non-eligible errors, returns immediately.

  ## Options

  - `:telemetry_prefix` — prefix for telemetry events (default: `[:nous, :fallback]`)
  """
  @spec with_fallback([Model.t()], (Model.t() -> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_fallback(models, request_fn, opts \\ [])

  def with_fallback([model], request_fn, _opts) do
    request_fn.(model)
  end

  def with_fallback([model | rest], request_fn, opts) do
    case request_fn.(model) do
      {:ok, _} = success ->
        success

      {:error, reason} ->
        if fallback_eligible?(reason) do
          next = hd(rest)

          Logger.warning(
            "Fallback: #{model.provider}:#{model.model} failed (#{inspect(reason)}), " <>
              "trying #{next.provider}:#{next.model}"
          )

          emit_fallback_activated(model, next, reason, opts)
          with_fallback(rest, request_fn, opts)
        else
          {:error, reason}
        end
    end
  end

  def with_fallback([], _request_fn, _opts) do
    {:error, Errors.ConfigurationError.exception(message: "Empty fallback model chain")}
  end

  @doc """
  Parse a mixed list of model strings and `Model.t()` structs into `[Model.t()]`.
  """
  @spec parse_fallback_models([String.t() | Model.t()], keyword()) :: [Model.t()]
  def parse_fallback_models(models, opts \\ []) do
    Enum.map(models, fn
      %Model{} = model -> model
      model_string when is_binary(model_string) -> Model.parse(model_string, opts)
    end)
  end

  @doc """
  Build the full model chain: primary model followed by fallback models.
  """
  @spec build_model_chain(Model.t(), [Model.t()]) :: [Model.t()]
  def build_model_chain(primary, fallbacks) do
    [primary | fallbacks]
  end

  # Telemetry

  defp emit_fallback_activated(failed_model, next_model, reason, opts) do
    prefix = Keyword.get(opts, :telemetry_prefix, [:nous, :fallback])

    :telemetry.execute(
      prefix ++ [:activated],
      %{system_time: System.system_time()},
      %{
        failed_provider: failed_model.provider,
        failed_model: failed_model.model,
        next_provider: next_model.provider,
        next_model: next_model.model,
        reason: reason
      }
    )
  end

  @doc false
  def emit_fallback_exhausted(last_model, reason, opts) do
    prefix = Keyword.get(opts, :telemetry_prefix, [:nous, :fallback])

    :telemetry.execute(
      prefix ++ [:exhausted],
      %{system_time: System.system_time()},
      %{
        last_provider: last_model.provider,
        last_model: last_model.model,
        reason: reason
      }
    )
  end
end
