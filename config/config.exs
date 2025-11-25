import Config

config :yggdrasil,
  # API Keys (from environment variables)
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  google_ai_api_key: System.get_env("GOOGLE_AI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  together_api_key: System.get_env("TOGETHER_API_KEY"),
  brave_api_key: System.get_env("BRAVE_API_KEY"),
  # Finch pool name
  finch: Yggdrasil.Finch,
  # Timeouts
  default_timeout: 60_000,
  stream_timeout: 120_000,
  # Telemetry
  enable_telemetry: true

# Note: gemini_ex configuration commented out as it's not actively used yet
# Uncomment when you need to use Google Gemini models:
# config :gemini,
#   api_key: System.get_env("GOOGLE_AI_API_KEY") || System.get_env("GEMINI_API_KEY")

# Import environment specific config
import_config "#{config_env()}.exs"
