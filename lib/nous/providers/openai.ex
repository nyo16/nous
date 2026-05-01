defmodule Nous.Providers.OpenAI do
  @moduledoc """
  OpenAI-specific provider implementation.

  Extends the generic OpenAI-compatible provider with OpenAI-specific features:
  - Structured outputs (response_format with json_schema)
  - Predicted outputs
  - Reasoning models (o1, o3)
  - Future: Responses API, Assistants API, etc.

  For generic OpenAI-compatible endpoints (Groq, Together, LM Studio, etc.),
  use `Nous.Providers.OpenAICompatible` instead.

  ## Usage

      # Basic chat
      {:ok, response} = Nous.Providers.OpenAI.chat(%{
        model: "gpt-4o",
        messages: [%{"role" => "user", "content" => "Hello"}]
      })

      # With structured output
      {:ok, response} = Nous.Providers.OpenAI.chat(%{
        model: "gpt-4o",
        messages: messages,
        response_format: %{
          type: "json_schema",
          json_schema: %{
            name: "response",
            schema: %{type: "object", properties: %{answer: %{type: "string"}}}
          }
        }
      })

      # Streaming
      {:ok, stream} = Nous.Providers.OpenAI.chat_stream(params)
      Enum.each(stream, fn event -> IO.inspect(event) end)

  ## Configuration

      # In config.exs
      config :nous, :openai,
        api_key: "sk-...",
        organization: "org-..."  # optional
  """

  use Nous.Provider,
    id: :openai,
    default_base_url: "https://api.openai.com/v1",
    default_env_key: "OPENAI_API_KEY"

  alias Nous.Providers.HTTP

  @default_timeout 180_000
  @streaming_timeout 120_000

  # Reasoning models have different requirements.
  # L-10: matched via a regex covering the full o-series digit family
  # rather than a hard-coded list, so new models like o4 / o3-pro /
  # o5-mini are detected without code changes. Also rejects ambiguous
  # patterns like "o1.5" (which the old String.starts_with?(model, "o1")
  # would have matched as :reasoning).
  @reasoning_pattern ~r/^(?:azure\/)?o[1-9](?:-[a-z]+(?:-[a-z0-9-]+)?|-\d{4,}-\d{2}-\d{2})?$/

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    url = "#{base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Handle reasoning model specifics
    params = maybe_adjust_for_reasoning(params)

    HTTP.post(url, params, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || ""

    # Reasoning models don't support streaming (as of early 2025)
    if reasoning_model?(model) do
      {:error,
       %{
         reason: :streaming_not_supported,
         message: "Reasoning models (#{model}) don't support streaming"
       }}
    else
      url = "#{base_url(opts)}/chat/completions"
      headers = build_headers(api_key(opts), opts)
      timeout = Keyword.get(opts, :timeout, @streaming_timeout)
      finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

      params = Map.put(params, "stream", true)

      HTTP.stream(url, params, headers, timeout: timeout, finch_name: finch_name)
    end
  end

  @doc """
  Check if a model is a reasoning model (o1, o3 series).

  Reasoning models have different API requirements:
  - No streaming support
  - No system messages (use developer messages instead)
  - No temperature parameter
  """
  @spec reasoning_model?(String.t()) :: boolean()
  def reasoning_model?(model) when is_binary(model) do
    Regex.match?(@reasoning_pattern, model)
  end

  def reasoning_model?(_), do: false

  # Adjust parameters for reasoning models. L-10: also drops the
  # frequency/presence penalties which o-series models reject with a
  # 400 from the OpenAI API; previously only temperature/top_p were
  # stripped.
  defp maybe_adjust_for_reasoning(params) do
    model = Map.get(params, "model") || Map.get(params, :model) || ""

    if reasoning_model?(model) do
      params
      |> Map.delete("temperature")
      |> Map.delete(:temperature)
      |> Map.delete("top_p")
      |> Map.delete(:top_p)
      |> Map.delete("presence_penalty")
      |> Map.delete(:presence_penalty)
      |> Map.delete("frequency_penalty")
      |> Map.delete(:frequency_penalty)

      # Note: System messages should be converted to developer messages by the caller
    else
      params
    end
  end

  # Build headers for the request
  defp build_headers(api_key, opts) do
    headers = [
      {"content-type", "application/json"}
    ]

    # Add authorization
    headers =
      if api_key && api_key != "" do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    # Add organization header if provided
    headers =
      case Keyword.get(opts, :organization) do
        nil -> headers
        org -> [{"openai-organization", org} | headers]
      end

    # Add project header if provided (for project-scoped API keys)
    case Keyword.get(opts, :project) do
      nil -> headers
      project -> [{"openai-project", project} | headers]
    end
  end
end
