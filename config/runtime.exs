import Config

# Runtime configuration (loads at runtime, can use System.get_env)

# Note: gemini_ex configuration commented out as it's not actively used yet
# Uncomment when you need to use Google Gemini models:
# config :gemini,
#   api_key: System.get_env("GOOGLE_AI_API_KEY") || System.get_env("GEMINI_API_KEY")

if config_env() == :prod do
  config :nous,
    openai_api_key: System.get_env("OPENAI_API_KEY"),
    anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
    google_ai_api_key: System.get_env("GOOGLE_AI_API_KEY"),
    groq_api_key: System.get_env("GROQ_API_KEY"),
    openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
    together_api_key: System.get_env("TOGETHER_API_KEY")
end
