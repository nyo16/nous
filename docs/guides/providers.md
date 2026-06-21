# LLM Providers

[Back to README](../../README.md#supported-providers)

Nous talks to every LLM through a single front door: a `"provider:model"` string. You pick a model by naming its provider and the model identifier, and Nous routes the request to the right backend — OpenAI, Anthropic, Google, a cloud aggregator, or a local server on your laptop. Switching providers is usually a one-line change.

This guide is the overview: every supported provider, how to authenticate each one, and how to move between them. For depth on three topics it links out — [custom OpenAI-compatible endpoints](custom_providers.md), [Google Vertex AI setup](vertex_ai_setup.md), and [HTTP backends](http_backends.md).

## How provider selection works

`Nous.Model.parse/2` splits a string like `"openai:gpt-4o"` on the first colon. The left side is the provider, the right side is the model name (which may itself contain slashes or colons, e.g. `"openrouter:anthropic/claude-3.5-sonnet"`). `Nous.new/2` accepts the same string:

```elixir
agent = Nous.new("openai:gpt-4o")
{:ok, result} = Nous.run(agent, "What is Elixir?")
```

The provider determines three things: the default base URL, where the API key is read from, and which provider module handles the HTTP request/response shaping.

## All providers

There are 13 named providers plus the `custom:` prefix. The list below is the authoritative one from `Nous.Model` — note that `groq`, `ollama`, `openrouter`, and `together` (along with `lmstudio`, `vllm`, and `sglang`) do **not** have their own provider modules; they route through the generic `Nous.Providers.OpenAICompatible` implementation.

| Prefix | Example string | API key vs. local | Handled by |
|--------|----------------|-------------------|------------|
| `openai` | `openai:gpt-4o` | API key | `Nous.Providers.OpenAI` |
| `anthropic` | `anthropic:claude-3-5-sonnet-20241022` | API key | `Nous.Providers.Anthropic` |
| `gemini` | `gemini:gemini-1.5-pro` | API key | `Nous.Providers.Gemini` |
| `vertex_ai` | `vertex_ai:gemini-2.0-flash` | GCP auth (Goth / token) | `Nous.Providers.VertexAI` |
| `groq` | `groq:llama-3.1-70b-versatile` | API key | `Nous.Providers.OpenAICompatible` |
| `mistral` | `mistral:mistral-large-latest` | API key | `Nous.Providers.Mistral` |
| `ollama` | `ollama:llama2` | Local server | `Nous.Providers.OpenAICompatible` |
| `lmstudio` | `lmstudio:qwen3-vl-4b-thinking-mlx` | Local server | `Nous.Providers.LMStudio` |
| `llamacpp` | `llamacpp:local` | Local (in-process NIF) | `Nous.Providers.LlamaCpp` |
| `openrouter` | `openrouter:anthropic/claude-3.5-sonnet` | API key | `Nous.Providers.OpenAICompatible` |
| `together` | `together:meta-llama/Llama-3-70b-chat-hf` | API key | `Nous.Providers.OpenAICompatible` |
| `vllm` | `vllm:meta-llama/Llama-3-8B-Instruct` | Local server (`base_url` required) | `Nous.Providers.VLLM` |
| `sglang` | `sglang:meta-llama/Llama-3-8B` | Local server | `Nous.Providers.SGLang` |
| `custom` | `custom:my-model` | Either (`base_url` required) | `Nous.Providers.Custom` |

> The legacy `"openai_compatible:"` prefix is still accepted and is equivalent to `"custom:"`. Prefer `custom:` for new code.

## Provider categories

**First-party APIs** — `openai`, `anthropic`, `gemini` each have a dedicated module that exposes provider-specific features (OpenAI structured outputs and reasoning models, Anthropic's Messages API and long-context beta, Gemini's thinking config and `x-goog-api-key` auth). Defaults:

| Provider | Default base URL |
|----------|------------------|
| `openai` | `https://api.openai.com/v1` |
| `anthropic` | `https://api.anthropic.com` |
| `gemini` | `https://generativelanguage.googleapis.com/v1beta` |
| `mistral` | `https://api.mistral.ai/v1` |
| `groq` | `https://api.groq.com/openai/v1` |
| `together` | `https://api.together.xyz/v1` |
| `openrouter` | `https://openrouter.ai/api/v1` |
| `ollama` | `http://localhost:11434/v1` |
| `lmstudio` | `http://localhost:1234/v1` |
| `sglang` | `http://localhost:30000/v1` |

**OpenAI-compatible cloud aggregators** — `groq`, `together`, and `openrouter` are hosted services that speak the OpenAI Chat Completions API. They are convenience aliases: each ships a sensible default base URL and reads its own env var, but routes through `Nous.Providers.OpenAICompatible`. You could reach the exact same endpoint with a `custom:` string and an explicit `base_url`.

**Local servers** — `ollama`, `lmstudio`, `vllm`, and `sglang` point at a server running on your own machine. They need no API key (Nous supplies a placeholder where one is required). `vllm` has no default base URL, so `"vllm:..."` **requires** a `base_url` option and raises `ArgumentError` without one. `sglang` defaults to `http://localhost:30000/v1`; the others default to their standard local ports.

**In-process** — `llamacpp` runs the model inside the BEAM via NIFs (no HTTP server, no API key). Its base URL is the sentinel string `"local"`. Pass the model file with the `:llamacpp_model` option, which `parse/2` folds into `default_settings`:

```elixir
Nous.new("llamacpp:local", llamacpp_model: "/path/to/model.gguf")
```

**Enterprise** — `vertex_ai` is Google Cloud's enterprise Gemini platform (VPC-SC, IAM, regional/global endpoints). It uses GCP OAuth tokens rather than a static API key, and its base URL is built per-request by the provider. See [Vertex AI setup](vertex_ai_setup.md).

**Custom** — `custom:` is the catch-all for any OpenAI-compatible endpoint not covered above. It always requires a `base_url` (from option, `CUSTOM_BASE_URL`, or `config :nous, :custom`). See [custom providers](custom_providers.md).

## Switching providers

Because the provider lives in the model string, switching is usually just editing that string — the rest of your agent code is identical:

```elixir
# Cloud OpenAI
agent = Nous.new("openai:gpt-4o")

# Swap to Claude — nothing else changes
agent = Nous.new("anthropic:claude-3-5-sonnet-20241022")

# Swap to a local Ollama model — no API key, no network
agent = Nous.new("ollama:llama3.1")

{:ok, result} = Nous.run(agent, "Summarize this thread.")
```

Tools, plugins, instructions, streaming (`Nous.run_stream/2`), and `context` all behave the same across providers. The few exceptions are providers that need extra wiring: `vllm` and `custom` require a `base_url`, `llamacpp` needs `:llamacpp_model`, and `vertex_ai` needs GCP auth.

## Configuration

### API keys via application config

The hosted providers read their key from `config :nous` by default. Set them in `config/runtime.exs` (so they read from the environment at boot):

```elixir
import Config

config :nous,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  google_ai_api_key: System.get_env("GOOGLE_AI_API_KEY"),  # for gemini:
  groq_api_key: System.get_env("GROQ_API_KEY"),
  mistral_api_key: System.get_env("MISTRAL_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  together_api_key: System.get_env("TOGETHER_API_KEY")
```

The config key per provider:

| Provider | Config key | Notes |
|----------|------------|-------|
| `openai` | `:openai_api_key` | |
| `anthropic` | `:anthropic_api_key` | |
| `gemini` | `:google_ai_api_key` | |
| `groq` | `:groq_api_key` | |
| `mistral` | `:mistral_api_key` | |
| `openrouter` | `:openrouter_api_key` | |
| `together` | `:together_api_key` | |
| `vertex_ai` | `:vertex_ai_api_key` | usually Goth/token instead — see guide |
| `ollama` | — | placeholder `"ollama"` |
| `lmstudio` | — | placeholder `"not-needed"` |
| `vllm` / `sglang` / `llamacpp` | — | key optional / not used |
| `custom` | `CUSTOM_API_KEY` env var | or per-call `api_key:` |

### Per-call override

Any default can be overridden inline. This wins over env vars and app config:

```elixir
Nous.new("openai:gpt-4o",
  api_key: System.get_env("OPENAI_API_KEY"),
  base_url: "https://my-proxy.internal/v1",
  organization: "org-...",
  receive_timeout: 300_000
)
```

### Timeouts

The default receive timeout is 3 minutes for cloud providers and `custom`. Local providers get longer defaults (2 minutes for `ollama`/`lmstudio`/`vllm`/`sglang`, 5 minutes for `llamacpp`, since cold weights are slow to first token). Override with `receive_timeout:` (milliseconds) when a model needs more.

### `custom:` defaults

The `custom:` provider also reads `CUSTOM_BASE_URL` and `CUSTOM_API_KEY` environment variables, or `config :nous, :custom, base_url: ..., api_key: ...`, as defaults. Details in [custom providers](custom_providers.md).

## Related guides

- [Custom Providers](custom_providers.md) — the `custom:` prefix, OpenAI-compatible cloud and local endpoints, troubleshooting connection and auth errors.
- [Google Vertex AI Setup](vertex_ai_setup.md) — service accounts, Goth, regional vs. global endpoints, supported Gemini models.
- [HTTP Backends](http_backends.md) — choosing Req vs. Hackney for streaming and non-streaming requests, backpressure, and connection pooling.
