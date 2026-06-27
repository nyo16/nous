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

  # The custom provider accepts a user-supplied base URL, so `chat/2` and
  # `chat_stream/2` are injected by `Nous.Provider` with the `:required` base-URL
  # strategy: the URL is mandatory and validated through UrlGuard for SSRF
  # protection (set `allow_private_hosts: true` in opts or app config for local
  # dev). `bearer_org` headers support the optional `openai-organization` header.
  use Nous.Provider,
    id: :custom,
    display_name: "Custom provider",
    default_base_url: "",
    default_env_key: "CUSTOM_API_KEY",
    chat: [base_url: :required, headers: :bearer_org, timeout: 120_000, stream_timeout: 300_000]
end
