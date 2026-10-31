defmodule Nous.DecisionModel.Backend.HTTP do
  @moduledoc false

  # Shared request plumbing for the HTTP decision backends: URL validation
  # through `Nous.UrlGuard`, the POST through `Nous.Providers.HTTP.post/4`, and
  # the mapping of transport / status failures to `DecisionModelError`.

  alias Nous.DecisionModel.Backend
  alias Nous.Errors.RetryInfo
  alias Nous.Providers.HTTP

  @default_timeout 5_000
  @loopback_hosts ["localhost", "127.0.0.1", "::1"]
  @too_long ~r/too long|too many tokens|exceeds the maximum|maximum context|context length/i

  @doc false
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc false
  # Validates `url` with UrlGuard. Private hosts are allowed only when the
  # caller opted in (`allow_private_hosts: true`) or the URL is explicitly a
  # loopback address (a local vLLM / llama-server).
  @spec validate_url(module(), String.t(), keyword()) :: :ok | {:error, Exception.t()}
  def validate_url(backend, url, opts) do
    allow_private = Keyword.get(opts, :allow_private_hosts, false) == true or loopback?(url)

    case Nous.UrlGuard.validate(url, allow_private_hosts: allow_private) do
      {:ok, _uri} ->
        :ok

      {:error, reason} ->
        {:error,
         Backend.error(
           backend,
           :unavailable,
           "decision model URL failed SSRF validation: #{reason}. " <>
             "Pass `allow_private_hosts: true` for a private-network server."
         )}
    end
  end

  defp loopback?(url) do
    case URI.parse(url) do
      %URI{host: host} when host in @loopback_hosts -> true
      %URI{host: "127." <> _} -> true
      _ -> false
    end
  end

  @doc false
  # The server root: trailing "/" and a trailing "/v1" are dropped, so both
  # "http://host:8000" and "http://host:8000/v1" work.
  @spec root(String.t()) :: String.t()
  def root(base_url) do
    base_url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end

  @doc false
  @spec post(module(), String.t(), map(), list(), keyword(), keyword()) ::
          {:ok, map()} | {:error, Nous.Errors.DecisionModelError.t()}
  def post(backend, url, body, headers, dm_opts, call_opts) do
    timeout = Keyword.get(call_opts, :timeout) || Keyword.get(dm_opts, :timeout, @default_timeout)
    http_opts = [timeout: timeout, backend: Keyword.get(dm_opts, :http_backend)]

    # `HTTP.post/4` returns the decoded JSON object; callers match the keys
    # they need and treat anything else as `:invalid_response`.
    with :ok <- validate_url(backend, url, dm_opts) do
      case HTTP.post(url, body, headers, http_opts) do
        {:ok, response} -> {:ok, response}
        {:error, error} -> {:error, map_error(backend, error)}
      end
    end
  end

  @doc false
  @spec map_error(module(), term()) :: Nous.Errors.DecisionModelError.t()
  def map_error(backend, %{status: 429} = error) do
    Backend.error(backend, :http, "decision model rate limited (429)",
      status: 429,
      retryable?: true,
      retry_after_ms: RetryInfo.parse(error),
      details: error
    )
  end

  def map_error(backend, %{status: status} = error) when status in [400, 413] do
    if too_long?(error[:body]) do
      Backend.error(backend, :oversize, "decision request too long for the model (#{status})",
        status: status,
        details: error
      )
    else
      http_error(backend, status, error, false)
    end
  end

  def map_error(backend, %{status: 408} = error) do
    Backend.error(backend, :timeout, "decision model request timed out (408)",
      status: 408,
      details: error
    )
  end

  def map_error(backend, %{status: status} = error) when is_integer(status) do
    http_error(backend, status, error, status >= 500)
  end

  def map_error(backend, error) do
    if timeout?(error) do
      Backend.error(backend, :timeout, "decision model request timed out", details: error)
    else
      Backend.error(backend, :unavailable, "decision model unreachable: #{inspect(error)}",
        retryable?: true,
        details: error
      )
    end
  end

  defp http_error(backend, status, error, retryable?) do
    Backend.error(backend, :http, "decision model request failed (#{status})",
      status: status,
      retryable?: retryable?,
      details: error
    )
  end

  defp timeout?(:timeout), do: true
  defp timeout?(%{reason: reason}), do: timeout?(reason)
  defp timeout?({:timeout, _}), do: true
  defp timeout?(_), do: false

  defp too_long?(body) when is_binary(body), do: Regex.match?(@too_long, body)
  defp too_long?(nil), do: false

  # Error bodies vary by server (a string, `{"error": "..."}`,
  # `{"errors": [{"message": ...}]}`); search their printed form.
  defp too_long?(body), do: Regex.match?(@too_long, inspect(body, printable_limit: 4096))
end
