defmodule Nous.Providers.Custom do
  @moduledoc """
  Custom provider for any OpenAI-compatible endpoint.

  The `custom:` provider is the recommended way to connect to any server
  implementing the OpenAI Chat Completions API. It supports flexible configuration
  via options, environment variables, or application config.

  ## Configuration

  The custom provider looks up configuration in the following precedence:

  1. **Direct options** (highest priority):
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

  3. **Application config**:
     ```elixir
     # config/config.exs
     config :nous, :custom,
       base_url: "https://api.example.com/v1",
       api_key: "sk-..."
     ```

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `base_url` | `String.t()` | From env/config | API endpoint URL (required if not in env) |
  | `api_key` | `String.t()` | From env/config | Authentication token (optional for local servers) |
  | `organization` | `String.t()` | `nil` | Organization ID (some providers) |
  | `timeout` | `non_neg_integer()` | `120000` | Request timeout in milliseconds |

  ## Examples

  ### Groq

  ```elixir
  # Via environment variables:
  # export CUSTOM_BASE_URL="https://api.groq.com/openai/v1"
  # export CUSTOM_API_KEY="gsk_..."
  agent = Nous.new("custom:llama-3.1-70b")

  # With explicit options:
  agent = Nous.new("custom:llama-3.1-70b",
    base_url: "https://api.groq.com/openai/v1",
    api_key: System.get_env("GROQ_API_KEY")
  )
  ```

  ### Together AI

  ```elixir
  agent = Nous.new("custom:meta-llama/Llama-3-70b",
    base_url: "https://api.together.xyz/v1",
    api_key: System.get_env("TOGETHER_API_KEY")
  )
  ```

  ### OpenRouter

  ```elixir
  agent = Nous.new("custom:anthropic/claude-3.5-sonnet",
    base_url: "https://openrouter.ai/api/v1",
    api_key: System.get_env("OPENROUTER_API_KEY")
  )
  ```

  ### Local Servers (LM Studio, Ollama, etc.)

  ```elixir
  # LM Studio (no API key needed)
  agent = Nous.new("custom:qwen3",
    base_url: "http://localhost:1234/v1"
  )

  # Ollama (no API key needed)
  agent = Nous.new("custom:llama2",
    base_url: "http://localhost:11434/v1"
  )
  ```

  ### Custom Base URL with Built-in Providers

  You can also use `base_url` to point built-in providers to custom endpoints:

  ```elixir
  # Use OpenAI provider format with custom endpoint
  agent = Nous.new("openai:gpt-4",
    base_url: "https://my-proxy.example.com/v1"
  )
  ```

  ## Backward Compatibility

  The legacy `openai_compatible:` prefix still works and is equivalent to `custom:`:

  ```elixir
  # Legacy (still works)
  agent = Nous.new("openai_compatible:my-model", base_url: "...")

  # Recommended
  agent = Nous.new("custom:my-model", base_url: "...")
  ```

  ## Direct Provider Usage

  For low-level access without the agent:

  ```elixir
  {:ok, response} = Nous.Providers.Custom.chat(%{
    "model" => "llama-3.1-70b",
    "messages" => [%{"role" => "user", "content" => "Hello"}]
  },
    base_url: "https://api.groq.com/openai/v1",
    api_key: System.get_env("GROQ_API_KEY")
  )
  ```

  See `Nous.Providers.OpenAICompatible` for implementation details.
  """

  use Nous.Provider,
    id: :custom,
    default_base_url: "",
    default_env_key: "CUSTOM_API_KEY"

  alias Nous.Providers.HTTP

  @default_timeout 120_000
  @streaming_timeout 300_000

  @impl Nous.Provider
  def chat(params, opts \\ []) do
    url = "#{get_base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    HTTP.post(url, params, headers, timeout: timeout)
  end

  @impl Nous.Provider
  def chat_stream(params, opts \\ []) do
    url = "#{get_base_url(opts)}/chat/completions"
    headers = build_headers(api_key(opts), opts)
    timeout = Keyword.get(opts, :timeout, @streaming_timeout)
    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    params = Map.put(params, "stream", true)

    HTTP.stream(url, params, headers, timeout: timeout, finch_name: finch_name)
  end

  # Get base URL from opts, env var, or config (required for custom provider)
  defp get_base_url(opts) do
    base =
      Keyword.get(opts, :base_url) ||
        System.get_env("CUSTOM_BASE_URL") ||
        get_in(Application.get_env(:nous, :custom, []), [:base_url])

    if is_nil(base) or base == "" do
      raise ArgumentError, """
      Custom provider requires a base_url.

      Set one of:
      1. Option: Nous.new("custom:model", base_url: "http://...")
      2. Environment: export CUSTOM_BASE_URL="http://..."
      3. Config: config :nous, :custom, base_url: "http://..."
      """
    end

    base
  end

  # Build headers for the request
  defp build_headers(api_key, opts) do
    headers = [
      {"content-type", "application/json"}
    ]

    # Add authorization if API key provided (skip for "not-needed" sentinel)
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
