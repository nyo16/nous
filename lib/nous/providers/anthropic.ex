defmodule Nous.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude provider implementation.

  Supports Claude models via the Anthropic Messages API.

  ## Usage

      # Basic usage
      {:ok, response} = Nous.Providers.Anthropic.chat(%{
        model: "claude-sonnet-4-20250514",
        max_tokens: 1024,
        messages: [%{"role" => "user", "content" => "Hello"}]
      })

      # With system prompt
      {:ok, response} = Nous.Providers.Anthropic.chat(%{
        model: "claude-sonnet-4-20250514",
        max_tokens: 1024,
        system: "You are a helpful assistant.",
        messages: [%{"role" => "user", "content" => "Hello"}]
      })

      # With long context beta
      {:ok, response} = Nous.Providers.Anthropic.chat(
        params,
        enable_long_context: true
      )

      # Streaming
      {:ok, stream} = Nous.Providers.Anthropic.chat_stream(params)
      Enum.each(stream, fn event -> IO.inspect(event) end)

  ## Configuration

      # In config.exs
      config :nous, :anthropic,
        api_key: "sk-ant-...",
        base_url: "https://api.anthropic.com"  # optional
  """

  use Nous.Provider,
    id: :anthropic,
    default_base_url: "https://api.anthropic.com",
    default_env_key: "ANTHROPIC_API_KEY"

  alias Nous.Providers.HTTP

  @api_version "2023-06-01"
  @long_context_beta "context-1m-2025-08-07"
  @default_timeout 180_000
  @streaming_timeout 300_000

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    url = "#{base_url(opts)}/v1/messages"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    HTTP.post(url, params, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    url = "#{base_url(opts)}/v1/messages"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @streaming_timeout)
    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    # Ensure stream is enabled
    params = Map.put(params, "stream", true)

    HTTP.stream(url, params, headers, timeout: timeout, finch_name: finch_name)
  end

  defp build_headers(api_key, opts) do
    HTTP.json_headers() ++
      [{"anthropic-version", @api_version}] ++
      HTTP.api_key_header(api_key, "x-api-key") ++
      anthropic_beta_headers(opts)
  end

  # Collect long-context and custom beta features into the single
  # `anthropic-beta` header. Anthropic accepts a comma-separated list per
  # header, but emitting one header per beta is just as valid; we use
  # separate headers so each beta is independently inspectable in logs.
  defp anthropic_beta_headers(opts) do
    long_context =
      if Keyword.get(opts, :enable_long_context, false),
        do: [{"anthropic-beta", @long_context_beta}],
        else: []

    custom =
      case Keyword.get(opts, :beta) do
        nil -> []
        beta when is_binary(beta) -> [{"anthropic-beta", beta}]
        betas when is_list(betas) -> [{"anthropic-beta", Enum.join(betas, ",")}]
      end

    long_context ++ custom
  end
end
