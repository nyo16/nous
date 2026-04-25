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
  """

  use Nous.Provider,
    id: :gemini,
    default_base_url: "https://generativelanguage.googleapis.com/v1beta",
    default_env_key: "GOOGLE_AI_API_KEY"

  alias Nous.Providers.HTTP

  @default_timeout 60_000
  @streaming_timeout 120_000

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
      |> maybe_put("stopSequences", merged_settings[:stop_sequences] || merged_settings[:stop])

    # Merge any explicit generationConfig from settings
    generation_config =
      Map.merge(generation_config, merged_settings[:generationConfig] || %{})

    params =
      if map_size(generation_config) > 0 do
        Map.put(params, "generationConfig", generation_config)
      else
        params
      end

    maybe_merge_extra_body(params, merged_settings[:extra_body])
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
    timeout = Keyword.get(opts, :timeout, @streaming_timeout)
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

  # Build headers (no auth header - it's in the URL)
  defp build_headers do
    [{"content-type", "application/json"}]
  end
end
