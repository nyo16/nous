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

  Unlike OpenAI/Anthropic which use headers, Gemini uses query parameter auth:
  `?key=API_KEY`

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

  # Override to convert from generic format to Gemini's format
  defp build_request_params(model, messages, settings) do
    merged_settings = Map.merge(model.default_settings, settings)

    # Convert messages to Gemini format: {system_prompt, contents}
    {system_prompt, contents} = Nous.Messages.to_provider_format(messages, :gemini)

    params = %{"model" => model.model, "contents" => contents}

    params =
      if system_prompt do
        Map.put(params, "systemInstruction", %{"parts" => [%{"text" => system_prompt}]})
      else
        params
      end

    # Map generic settings to Gemini's generationConfig
    generation_config =
      %{}
      |> maybe_put("temperature", merged_settings[:temperature])
      |> maybe_put("maxOutputTokens", merged_settings[:max_tokens])
      |> maybe_put("topP", merged_settings[:top_p])
      |> maybe_put("topK", merged_settings[:top_k])
      |> maybe_put("seed", merged_settings[:seed])
      |> maybe_put("candidateCount", merged_settings[:candidate_count])
      |> maybe_put("presencePenalty", merged_settings[:presence_penalty])
      |> maybe_put("frequencyPenalty", merged_settings[:frequency_penalty])
      |> maybe_put("responseModalities", merged_settings[:response_modalities])
      |> maybe_put("stopSequences", merged_settings[:stop_sequences] || merged_settings[:stop])
      |> maybe_put(
        "thinkingConfig",
        Nous.Messages.Gemini.normalize_thinking_config(merged_settings[:thinking_config])
      )
      |> Map.merge(Nous.Messages.Gemini.json_config_for_settings(merged_settings))

    # Merge any explicit generationConfig from settings
    generation_config =
      Map.merge(generation_config, merged_settings[:generationConfig] || %{})

    params =
      if map_size(generation_config) > 0 do
        Map.put(params, "generationConfig", generation_config)
      else
        params
      end

    params =
      params
      |> maybe_put(
        "tools",
        Nous.Messages.Gemini.build_tools(
          merged_settings[:tools] || [],
          merged_settings[:native_tools]
        )
      )
      |> maybe_put(
        "safetySettings",
        Nous.Messages.Gemini.normalize_safety_settings(merged_settings[:safety_settings])
      )
      |> maybe_put("toolConfig", resolve_tool_config(merged_settings))
      |> maybe_put("cachedContent", merged_settings[:cached_content])

    maybe_merge_extra_body(params, merged_settings[:extra_body])
  end

  defp resolve_tool_config(settings) do
    settings[:tool_config] ||
      Nous.Messages.Gemini.normalize_tool_choice(settings[:tool_choice])
  end

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || "gemini-2.0-flash-exp"
    api_key = api_key(opts)

    url = build_url(base_url(opts), model, api_key, :generate)
    headers = build_headers()
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Remove model from params (it's in the URL)
    body = params |> Map.delete("model") |> Map.delete(:model)

    HTTP.post(url, body, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    model = Map.get(params, "model") || Map.get(params, :model) || "gemini-2.0-flash-exp"
    api_key = api_key(opts)

    url = build_url(base_url(opts), model, api_key, :stream)
    headers = build_headers()
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

  # Build URL with model and API key in query params
  defp build_url(base_url, model, api_key, :generate) do
    "#{base_url}/models/#{model}:generateContent?key=#{api_key}"
  end

  defp build_url(base_url, model, api_key, :stream) do
    "#{base_url}/models/#{model}:streamGenerateContent?key=#{api_key}"
  end

  # Auth header is omitted because the API key lives in the URL query string.
  defp build_headers, do: HTTP.json_headers()
end
