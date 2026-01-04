import Config

config :nous,
  # API Keys (from environment variables)
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  google_ai_api_key: System.get_env("GOOGLE_AI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  together_api_key: System.get_env("TOGETHER_API_KEY"),
  mistral_api_key: System.get_env("MISTRAL_API_KEY"),
  brave_api_key: System.get_env("BRAVE_API_KEY"),
  # Finch pool name
  finch: Nous.Finch,
  # Timeouts
  default_timeout: 60_000,
  stream_timeout: 120_000,
  # Telemetry
  enable_telemetry: true,
  # Observability (for nous_ui integration) - disabled by default
  observability: [
    enabled: false,
    endpoint: "http://localhost:4000/api/telemetry",
    batch_size: 100,
    batch_timeout: 5_000,
    concurrency: 2,
    max_demand: 50,
    headers: []
  ]

# Note: gemini_ex configuration commented out as it's not actively used yet
# Uncomment when you need to use Google Gemini models:
# config :gemini,
#   api_key: System.get_env("GOOGLE_AI_API_KEY") || System.get_env("GEMINI_API_KEY")

# Import environment specific config
import_config "#{config_env()}.exs"
