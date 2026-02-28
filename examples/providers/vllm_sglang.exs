#!/usr/bin/env elixir

# Nous AI - vLLM & SGLang (High-Performance Local Inference)
# OpenAI-compatible servers optimized for production throughput

IO.puts("=== Nous AI - vLLM & SGLang ===\n")

# ============================================================================
# Setup
# ============================================================================

IO.puts("""
--- Setup ---

vLLM:
  pip install vllm
  vllm serve meta-llama/Llama-3.1-8B-Instruct
  # Default: http://localhost:8000/v1

SGLang:
  pip install sglang[all]
  python -m sglang.launch_server --model meta-llama/Llama-3.1-8B-Instruct
  # Default: http://localhost:30000/v1

Environment variables (optional):
  export VLLM_BASE_URL="http://localhost:8000/v1"
  export SGLANG_BASE_URL="http://localhost:30000/v1"
  export VLLM_API_KEY="token-abc123"    # only if auth enabled
  export SGLANG_API_KEY="token-abc123"  # only if auth enabled
""")

# ============================================================================
# Part 1: vLLM
# ============================================================================

IO.puts("--- vLLM: Basic Usage ---")

vllm_agent =
  Nous.new("vllm:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "You are a helpful, concise assistant."
  )

IO.puts("Created vLLM agent")

case Nous.run(vllm_agent, "What is the BEAM virtual machine? One sentence.") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
    IO.puts("Make sure vLLM is running: vllm serve meta-llama/Llama-3.1-8B-Instruct")
end

IO.puts("")

# ============================================================================
# vLLM: Model Settings
# ============================================================================

IO.puts("--- vLLM: Model Settings ---")

vllm_configured =
  Nous.new("vllm:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "Be concise and precise.",
    model_settings: %{
      temperature: 0.3,
      max_tokens: 500,
      top_p: 0.9,
      # vLLM-specific parameters
      # Generate 3 candidates, return the best
      best_of: 3,
      # Clean output
      skip_special_tokens: true
    }
  )

case Nous.run(vllm_configured, "Explain pattern matching in Elixir in 2 sentences.") do
  {:ok, result} -> IO.puts("Response: #{result.output}")
  {:error, _} -> IO.puts("(Skipped - vLLM not running)")
end

IO.puts("")

# ============================================================================
# vLLM: Streaming
# ============================================================================

IO.puts("--- vLLM: Streaming ---")

case Nous.run_stream(vllm_agent, "List 3 advantages of vLLM over naive inference.") do
  {:ok, stream} ->
    stream
    |> Enum.each(fn
      {:text_delta, text} -> IO.write(text)
      {:finish, _} -> IO.puts("")
      _ -> :ok
    end)

  {:error, _} ->
    IO.puts("(Skipped - vLLM not running)")
end

IO.puts("")

# ============================================================================
# vLLM: Tools (Function Calling)
# ============================================================================

IO.puts("--- vLLM: Tools ---")

get_weather = fn _ctx, %{"city" => city} ->
  forecasts = %{
    "San Francisco" => %{temp: 62, condition: "foggy"},
    "Tokyo" => %{temp: 75, condition: "sunny"},
    "London" => %{temp: 55, condition: "rainy"}
  }

  Map.get(forecasts, city, %{temp: 70, condition: "unknown"})
end

vllm_tool_agent =
  Nous.new("vllm:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "Use tools when asked about weather.",
    tools: [get_weather]
  )

case Nous.run(vllm_tool_agent, "What's the weather in Tokyo?") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tool calls: #{result.usage.tool_calls}")

  {:error, _} ->
    IO.puts("(Skipped - vLLM not running)")
end

IO.puts("")

# ============================================================================
# vLLM: Guided Decoding (Constrained Generation)
# ============================================================================

IO.puts("--- vLLM: Guided Decoding ---")
IO.puts("vLLM supports constrained generation via guided decoding:\n")

# Guided JSON — force output to match a JSON schema
IO.puts("1. guided_json — Constrain output to a JSON schema:")

json_agent =
  Nous.new("vllm:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "Extract structured data from text.",
    model_settings: %{
      guided_json: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"},
          "city" => %{"type" => "string"}
        },
        "required" => ["name", "age", "city"]
      }
    }
  )

case Nous.run(json_agent, "Alice is 30 years old and lives in Portland.") do
  {:ok, result} -> IO.puts("   #{result.output}")
  {:error, _} -> IO.puts("   (Skipped - vLLM not running)")
end

# Guided regex — constrain output to match a pattern
IO.puts("\n2. guided_regex — Constrain output to a regex pattern:")

regex_agent =
  Nous.new("vllm:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "Output only the requested format.",
    model_settings: %{
      guided_regex: ~S"\d{4}-\d{2}-\d{2}"
    }
  )

case Nous.run(regex_agent, "What is today's date? Output only the date.") do
  {:ok, result} -> IO.puts("   #{result.output}")
  {:error, _} -> IO.puts("   (Skipped - vLLM not running)")
end

# Guided choice — constrain to one of N options
IO.puts("\n3. guided_choice — Constrain to one of several options:")

