#!/usr/bin/env elixir

# Nous AI - One-Shot LLM API (no agent)
# The bare `Nous.LLM` module: direct model calls without the agent machinery.
#
# Use this when you just want text in / text out and don't need instructions,
# memory, history, or the agent run loop.
#
# Default model below is "lmstudio:qwen3" (a local LM Studio server), but any
# "provider:model" string works, e.g.:
#   "anthropic:claude-haiku-4-5"
#   "openai:gpt-4"
#   "ollama:llama3"
# You can also pass a %Nous.Model{} struct directly (see section 4).

model = "lmstudio:qwen3"

IO.puts("=== Nous AI - One-Shot LLM API ===\n")

# ============================================================================
# 1. generate_text/3 - returns {:ok, text} | {:error, reason}
# ============================================================================

IO.puts("--- 1. generate_text/3 (tuple result) ---")
IO.puts("Prompt: What is 2 + 2? Answer with just the number.\n")

case Nous.LLM.generate_text(model, "What is 2 + 2? Answer with just the number.") do
  {:ok, text} ->
    IO.puts("Answer: #{text}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("")

# generate_text/3 also accepts options. The binary model-string clause routes
# :base_url / :api_key / :receive_timeout into Model.parse, while
# :system / :temperature / :max_tokens / :top_p become the request settings.
IO.puts("--- generate_text/3 with options ---")
IO.puts("Prompt: Say hello. (as a pirate, temp 0.7)\n")

case Nous.LLM.generate_text(model, "Say hello.",
       system: "You are a pirate. Keep it to one short sentence.",
       temperature: 0.7,
       max_tokens: 100,
       # HTTP receive timeout in ms; local/reasoning models can be slow.
       receive_timeout: 120_000
     ) do
  {:ok, text} -> IO.puts("Answer: #{text}")
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end

IO.puts("")

# ============================================================================
# 2. generate_text!/3 - bang variant, returns the string or raises
# ============================================================================

IO.puts("--- 2. generate_text!/3 (bang, raises on error) ---")
IO.puts("Prompt: Name one primary color. One word.\n")

# The bang variant returns the string directly or RAISES. In a script you'd
# normally let it crash; here we rescue so the demo keeps running offline.
try do
  text = Nous.LLM.generate_text!(model, "Name one primary color. One word.")
  IO.puts("Answer: #{text}")
rescue
  e in [Nous.Errors.ModelError, Nous.Errors.ProviderError] ->
    IO.puts("(generate_text!/3 raised — no provider reachable: #{Exception.message(e)})")
end

IO.puts("")

# ============================================================================
# 3. stream_text/3 - returns {:ok, stream}
# ============================================================================
#
# Important: the bare LLM stream is NOT the same shape as the agent's
# `Nous.run_stream`. With no tools, `stream_text/3` yields plain TEXT STRINGS
# (it internally filters {:text_delta, _} events and maps them to the text).
# There is no {:finish, _} or {:complete, _} terminator here - the stream just
# ends. (When tools are supplied, the stream may additionally yield an
# {:error, reason} tuple if a turn fails.)

IO.puts("--- 3. stream_text/3 (yields text chunks) ---")
IO.puts("Prompt: Count from 1 to 5, one number per line.\n")

case Nous.LLM.stream_text(model, "Count from 1 to 5, one number per line.") do
  {:ok, stream} ->
    # Each chunk is a String; write them as they arrive.
    stream
    |> Stream.each(fn
      {:error, reason} -> IO.puts("\n[Stream Error: #{inspect(reason)}]")
      chunk when is_binary(chunk) -> IO.write(chunk)
    end)
    |> Stream.run()

    IO.puts("\n[stream complete]")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("")

# ============================================================================
# 4. Passing a %Nous.Model{} struct instead of a string
# ============================================================================
#
# Every function above has a String clause and a %Model{} clause. Building the
# struct yourself lets you set fields like receive_timeout / base_url up front
# and reuse it across calls.

IO.puts("--- 4. Using a %Nous.Model{} struct ---")

model_struct = Nous.Model.parse(model, receive_timeout: 120_000)
IO.puts("Built: #{model_struct.provider}:#{model_struct.model}\n")

case Nous.LLM.generate_text(model_struct, "Reply with the single word: ready") do
  {:ok, text} -> IO.puts("Answer: #{text}")
  {:error, reason} -> IO.puts("(no provider reachable: #{inspect(reason)})")
end

IO.puts("\nNext: mix run examples/01_hello_world.exs  - the full agent API")
