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

  # 3 minutes — LLMs with reasoning/long completions routinely exceed
  # the previous 60s default. Per-call `:timeout` opt overrides.
  @default_timeout 180_000
  @default_connect_timeout 30_000

  @impl Nous.HTTP.Backend
  def post(url, body, headers, opts \\ [])
      when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    pool = Keyword.get(opts, :pool, :default)

    headers = ensure_content_type(headers)
    hackney_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    with {:ok, json_body} <- encode_body(body) do
      do_request(url, hackney_headers, json_body, timeout, connect_timeout, pool)
    end
  end

  # The rescue covers the encode and nothing else. It used to span
  # `do_request/6` as well, so every exception raised on the transport path —
  # including the `UndefinedFunctionError` an app gets when `:hackney` is not
  # in its deps — was reported as `:json_encode_error`. A confidently wrong
  # error costs more to debug than a raw one.
  #
  # `JSON.encode!/1` here is the OTP-27 `:json` module, not Jason: it raises
  # `Protocol.UndefinedError` for terms with no `JSON.Encoder` implementation
  # and `ErlangError` (`{:invalid_byte, _}`) for invalid UTF-8 in a binary or
  # a key. Both are verified and both are reachable from model-authored
  # content. Nothing else in this clause raises.
  defp encode_body(body) do
    {:ok, JSON.encode!(body)}
  rescue
    e in [Protocol.UndefinedError, ErlangError] ->
      Logger.error("Failed to encode request body: #{Exception.message(e)}")
      {:error, %{reason: :json_encode_error, details: e}}
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

      {:ok, status, resp_headers, body_bin} ->
        decoded = decode_body(body_bin)

        Logger.warning("HTTP request failed with status #{status}: #{truncate_for_log(decoded)}")

        # Headers surfaced for Nous.Errors.RetryInfo. Hackney returns names
        # and values as charlists; convert to strings for downstream parsing.
        {:error, %{status: status, body: decoded, headers: stringify_headers(resp_headers)}}

      {:error, reason} = err ->
        Logger.error("Hackney request error: #{inspect(reason)}")
        err
    end
  end

  defp stringify_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
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
