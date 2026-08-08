defmodule Nous.Providers.HTTP do
  @moduledoc """
  Shared HTTP utilities for all LLM providers.

  Two HTTP families, both pluggable:

  - **Non-streaming** requests (one-shot model calls, web fetching, search
    APIs) go through a `Nous.HTTP.Backend`. Default is
    `Nous.HTTP.Backend.Req`; `Nous.HTTP.Backend.Hackney` is also shipped.
  - **Streaming** requests (SSE / chunked LLM responses) go through a
    `Nous.HTTP.StreamBackend`. Default is `Nous.HTTP.StreamBackend.Req`
    (Req's `:into` callback driven by Finch); `Nous.HTTP.StreamBackend.Hackney`
    provides strict pull-based backpressure via `:hackney`'s `{:async, :once}`
    mode for callers whose downstream consumers can block per chunk.

  Both backend layers resolve via the same precedence: per-call opt → env
  var → app config → default. See `Nous.HTTP.Backend` and
  `Nous.HTTP.StreamBackend` for selection details.

  ## Usage

      # Non-streaming request
      {:ok, body} = HTTP.post(url, body, headers)

      # Streaming request — returns a lazy stream of parsed events
      {:ok, stream} = HTTP.stream(url, body, headers)
      Enum.each(stream, &process_event/1)

      # Per-call backend override
      {:ok, stream} = HTTP.stream(url, body, headers,
        stream_backend: Nous.HTTP.StreamBackend.Hackney)

  ## SSE Parsing

  SSE events follow the Server-Sent Events spec (https://html.spec.whatwg.org/multipage/server-sent-events.html):
  - Events are separated by double newlines (`\\n\\n`)
  - Each event contains field lines like `data: {...}`
  - Multiple `data:` fields are concatenated with newlines
  - `[DONE]` signals stream completion (OpenAI convention)

  The default SSE parser (`parse_sse_buffer/1`) is transport-agnostic and
  shared by both stream backends. Custom parsers can be plugged in via
  the `:stream_parser` opt; see `Nous.Providers.HTTP.JSONArrayParser`
  for an example.

  ## Stream backpressure

  - `Nous.HTTP.StreamBackend.Req` (default): the `:into` callback runs in
    a `Task` and feeds the consumer process via `send/2`. Producer and
    consumer share an `:atomics` counter of in-flight chunk bytes; above
    the 8 MB high-water mark the producer parks until the consumer drains
    below 1 MB, which stops the socket being read. Memory per stream is
    bounded by that window, not by the (unbounded) mailbox. A consumer
    that stays stalled past `:backpressure_max_wait_ms` gets
    `{:stream_error, %{reason: :backpressure_overflow}}`.
  - `Nous.HTTP.StreamBackend.Hackney`: strict pull-based — the consumer
    calls `:hackney.stream_next/1` per chunk, so the producer literally
    cannot outrun the consumer. Pick this when downstream consumers can
    block per chunk (LiveView fan-out, persistence-on-every-chunk, slow IO).
  """

  require Logger

  alias Nous.HTTP.Buffer

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Make a non-streaming POST request.

  Dispatches to the configured `Nous.HTTP.Backend`. Resolution order
  (highest precedence first):

  1. Per-call `:backend` opt — `HTTP.post(url, body, headers, backend: Nous.HTTP.Backend.Hackney)`
  2. `NOUS_HTTP_BACKEND` env var — `req`, `hackney`, or a fully-qualified
     module name (e.g. `MyApp.MyHTTPBackend`)
  3. `Application.get_env(:nous, :http_backend, ...)`
  4. Default: `Nous.HTTP.Backend.Req`

  A hackney backend selected through *any* of those routes degrades to the
  next-lowest-precedence choice, with a warning, when `:hackney` is not
  loaded — it is an optional dep.

  Returns `{:ok, body}` or `{:error, reason}`.

  ## Options
    * `:backend` - Backend module (overrides env / config / default)
    * `:timeout` - Request timeout in ms (default: 180_000)

  ## Error Reasons
    * `%{status: integer(), body: term()}` - HTTP error response
    * `%Req.TransportError{}` / `%Mint.TransportError{}` - Network error (Req backend)
    * `%JSON.DecodeError{}` - JSON decode error
  """
  @spec post(String.t(), map(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(url, body, headers, opts \\ [])

  def post(url, body, headers, opts) when is_binary(url) and is_map(body) and is_list(headers) do
    backend = available_backend(Keyword.get(opts, :backend) || configured_backend())
    backend.post(url, body, headers, opts)
  end

  def post(url, body, headers, _opts) do
    {:error,
     %ArgumentError{
       message:
         "Invalid arguments: url must be string, body must be map, headers must be list. " <>
           "Got: url=#{inspect(url)}, body=#{inspect(body)}, headers=#{redact_headers(headers)}"
     }}
  end

  # Resolve the configured HTTP backend. The env var takes precedence over
  # app config so ops can A/B-test backends without a redeploy.
  #
  # Custom backend modules are resolved via `String.to_existing_atom/1` to
  # uphold the project-wide rule (review C-2): never `String.to_atom/1` on
  # untrusted input. If the atom doesn't exist or doesn't implement the
  # behaviour, fall back to app config / default rather than crash.
  #
  # Availability is NOT decided here: `available_backend/1` is the single
  # choke point every route passes through, including the ones that never
  # touch this function.
  defp configured_backend do
    case System.get_env("NOUS_HTTP_BACKEND") do
      nil -> app_or_default()
      "req" -> Nous.HTTP.Backend.Req
      "hackney" -> Nous.HTTP.Backend.Hackney
      other -> resolve_custom_backend(other, :post, 4, &app_or_default/0)
    end
  end

  defp app_or_default do
    Application.get_env(:nous, :http_backend, Nous.HTTP.Backend.Req)
  end

  defp resolve_custom_backend(name, fun, arity, fallback) do
    mod = String.to_existing_atom("Elixir." <> name)
    Code.ensure_loaded?(mod)

    if function_exported?(mod, fun, arity) do
      mod
    else
      fallback.()
    end
  rescue
    ArgumentError -> fallback.()
  end

  # Header values carry secrets (authorization, x-api-key) — show only the
  # keys when interpolating headers into error messages.
  defp redact_headers(headers) when is_list(headers) or is_map(headers) do
    headers
    |> Enum.map(fn
      {key, _value} -> {key, "[REDACTED]"}
      other -> other
    end)
    |> inspect()
  end

  defp redact_headers(headers), do: inspect(headers)

  @doc """
  Make a streaming POST request.

  Dispatches to the configured `Nous.HTTP.StreamBackend`. Resolution
  order (highest precedence first):

  1. Per-call `:stream_backend` opt
  2. `NOUS_HTTP_STREAM_BACKEND` env var — `req`, `hackney`, or a
     fully-qualified module name
  3. `Application.get_env(:nous, :http_stream_backend, ...)`
  4. Default: `Nous.HTTP.StreamBackend.Req`

  A hackney backend selected through *any* of those routes degrades to the
  next-lowest-precedence choice, with a warning, when `:hackney` is not
  loaded — it is an optional dep.

  Returns `{:ok, stream}` where stream is an `Enumerable.t()` of parsed
  events. Events are maps with string keys (parsed JSON),
  `{:stream_done, reason}` tuples on completion, or
  `{:stream_error, reason}` tuples on failure.

  ## Options
    * `:stream_backend` - Backend module (overrides env / config / default)
    * `:timeout` - Receive timeout in ms (default: 180_000)
    * `:connect_timeout` - TCP connect timeout in ms (default: 30_000)
    * `:stream_parser` - Module for parsing the stream buffer (default: SSE).
      Must implement `parse_buffer/1` returning `{events, remaining_buffer}`.
      See `Nous.Providers.HTTP.JSONArrayParser` for an example.
    * `:pool` - (Hackney backend only) Hackney pool name (default: `:default`).

  ## Error Handling
  The stream emits `{:stream_error, reason}` on errors and then halts.
  """
  @spec stream(String.t(), map(), list(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(url, body, headers, opts \\ [])

  def stream(url, body, headers, opts)
      when is_binary(url) and is_map(body) and is_list(headers) do
    backend = available_backend(Keyword.get(opts, :stream_backend) || configured_stream_backend())
    backend.stream(url, body, ensure_streaming_headers(headers), opts)
  end

  def stream(url, body, headers, _opts) do
    {:error,
     %ArgumentError{
       message:
         "Invalid arguments: url must be string, body must be map, headers must be list. " <>
           "Got: url=#{inspect(url)}, body=#{inspect(body)}, headers=#{redact_headers(headers)}"
     }}
  end

  defp configured_stream_backend do
    case System.get_env("NOUS_HTTP_STREAM_BACKEND") do
      nil -> stream_app_or_default()
      "req" -> Nous.HTTP.StreamBackend.Req
      "hackney" -> Nous.HTTP.StreamBackend.Hackney
      other -> resolve_custom_backend(other, :stream, 4, &stream_app_or_default/0)
    end
  end

  # The hackney backends are opt-in: hackney is an *optional* dep, so a
  # selection that names one has to be checked before it is dispatched to.
  # Every route funnels through here — the per-call `:backend` /
  # `:stream_backend` opt, the env vars, and `config :nous, :http_backend` /
  # `:http_stream_backend`. Guarding only the env var (as this did) left the
  # other two reaching `:hackney.request/5` and raising UndefinedFunctionError
  # on the first request of any app that never declared `{:hackney, "~> 4.0"}`.
  defp available_backend(backend) do
    if hackney_backend?(backend) and not Code.ensure_loaded?(:hackney) do
      Logger.warning(
        "#{inspect(backend)} was selected, but :hackney is not available. " <>
          "Add {:hackney, \"~> 4.0\"} to your deps to use it. " <>
          "Falling back to the default backend."
      )

      fallback_backend(backend)
    else
      backend
    end
  end

  defp hackney_backend?(backend),
    do: backend in [Nous.HTTP.Backend.Hackney, Nous.HTTP.StreamBackend.Hackney]

  # Degrade to the next-lowest-precedence choice — unless that is the very
  # backend we just rejected, in which case there is nowhere left to fall but
  # the shipped default.
  defp fallback_backend(Nous.HTTP.Backend.Hackney) do
    case app_or_default() do
      Nous.HTTP.Backend.Hackney -> Nous.HTTP.Backend.Req
      other -> other
    end
  end

  defp fallback_backend(Nous.HTTP.StreamBackend.Hackney) do
    case stream_app_or_default() do
      Nous.HTTP.StreamBackend.Hackney -> Nous.HTTP.StreamBackend.Req
      other -> other
    end
  end

  defp stream_app_or_default do
    Application.get_env(:nous, :http_stream_backend, Nous.HTTP.StreamBackend.Req)
  end

  # ============================================================================
  # SSE Parsing (Public for testing and reuse by stream backends)
  # ============================================================================

  @doc """
  Parse an SSE buffer into events.

  Returns `{events, remaining_buffer}` where events is a list of parsed
  JSON maps, `{:stream_done, reason}` tuples, or `{:parse_error, reason}` tuples.

  Handles edge cases:
  - Empty events (ignored)
  - Whitespace-only events (ignored)
  - Malformed JSON (emits `{:parse_error, reason}`)
  - Multiple data fields per event (concatenated per spec)
  - Comment lines (ignored)
  - Buffer overflow protection

  ## Examples

      iex> parse_sse_buffer("data: {\\"text\\": \\"hi\\"}\\n\\n")
      {[%{"text" => "hi"}], ""}

      iex> parse_sse_buffer("data: partial")
      {[], "data: partial"}

      iex> parse_sse_buffer("data: [DONE]\\n\\n")
      {[{:stream_done, "stop"}], ""}
  """
  @spec parse_sse_buffer(String.t() | nil | any()) ::
          {list(), String.t()} | {:error, :buffer_overflow}
  defdelegate parse_sse_buffer(buffer), to: Buffer

  @doc """
  Parse a single SSE event.

  Returns parsed JSON map, `{:stream_done, reason}`, `{:parse_error, reason}`, or nil.

  Handles per SSE spec:
  - `data:` fields (with or without space after colon)
  - Multiple `data:` fields concatenated with newlines
  - `:` prefix for comments (ignored)
  - `event:`, `id:`, `retry:` fields (ignored for now)
  - Empty lines within events

  ## Examples

      iex> parse_sse_event("data: {\\"key\\": \\"value\\"}")
      %{"key" => "value"}

      iex> parse_sse_event("data: [DONE]")
      {:stream_done, "stop"}

      iex> parse_sse_event(": this is a comment")
      nil

      iex> parse_sse_event("")
      nil
  """
  @spec parse_sse_event(String.t()) ::
          map() | {:stream_done, String.t()} | {:parse_error, term()} | nil
  defdelegate parse_sse_event(event), to: Buffer

  @doc false
  # Public for stream-backend reuse only — not part of the public API
  # surface. Thin wrapper over `Nous.HTTP.Buffer.parse_stream_buffer/2`,
  # retained so out-of-tree callers keep working. The transport layer now
  # calls `Nous.HTTP.Buffer` directly: a generic transport must not reach
  # up into `Nous.Providers.*` (arch-review: layering inversion, the one
  # non-benign runtime cycle of the seven reported).
  @spec parse_stream_buffer(String.t(), module() | nil) :: {list(), String.t()}
  defdelegate parse_stream_buffer(buffer, parser_mod), to: Buffer

  @doc false
  # Public for stream-backend reuse only. See
  # `Nous.HTTP.Buffer.flush_stream_buffer/2`.
  @spec flush_stream_buffer(String.t(), module() | nil) :: {list(), String.t()}
  defdelegate flush_stream_buffer(buffer, parser_mod), to: Buffer

  @doc false
  # Max buffer size — public for stream-backend reuse.
  @spec max_buffer_size() :: pos_integer()
  defdelegate max_buffer_size(), to: Buffer

  # ============================================================================
  # Header Helpers (Public for testing)
  # ============================================================================

  @doc """
  Base JSON content-type headers. Most providers start their header list here.
  """
  @spec json_headers() :: list()
  def json_headers, do: [{"content-type", "application/json"}]

  @doc """
  Build authorization header for Bearer token auth (OpenAI style).

  Returns empty list for nil, empty string, or "not-needed" values.
  """
  @spec bearer_auth_header(String.t() | nil) :: list()
  def bearer_auth_header(nil), do: []
  def bearer_auth_header(""), do: []
  def bearer_auth_header("not-needed"), do: []

  def bearer_auth_header(api_key) when is_binary(api_key),
    do: [{"authorization", "Bearer #{api_key}"}]

  def bearer_auth_header(_), do: []

  @doc """
  Build authorization header for API key auth (Anthropic style).

  Returns empty list for nil or empty string values.
  """
  @spec api_key_header(String.t() | nil, String.t()) :: list()
  def api_key_header(nil, _header_name), do: []
  def api_key_header("", _header_name), do: []

  def api_key_header(api_key, header_name) when is_binary(api_key) and is_binary(header_name) do
    [{header_name, api_key}]
  end

  def api_key_header(_, _), do: []

  @doc """
  Build OpenAI-style `openai-organization` header. Returns empty list when nil/empty.
  """
  @spec organization_header(String.t() | nil) :: list()
  def organization_header(nil), do: []
  def organization_header(""), do: []
  def organization_header(org) when is_binary(org), do: [{"openai-organization", org}]
  def organization_header(_), do: []

  @doc """
  Build OpenAI-style `openai-project` header (project-scoped API keys).
  Returns empty list when nil/empty.
  """
  @spec openai_project_header(String.t() | nil) :: list()
  def openai_project_header(nil), do: []
  def openai_project_header(""), do: []
  def openai_project_header(project) when is_binary(project), do: [{"openai-project", project}]
  def openai_project_header(_), do: []

  @doc false
  # Public for stream-backend reuse. Ensures the request carries
  # `content-type: application/json` and `accept: text/event-stream`
  # if the caller didn't supply them.
  @spec ensure_streaming_headers(list()) :: list()
  def ensure_streaming_headers(headers) do
    headers
    |> maybe_add_header("content-type", "application/json")
    |> maybe_add_header("accept", "text/event-stream")
  end

  defp maybe_add_header(headers, key, value) do
    key_lower = String.downcase(key)

    if Enum.any?(headers, fn {k, _} -> String.downcase(to_string(k)) == key_lower end) do
      headers
    else
      [{key, value} | headers]
    end
  end
end
