defmodule Nous.Tools.UrlGuard do
  @moduledoc """
  SSRF protection for outbound HTTP from tools and providers.

  Prevents prompt-injected agents from reaching cloud-metadata
  (`169.254.169.254`), internal services on private networks, loopback,
  and link-local ranges. By default only `http://` and `https://` schemes
  are accepted; other schemes (`file://`, `gopher://`, `ftp://`, etc.)
  are rejected.

  ## Usage

      case Nous.Tools.UrlGuard.validate("https://example.com/foo") do
        {:ok, uri} -> proceed_with(uri)
        {:error, reason} -> {:error, reason}  # human-readable
      end

  ## Opt-in: allowing private hosts

  For local dev / Docker dev-loop you can pass `allow_private_hosts: true`:

      Nous.Tools.UrlGuard.validate(url, allow_private_hosts: true)

  Do NOT enable this in production. It re-opens the SSRF channel.
  """

  import Bitwise

  @blocked_schemes ~w(file gopher ftp ldap dict ssh)

  # IPv4 ranges that must never be reachable from agent-controlled URLs.
  # CIDR-style; checked via :inet integer math.
  @blocked_v4_ranges [
    # 127.0.0.0/8 - loopback
    {{127, 0, 0, 0}, 8},
    # 10.0.0.0/8 - RFC1918
    {{10, 0, 0, 0}, 8},
    # 172.16.0.0/12 - RFC1918
    {{172, 16, 0, 0}, 12},
    # 192.168.0.0/16 - RFC1918
    {{192, 168, 0, 0}, 16},
    # 169.254.0.0/16 - link-local (cloud metadata!)
    {{169, 254, 0, 0}, 16},
    # 100.64.0.0/10 - CGNAT
    {{100, 64, 0, 0}, 10},
    # 0.0.0.0/8 - "this network"
    {{0, 0, 0, 0}, 8},
    # 224.0.0.0/4 - multicast
    {{224, 0, 0, 0}, 4},
    # 240.0.0.0/4 - reserved
    {{240, 0, 0, 0}, 4}
  ]

  @doc """
  Validate a URL string. Returns `{:ok, %URI{}}` or `{:error, reason}`.

  ## Options

  - `:allow_private_hosts` — when true, skips the private/loopback
    blocklist. Defaults to false.
  """
  @spec validate(String.t(), keyword()) :: {:ok, URI.t()} | {:error, String.t()}
  def validate(url, opts \\ []) do
    with {:ok, uri, _addrs} <- do_validate(url, opts), do: {:ok, uri}
  end

  @doc """
  Like `validate/2`, but also returns one validated IP address to **pin** the
  subsequent connection to — closing the DNS-rebinding TOCTOU window where the
  guard resolves one IP and the HTTP client independently resolves another.

  Returns `{:ok, %URI{}, ip_tuple}` (or `{:ok, %URI{}, nil}` when host checking
  was skipped via `allow_private_hosts: true`). Because validation rejects the
  URL if *any* resolved address is blocked, the returned address is always safe.
  """
  @spec validate_pinned(String.t(), keyword()) ::
          {:ok, URI.t(), :inet.ip_address() | nil} | {:error, String.t()}
  def validate_pinned(url, opts \\ []) do
    with {:ok, uri, addrs} <- do_validate(url, opts) do
      {:ok, uri, List.first(addrs)}
    end
  end

  defp do_validate(url, _opts) when not is_binary(url) do
    {:error, "URL must be a string"}
  end

  defp do_validate(url, opts) do
    allow_private = Keyword.get(opts, :allow_private_hosts, false)

    with {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri),
         {:ok, addrs} <- resolve_and_check(uri, allow_private) do
      {:ok, uri, addrs}
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" -> {:ok, uri}
      {:ok, _} -> {:error, "URL has no host"}
      {:error, _} -> {:error, "URL is malformed"}
    end
  end

  defp check_scheme(%URI{scheme: scheme}) do
    cond do
      is_nil(scheme) ->
        {:error, "URL must include a scheme (http:// or https://)"}

      scheme in @blocked_schemes ->
        {:error, "URL scheme #{inspect(scheme)} is blocked"}

      scheme in ["http", "https"] ->
        :ok

      true ->
        {:error, "URL scheme #{inspect(scheme)} is not allowed (use http or https)"}
    end
  end

  # allow_private_hosts: skip resolution/blocklist entirely (local dev only).
  defp resolve_and_check(_uri, true), do: {:ok, []}

  defp resolve_and_check(%URI{host: host}, false) do
    case resolve_host(host) do
      {:ok, addrs} ->
        if Enum.any?(addrs, &address_blocked?/1) do
          {:error,
           "URL resolves to a private/loopback/link-local address; refusing to fetch (#{host})"}
        else
          {:ok, addrs}
        end

      {:error, reason} ->
        {:error, "Could not resolve #{host}: #{inspect(reason)}"}
    end
  end

  # Resolve a host name to its IP addresses. If the input is already an IP
  # literal, just parse it. For names we resolve BOTH families (A + AAAA):
  # the HTTP client may connect over IPv6, so validating only IPv4 left a
  # dual-stack bypass (benign A record, internal AAAA record).
  defp resolve_host(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, addr} ->
        {:ok, [addr]}

      {:error, _} ->
        v4 = getaddrs(charlist, :inet)
        v6 = getaddrs(charlist, :inet6)

        case v4 ++ v6 do
          [] -> {:error, :nxdomain}
          addrs -> {:ok, addrs}
        end
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end
  end

  # IPv4 address blocklist check (CIDR-style).
  defp address_blocked?({a, b, c, d} = _addr) do
    Enum.any?(@blocked_v4_ranges, fn {prefix, prefix_len} ->
      addr_int = ip_to_int({a, b, c, d})
      prefix_int = ip_to_int(prefix)
      mask = bsl(0xFFFFFFFF, 32 - prefix_len) |> band(0xFFFFFFFF)
      band(addr_int, mask) == band(prefix_int, mask)
    end)
  end

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) — normalize to the embedded v4 and reuse
  # the comprehensive v4 blocklist (otherwise ::ffff:169.254.169.254 reached
  # cloud metadata).
  defp address_blocked?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    address_blocked?(embedded_v4(g, h))
  end

  # NAT64 well-known prefix 64:ff9b::/96 — embeds a v4 address in the low 32 bits.
  defp address_blocked?({0x64, 0xFF9B, 0, 0, 0, 0, g, h}) do
    address_blocked?(embedded_v4(g, h))
  end

  # IPv6 loopback (::1) and unspecified (::).
  defp address_blocked?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp address_blocked?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # Unique-local fc00::/7.
  defp address_blocked?({a, _, _, _, _, _, _, _}) when band(a, 0xFE00) == 0xFC00, do: true

  # Link-local fe80::/10 (the IPv6 analogue of 169.254.0.0/16).
  defp address_blocked?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFE80, do: true

  defp address_blocked?(_), do: false

  defp embedded_v4(g, h) do
    {band(bsr(g, 8), 0xFF), band(g, 0xFF), band(bsr(h, 8), 0xFF), band(h, 0xFF)}
  end

  defp ip_to_int({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
end
