# Exclude tests that require real LLM connections by default
# Run them with: mix test --include llm
ExUnit.configure(exclude: [:llm])

ExUnit.start()
