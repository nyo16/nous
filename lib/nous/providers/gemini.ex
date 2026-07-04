defmodule Nous.Providers.Gemini do
  @moduledoc """
  Google Gemini provider implementation.

  Supports Gemini models via the Google AI Generative Language API.

  ## Usage

      # Basic usage
      {:ok, response} = Nous.Providers.Gemini.chat(%{
        model: "gemini-2.0-flash-exp",
        contents: [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]
      })

      # With system instruction
      {:ok, response} = Nous.Providers.Gemini.chat(%{
        model: "gemini-2.0-flash-exp",
        systemInstruction: %{"parts" => [%{"text" => "You are helpful."}]},
        contents: [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}],
        generationConfig: %{"temperature" => 0.7, "maxOutputTokens" => 1024}
      })

      # Streaming
      {:ok, stream} = Nous.Providers.Gemini.chat_stream(params)
      Enum.each(stream, fn event -> IO.inspect(event) end)

  ## Configuration

      # In config.exs
      config :nous, :gemini,
        api_key: "AIza...",
        base_url: "https://generativelanguage.googleapis.com/v1beta"  # optional

  ## Note on Authentication

  The API key is sent via the `x-goog-api-key` request header (not the URL
  query string), so it does not leak into proxy/load-balancer access logs,
  tracing spans, or redirect logs.

  ## Thinking (Gemini 2.5/3.x)

  For models that support extended thinking, pass `:thinking_config` in
  `default_settings`. Both the Elixir shape (snake_case atoms) and the native
  Vertex shape (camelCase strings) are accepted:

      # Elixir shape (recommended)
      Nous.new("gemini:gemini-2.5-pro",
        default_settings: %{
          thinking_config: %{thinking_budget: 1024, include_thoughts: true}
        }
      )

      # Native Vertex shape
      Nous.new("gemini:gemini-2.5-pro",
        default_settings: %{
          thinking_config: %{"thinkingBudget" => 1024, "includeThoughts" => true}
        }
      )

  When `include_thoughts: true`, thought summaries arrive as
  `Message.reasoning_content`. For tool-using thinking models, Vertex emits a
  `thoughtSignature` on each tool call; Nous preserves it in
  `tool_call["metadata"]["thought_signature"]` and echoes it back on the next
  turn automatically — required for multi-turn thinking + tool loops to keep
  working.

  See https://ai.google.dev/gemini-api/docs/thinking for the Gemini-side docs
  and https://cloud.google.com/vertex-ai/generative-ai/docs/thinking for the
  Vertex equivalent.
  """

  use Nous.Provider,
    id: :gemini,
    default_base_url: "https://generativelanguage.googleapis.com/v1beta",
    default_env_key: "GOOGLE_AI_API_KEY"

  alias Nous.Providers.HTTP

  # Single source of truth for the provider's HTTP receive timeout. The actual
  # timeout used at request time is `model.receive_timeout` (set via
  # `Model.parse(..., receive_timeout: ms)`), which flows through
  # `build_provider_opts/1` as the `:timeout` option. This constant is only the
  # safety-net default when `chat/2` or `chat_stream/2` is called directly
  # without a model-level value.
  @default_timeout 120_000

  # Override to convert from generic format to Gemini's format. The builder is
  # shared with Vertex AI (same wire format); only :extra_body merging stays
  # here so the macro-injected blocked-key policy applies.
  defp build_request_params(model, messages, settings) do
    merged_settings = Map.merge(model.default_settings, settings)

    model
    |> Nous.Messages.Gemini.build_request_params(messages, merged_settings)
    |> maybe_merge_extra_body(merged_settings[:extra_body])
  end

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || "gemini-2.0-flash-exp"
    api_key = api_key(opts)

    url = build_url(base_url(opts), model, :generate)
    headers = build_headers(api_key)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Remove model from params (it's in the URL)
    body = params |> Map.delete("model") |> Map.delete(:model)

    HTTP.post(url, body, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || "gemini-2.0-flash-exp"
    api_key = api_key(opts)

    url = build_url(base_url(opts), model, :stream)
    headers = build_headers(api_key)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    # Remove model from params (it's in the URL)
    body = params |> Map.delete("model") |> Map.delete(:model)

    HTTP.stream(url, body, headers,
      timeout: timeout,
      finch_name: finch_name,
      stream_parser: Nous.Providers.HTTP.JSONArrayParser
    )
  end

  # Build URL with model. The API key is sent via the x-goog-api-key header
  # (see build_headers/1), NOT the query string — URLs leak into proxy/LB access
  # logs, APM spans, and redirect logs, so a key in the query is a secret leak.
  defp build_url(base_url, model, :generate) do
    "#{base_url}/models/#{model}:generateContent"
  end

  defp build_url(base_url, model, :stream) do
    "#{base_url}/models/#{model}:streamGenerateContent"
  end

  defp build_headers(api_key) do
    [{"x-goog-api-key", api_key} | HTTP.json_headers()]
  end
end
