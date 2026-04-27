defmodule Nous.HTTP.Backend do
  @moduledoc """
  Behaviour for non-streaming HTTP backends.

  Implemented by `Nous.HTTP.Backend.Req` (default) and
  `Nous.HTTP.Backend.Hackney`. Selection is per-call via `:backend`,
  per-environment via `NOUS_HTTP_BACKEND`, or per-app via
  `config :nous, :http_backend, MyBackend`. See
  `Nous.Providers.HTTP.post/4` for the resolution order and
  `docs/benchmarks/http_backend.md` for performance characteristics.

  Custom backends just need to implement `c:post/4` and return one of:
  `{:ok, decoded_body}` for 2xx, `{:error, %{status: status, body: body}}`
  for 4xx/5xx, or `{:error, term()}` for transport / decode failures.

  Streaming requests do NOT go through this behaviour — those always
  use hackney's `:async, :once` mode for backpressure (see
  `Nous.Providers.HTTP.stream/4`).
  """

  @doc """
  Issue a POST request with a JSON body and return the decoded JSON response.

  ## Options
    * `:timeout` — receive timeout in milliseconds (default: 60_000)

  Backends MAY accept additional options; unknown options should be ignored.
  """
  @callback post(
              url :: String.t(),
              body :: map(),
              headers :: [{String.t(), String.t()}],
              opts :: keyword()
            ) :: {:ok, map() | binary()} | {:error, term()}
end