choice_agent =
  Nous.new("vllm:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "Classify the sentiment of the text.",
    model_settings: %{
      guided_choice: ["positive", "negative", "neutral"]
    }
  )

case Nous.run(choice_agent, "I absolutely love this product! Best purchase ever.") do
  {:ok, result} -> IO.puts("   #{result.output}")
  {:error, _} -> IO.puts("   (Skipped - vLLM not running)")
end

IO.puts("")

# ============================================================================
# Part 2: SGLang
# ============================================================================

IO.puts("--- SGLang: Basic Usage ---")

sglang_agent =
  Nous.new("sglang:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "You are a helpful, concise assistant."
  )

IO.puts("Created SGLang agent")

case Nous.run(sglang_agent, "What is RadixAttention? One sentence.") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
    IO.puts("Make sure SGLang is running:")
    IO.puts("  python -m sglang.launch_server --model meta-llama/Llama-3.1-8B-Instruct")
end

IO.puts("")

# ============================================================================
# SGLang: Constrained Decoding
# ============================================================================

IO.puts("--- SGLang: Constrained Decoding ---")
IO.puts("SGLang has native constrained decoding via json_schema and regex:\n")

# JSON schema constraint
IO.puts("1. json_schema — Force JSON schema compliance:")

sglang_json =
  Nous.new("sglang:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "Extract structured data from text.",
    model_settings: %{
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "language" => %{"type" => "string"},
          "paradigm" => %{"type" => "string"},
          "typed" => %{"type" => "boolean"}
        },
        "required" => ["language", "paradigm", "typed"]
      }
    }
  )

case Nous.run(sglang_json, "Elixir is a dynamic, functional language for the BEAM VM.") do
  {:ok, result} -> IO.puts("   #{result.output}")
  {:error, _} -> IO.puts("   (Skipped - SGLang not running)")
end

# Regex constraint
IO.puts("\n2. regex — Constrain output to a regex pattern:")

sglang_regex =
  Nous.new("sglang:meta-llama/Llama-3.1-8B-Instruct",
    instructions: "Output only the requested format.",
    model_settings: %{
      regex: ~S"[A-Z][a-z]+ \d{1,2}, \d{4}"
    }
  )

case Nous.run(sglang_regex, "When was Elixir first released? Output only the date.") do
  {:ok, result} -> IO.puts("   #{result.output}")
  {:error, _} -> IO.puts("   (Skipped - SGLang not running)")
end

IO.puts("")

# ============================================================================
# SGLang: Streaming
# ============================================================================

IO.puts("--- SGLang: Streaming ---")

case Nous.run_stream(sglang_agent, "List 3 features of SGLang in bullet points.") do
  {:ok, stream} ->
    stream
    |> Enum.each(fn
      {:text_delta, text} -> IO.write(text)
      {:finish, _} -> IO.puts("")
      _ -> :ok
    end)

  {:error, _} ->
    IO.puts("(Skipped - SGLang not running)")
end

IO.puts("")

# ============================================================================
# Custom Base URL / Remote Deployment
# ============================================================================

IO.puts("--- Remote / Custom Deployment ---")

IO.puts("""
Both vLLM and SGLang can serve behind a reverse proxy or on a remote host:

  # vLLM on a remote GPU server
  agent = Nous.new("vllm:meta-llama/Llama-3.1-70B-Instruct",
    base_url: "https://gpu-server.example.com/v1",
    api_key: "my-secret-key"
  )

  # SGLang on a different port
  agent = Nous.new("sglang:Qwen/Qwen2.5-7B-Instruct",
    base_url: "http://localhost:9000/v1"
  )

  # Any OpenAI-compatible server (Together, Anyscale, etc.)
  agent = Nous.new("openai_compatible:meta-llama/Llama-3.1-8B-Instruct",
    base_url: "https://api.together.xyz/v1",
    api_key: System.get_env("TOGETHER_API_KEY")
  )
""")

# ============================================================================
# Comparison & Best Practices
# ============================================================================

IO.puts("""
--- vLLM vs SGLang: When to Use Which ---

vLLM:
  - Best for: High-throughput batch inference
  - Key features: PagedAttention, continuous batching, tensor parallelism
  - Guided decoding: guided_json, guided_regex, guided_grammar, guided_choice
  - Multi-GPU: Automatic tensor parallelism (--tensor-parallel-size N)
  - Start: vllm serve <model>

SGLang:
  - Best for: Structured generation, multi-turn with KV cache reuse
  - Key features: RadixAttention, constrained decoding, speculative decoding
  - Guided decoding: json_schema, regex (native, very fast)
  - Multi-GPU: Automatic tensor parallelism (--tp N)
  - Start: python -m sglang.launch_server --model <model>

Both:
  - OpenAI-compatible API (/v1/chat/completions)
  - Streaming support
  - Tool/function calling (model-dependent)
  - No API key required for local usage

Model name format:
  vllm:<org>/<model>       → http://localhost:8000/v1
  sglang:<org>/<model>     → http://localhost:30000/v1
  openai_compatible:<model> → any OpenAI-compatible endpoint
""")
