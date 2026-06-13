# Exclude tests that require real LLM connections by default
# Run them with: mix test --include llm
#
# :llama — local llama.cpp NIF smoke tests; require a GGUF model on disk
# (NOUS_LLAMACPP_TEST_MODEL / NOUS_LLAMACPP_TEST_EMBED_MODEL). Run with:
#   NOUS_LLAMACPP_TEST_MODEL=~/Downloads/model.gguf mix test --only llama
ExUnit.configure(exclude: [:llm, :llama])

ExUnit.start()
