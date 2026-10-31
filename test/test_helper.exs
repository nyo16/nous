# Exclude tests that require real LLM connections by default
# Run them with: mix test --include llm
#
# :llama — local llama.cpp NIF smoke tests; require a GGUF model on disk
# (NOUS_LLAMACPP_TEST_MODEL / NOUS_LLAMACPP_TEST_EMBED_MODEL). Run with:
#   NOUS_LLAMACPP_TEST_MODEL=~/Downloads/model.gguf mix test --only llama
#
# :decision_model — opt-in decision-model accuracy evals (DecisionGuard corpus);
# require NOUS_DECISION_TEST_MODEL. Run with:
#   NOUS_DECISION_TEST_MODEL=~/Downloads/clef.gguf mix test --only decision_model
ExUnit.configure(exclude: [:llm, :llama, :decision_model])

ExUnit.start()
