defmodule Nous.HTTP.Backend.Hackney do
  @moduledoc """
  `Nous.HTTP.Backend` implementation backed by `:hackney`.

  Uses `:hackney.request/5` synchronously — hackney 4 returns the full
  response body inline as `{:ok, status, headers, body}` (the legacy
  `hackney.body/1` follow-up call from hackney 1.x was removed in v4).
  Hackney 4 is already in the dependency tree from 0.15.0 (used for
  streaming) — this backend lets users consolidate non-streaming HTTP
  onto the same library without keeping Finch/Mint in the hot path.

  TLS verification mirrors the streaming side: explicit
  `verify: :verify_peer` with system CAs from `:public_key.cacerts_get/0`.
  Hackney's default is `:verify_none`, which would silently accept
  MITM'd connections — do not regress this.

  Pool: uses hackney's `:default` pool (50 conns, 2s idle keepalive).
  Apps that want isolation can pass `pool: :my_pool` per call after
  starting the pool with `:hackney_pool.start_pool/2`.
  """

  @behaviour Nous.HTTP.Backend

  require Logger

  @default_timeout 60_000
  @default_connect_timeout 30_000

  @impl Nous.HTTP.Backend
  def post(url, body, headers, opts \\ [])
      when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    pool = Keyword.get(opts, :pool, :default)

    headers = ensure_content_type(headers)
    hackney_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    try do
      json_body = JSON.encode!(body)
      do_request(url, hackney_headers, json_body, timeout, connect_timeout, pool)
    rescue
      error ->
        Logger.error("Failed to encode request body: #{inspect(error)}")
        {:error, %{reason: :json_encode_error, details: error}}
    end
  end

  # Hackney 4 returns the body inline: `{:ok, status, headers, body}`. The
  # legacy hackney.body/1 follow-up call from hackney 1.x is gone — the
  # `with_body` option is now the default and ignored.
  defp do_request(url, headers, body, timeout, connect_timeout, pool) do
    hackney_opts = [
      {:pool, pool},
      {:recv_timeout, timeout},
      {:connect_timeout, connect_timeout},
      {:ssl_options, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}
    ]

    case :hackney.request(:post, url, headers, body, hackney_opts) do
      {:ok, status, _resp_headers, body_bin} when status in 200..299 ->
        {:ok, decode_body(body_bin)}

      {:ok, status, _resp_headers, body_bin} ->
        decoded = decode_body(body_bin)

        Logger.warning("HTTP request failed with status #{status}: #{truncate_for_log(decoded)}")

        {:error, %{status: status, body: decoded}}

      {:error, reason} = err ->
        Logger.error("Hackney request error: #{inspect(reason)}")
        err
    end
  end

  defp decode_body(""), do: %{}

  defp decode_body(bin) when is_binary(bin) do
    case JSON.decode(bin) do
      {:ok, value} -> value
      {:error, _} -> bin
    end
  end

  defp ensure_content_type(headers) do
    has_ct? =
      Enum.any?(headers, fn {k, _} -> String.downcase(to_string(k)) == "content-type" end)

    if has_ct?, do: headers, else: [{"content-type", "application/json"} | headers]
  end

  defp truncate_for_log(data) when is_binary(data) do
    if byte_size(data) > 500 do
      String.slice(data, 0, 500) <> "... (truncated)"
    else
      data
    end
  end

  defp truncate_for_log(data), do: inspect(data, limit: 500)
end
