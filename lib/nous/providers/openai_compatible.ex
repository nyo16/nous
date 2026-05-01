defmodule Nous.Providers.OpenAICompatible do
  @moduledoc """
  Generic OpenAI-compatible provider implementation.

  > **Note**: This module implements the underlying HTTP API for OpenAI-compatible
  > endpoints. For normal usage, prefer the `custom:` model prefix which routes
  > through `Nous.Providers.Custom` with better configuration support.

  Works with any server that implements the OpenAI Chat Completions API:
  - Groq (api.groq.com)
  - Together (api.together.xyz)
  - OpenRouter (openrouter.ai)
  - LM Studio (localhost)
  - Ollama (localhost)
  - vLLM (localhost)
  - SGLang (localhost)
  - Mistral (api.mistral.ai)
  - Any other OpenAI-compatible endpoint

  For OpenAI-specific features (Responses API, Assistants, etc.), use `Nous.Providers.OpenAI`.

  ## Configuration

  Configuration is looked up in the following precedence (highest to lowest):

  1. **Direct options** passed to functions or `Nous.new/2`:
     ```elixir
     Nous.new("custom:my-model",
       base_url: "https://api.example.com/v1",
       api_key: "sk-..."
     )
     ```

  2. **Environment variables**:
     ```bash
     export CUSTOM_BASE_URL="https://api.example.com/v1"
     export CUSTOM_API_KEY="sk-..."
     ```

  3. **Application config** (in `config/config.exs`):
     ```elixir
     config :nous, :custom,
       base_url: "https://api.example.com/v1",
       api_key: "sk-..."
     ```

  4. **Defaults** (used by this module directly):
     - `base_url`: `"https://api.openai.com/v1"`
     - `api_key`: From `OPENAI_API_KEY` env var

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `base_url` | `String.t()` | `"https://api.openai.com/v1"` | API endpoint URL |
  | `api_key` | `String.t()` | `nil` | Authentication token |
  | `organization` | `String.t()` | `nil` | OpenAI organization ID |
  | `timeout` | `non_neg_integer()` | `60000` | Request timeout (ms) |

  ## Usage

  ### With the `custom:` prefix (Recommended)

  Use this for any OpenAI-compatible endpoint:

      # Groq
      agent = Nous.new("custom:llama-3.1-70b",
        base_url: "https://api.groq.com/openai/v1",
        api_key: System.get_env("GROQ_API_KEY")
      )

      # Together AI
      agent = Nous.new("custom:meta-llama/Llama-3-70b",
        base_url: "https://api.together.xyz/v1",
        api_key: System.get_env("TOGETHER_API_KEY")
      )

      # OpenRouter
      agent = Nous.new("custom:anthropic/claude-3.5-sonnet",
        base_url: "https://openrouter.ai/api/v1",
        api_key: System.get_env("OPENROUTER_API_KEY")
      )

      # LM Studio (local)
      agent = Nous.new("custom:qwen3",
        base_url: "http://localhost:1234/v1"
      )

      # Using environment variables
      # export CUSTOM_BASE_URL="http://localhost:1234/v1"
      # export CUSTOM_API_KEY="not-needed"
      agent = Nous.new("custom:my-model")

  ### Direct Provider Usage (Low-level)

  For direct API access without the agent:

      # Using with Groq
      {:ok, response} = Nous.Providers.OpenAICompatible.chat(
        %{model: "llama-3.1-70b", messages: messages},
        base_url: "https://api.groq.com/openai/v1",
        api_key: System.get_env("GROQ_API_KEY")
      )

      # Using with local LM Studio
      {:ok, response} = Nous.Providers.OpenAICompatible.chat(
        %{model: "qwen2", messages: messages},
        base_url: "http://localhost:1234/v1"
      )

      # Streaming
      {:ok, stream} = Nous.Providers.OpenAICompatible.chat_stream(params, opts)
      Enum.each(stream, fn event -> IO.inspect(event) end)

  ## Backward Compatibility

  The legacy `openai_compatible:` prefix still works and is equivalent to `custom:`:

      # Legacy (still works)
      agent = Nous.new("openai_compatible:my-model", base_url: "...")

      # Recommended
      agent = Nous.new("custom:my-model", base_url: "...")

  See `Nous.Providers.Custom` for the dedicated custom provider implementation.
  """

  use Nous.Provider,
    id: :openai_compatible,
    default_base_url: "https://api.openai.com/v1",
    default_env_key: "OPENAI_API_KEY"

  alias Nous.Providers.HTTP

  @default_timeout 180_000
  @streaming_timeout 300_000

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    url = "#{base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    HTTP.post(url, params, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    url = "#{base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @streaming_timeout)
    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    # Ensure stream is enabled
    params = Map.put(params, "stream", true)

    HTTP.stream(url, params, headers, timeout: timeout, finch_name: finch_name)
  end

  # Build headers for the request
  defp build_headers(api_key, opts) do
    headers = [
      {"content-type", "application/json"}
    ]

    # Add authorization if API key provided
    headers =
      if api_key && api_key != "" && api_key != "not-needed" do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    # Add organization header if provided
    case Keyword.get(opts, :organization) do
      nil -> headers
      org -> [{"openai-organization", org} | headers]
    end
  end
end
