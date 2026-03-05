#!/usr/bin/env elixir

# Nous AI - LlamaCpp (Local NIF-based Inference)
# Run GGUF models directly in-process via llama.cpp NIFs

IO.puts("=== Nous AI - LlamaCpp (Local NIF) ===\n")

# ============================================================================
# Setup
# ============================================================================

IO.puts("""
--- Setup ---

1. Add {:llama_cpp_ex, "~> 0.5.0"} to your mix.exs deps
2. Download a GGUF model (e.g., from HuggingFace)
3. Set LLAMACPP_MODEL_PATH or edit the path below
4. Run: mix run examples/providers/llamacpp.exs
""")

# Initialize and load model
model_path = System.get_env("LLAMACPP_MODEL_PATH") || "model.gguf"
IO.puts("Loading model from #{model_path}...")

:ok = LlamaCppEx.init()

{:ok, llm} =
  LlamaCppEx.load_model(model_path,
    n_gpu_layers: -1,
    n_ctx: 4096
  )

IO.puts("Model loaded successfully!\n")

# ============================================================================
# Basic Usage (with thinking disabled)
# ============================================================================

IO.puts("--- Basic Chat ---")

# Thinking models (Qwen3, etc.) emit <think>...</think> tags by default.
# Set enable_thinking: false to get clean output.
agent =
  Nous.new("llamacpp:local",
    llamacpp_model: llm,
    instructions: "You are helpful and concise.",
    model_settings: %{enable_thinking: false}
  )

case Nous.run(agent, "What is 2 + 2?") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")

# ============================================================================
# Simple Text API
# ============================================================================

IO.puts("--- Simple Text Generation ---")

case Nous.generate_text("llamacpp:local", "What is Elixir?",
       llamacpp_model: llm,
       enable_thinking: false
     ) do
  {:ok, text} ->
    IO.puts("Response: #{text}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")

# ============================================================================
# Streaming
# ============================================================================

IO.puts("--- Streaming ---")

case Nous.stream_text("llamacpp:local", "Write a haiku about programming.",
       llamacpp_model: llm,
       enable_thinking: false
     ) do
  {:ok, stream} ->
    stream |> Stream.each(&IO.write/1) |> Stream.run()
    IO.puts("")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")

# ============================================================================
# Thinking Models
# ============================================================================

IO.puts("--- Thinking vs Non-Thinking ---")

IO.puts("With thinking (default for Qwen3, DeepSeek, etc.):")

case Nous.generate_text("llamacpp:local", "What is 1+1?",
       llamacpp_model: llm,
       max_tokens: 100
     ) do
  {:ok, text} -> IO.puts("  #{String.slice(text, 0, 120)}...")
  {:error, e} -> IO.puts("  Error: #{inspect(e)}")
end

IO.puts("\nWithout thinking (enable_thinking: false):")

case Nous.generate_text("llamacpp:local", "What is 1+1?",
       llamacpp_model: llm,
       max_tokens: 100,
       enable_thinking: false
     ) do
  {:ok, text} -> IO.puts("  #{text}")
  {:error, e} -> IO.puts("  Error: #{inspect(e)}")
end

IO.puts("")

# ============================================================================
# Structured Output
# ============================================================================

IO.puts("--- Structured Output (JSON Schema) ---")

schema = %{
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string"},
    "age" => %{"type" => "integer"},
    "hobbies" => %{"type" => "array", "items" => %{"type" => "string"}}
  },
  "required" => ["name", "age", "hobbies"]
}

structured_agent =
  Nous.new("llamacpp:local",
    llamacpp_model: llm,
    instructions: "You respond only with valid JSON matching the schema.",
    model_settings: %{json_schema: schema, enable_thinking: false}
  )

case Nous.run(structured_agent, "Describe a fictional character.") do
  {:ok, result} ->
    IO.puts("Structured: #{result.output}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")

# ============================================================================
# Model Settings
# ============================================================================

IO.puts("--- Model Settings ---")

IO.puts("""
Settings mapping (Nous -> LlamaCppEx):

  temperature:     -> temp          (sampling temperature)
  max_tokens:      -> max_tokens    (max tokens to generate)
  top_p:           -> top_p         (nucleus sampling)
  json_schema:     -> json_schema   (constrained JSON output)
  enable_thinking: -> enable_thinking (thinking token control)
""")

configured_agent =
  Nous.new("llamacpp:local",
    llamacpp_model: llm,
    instructions: "Be creative and expressive.",
    model_settings: %{
      temperature: 0.9,
      max_tokens: 200,
      top_p: 0.95,
      enable_thinking: false
    }
  )

case Nous.run(configured_agent, "Tell me a short story in one paragraph.") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")

# ============================================================================
# Best Practices
# ============================================================================

IO.puts("""
--- Best Practices ---

1. Load the model once at app start:
   - Use Application.start or a supervisor
   - Store the reference in a GenServer or persistent_term

2. GPU acceleration:
   - Use n_gpu_layers: -1 to offload all layers to GPU
   - Set n_gpu_layers: 0 for CPU-only

3. Context size:
   - Default is 512. Set n_ctx: 4096 (or higher) for longer conversations
   - More context = more memory usage

4. Thinking models:
   - Qwen3, DeepSeek R1, etc. emit <think> tags by default
   - Set enable_thinking: false in model_settings for clean output
   - Keep thinking enabled for complex reasoning tasks

5. When to use LlamaCpp vs HTTP providers:
   - LlamaCpp: Lowest latency, no network overhead, full control
   - Ollama/LMStudio: Easier model management, multiple models
   - Cloud: Largest models, no local hardware needed

6. Memory management:
   - GGUF models stay loaded in memory
   - Unload when done if running multiple models
""")
