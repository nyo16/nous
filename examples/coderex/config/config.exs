import Config

# Configure Yggdrasil API keys from environment variables
config :yggdrasil,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY")
