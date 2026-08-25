defmodule Nous.Tools.UrlGuard do
  @moduledoc """
  SSRF protection for outbound HTTP from tools and providers.

  Prevents prompt-injected agents from reaching cloud-metadata
  (`169.254.169.254`), internal services on private networks, loopback,
  and link-local ranges. By default only `http://` and `https://` schemes
  are accepted; other schemes (`file://`, `gopher://`, `ftp://`, etc.)
  are rejected.

  ## Usage

  Prefer `validate_pinned/2`: it also returns a vetted IP address to pin the
  subsequent connection to, which closes the DNS-rebinding TOCTOU window
  (see below):

      case Nous.Tools.UrlGuard.validate_pinned("https://example.com/foo") do
        {:ok, uri, ip} -> connect_to(ip, uri)   # pin the connection to `ip`
        {:error, reason} -> {:error, reason}    # human-readable
      end

  `validate/2` checks the URL but leaves the HTTP client to do its own DNS
  lookup afterwards. Between the two resolutions an attacker-controlled DNS
  record can be rebound to an internal address (a TOCTOU race), so only use
  it where pinning the connection is impossible:

      case Nous.Tools.UrlGuard.validate("https://example.com/foo") do
        {:ok, uri} -> proceed_with(uri)
        {:error, reason} -> {:error, reason}
      end

  ## Opt-in: allowing private hosts

  For local dev / Docker dev-loop you can pass `allow_private_hosts: true`:

      Nous.Tools.UrlGuard.validate(url, allow_private_hosts: true)

  Do NOT enable this in production. It re-opens the SSRF channel.

  ## Escape hatch: exact-IP allowlist

  `config :nous, url_guard_allow_ips: [{127, 0, 0, 1}]` exempts those *exact*
  `:inet.ip_address()` tuples from the address blocklist — nothing else. No
  CIDR, no hostnames, no ranges; the scheme check, DNS resolution, and the
  per-hop re-validation callers do on redirects all still run. It exists so the
  test suite can point a fetch at a loopback-bound `Bypass` server (and so an
  egress proxy on a fixed private IP can be whitelisted deliberately). Defaults
  to `[]`.

  Do NOT set it in production. Every address you list is an address a
  prompt-injected agent can reach.
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
    {{240, 0, 0, 0}, 4},
    # 198.18.0.0/15 - benchmarking (RFC 2544), sometimes routed internally
    {{198, 18, 0, 0}, 15},
    # 192.0.2.0/24 - TEST-NET-1 (RFC 5737)
    {{192, 0, 2, 0}, 24},
    # 198.51.100.0/24 - TEST-NET-2 (RFC 5737)
    {{198, 51, 100, 0}, 24},
    # 203.0.113.0/24 - TEST-NET-3 (RFC 5737)
    {{203, 0, 113, 0}, 24},
    # 192.0.0.0/24 - IETF protocol assignments (RFC 6890)
    {{192, 0, 0, 0}, 24}
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

  # Exact-IP escape hatch (see moduledoc). Consulted here and nowhere else, so
  # resolution and every other check stay exactly as they were; the default
  # empty list means the blocklist is authoritative unless someone opts out.
  defp address_blocked?(addr) do
    addr not in Application.get_env(:nous, :url_guard_allow_ips, []) and blocked_range?(addr)
  end

  # IPv4 address blocklist check (CIDR-style).
  defp blocked_range?({_, _, _, _} = addr) do
    addr_int = ip_to_int(addr)

    Enum.any?(@blocked_v4_ranges, fn {prefix, prefix_len} ->
      prefix_int = ip_to_int(prefix)
      mask = bsl(0xFFFFFFFF, 32 - prefix_len) |> band(0xFFFFFFFF)
      band(addr_int, mask) == band(prefix_int, mask)
    end)
  end

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) — normalize to the embedded v4 and reuse
  # the comprehensive v4 blocklist (otherwise ::ffff:169.254.169.254 reached
  # cloud metadata). The embedded form is checked against the ranges only: the
  # allowlist is exact-tuple, so allowing 127.0.0.1 must not also allow
  # ::ffff:127.0.0.1.
  defp blocked_range?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    blocked_range?(embedded_v4(g, h))
  end

  # NAT64 well-known prefix 64:ff9b::/96 — embeds a v4 address in the low 32 bits.
  defp blocked_range?({0x64, 0xFF9B, 0, 0, 0, 0, g, h}) do
    blocked_range?(embedded_v4(g, h))
  end

  # 6to4 prefix 2002::/16 — embeds a v4 address in the next 32 bits
  # (2002:AABB:CCDD::/48 tunnels for v4 AA.BB.CC.DD), so 2002:a9fe:a9fe::
  # would otherwise reach cloud metadata. Decode and reuse the v4 blocklist.
  defp blocked_range?({0x2002, g, h, _, _, _, _, _}) do
    blocked_range?(embedded_v4(g, h))
  end

  # IPv6 loopback (::1) and unspecified (::). Must precede the ::/96
  # compatible-address clause below, which would decode them as 0.0.0.1 /
  # 0.0.0.0 — same verdict, but the intent here is explicit.
  defp blocked_range?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_range?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # Deprecated IPv4-compatible IPv6 ::/96 (::a.b.c.d) — same embedded-v4 class
  # as the mapped/NAT64/6to4 clauses above: ::169.254.169.254 parses to
  # {0,0,0,0,0,0,0xA9FE,0xA9FE} and would otherwise fall through unblocked.
  defp blocked_range?({0, 0, 0, 0, 0, 0, g, h}) do
    blocked_range?(embedded_v4(g, h))
  end

  # SIIT / IPv4-translated ::ffff:0:a.b.c.d (::ffff:0:0/96 with a zero hextet
  # between the ffff marker and the embedded address).
  defp blocked_range?({0, 0, 0, 0, 0xFFFF, 0, g, h}) do
    blocked_range?(embedded_v4(g, h))
  end

  # Unique-local fc00::/7.
  defp blocked_range?({a, _, _, _, _, _, _, _}) when band(a, 0xFE00) == 0xFC00, do: true

  # Link-local fe80::/10 (the IPv6 analogue of 169.254.0.0/16).
  defp blocked_range?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFE80, do: true

  defp blocked_range?(_), do: false

  defp embedded_v4(g, h) do
    {band(bsr(g, 8), 0xFF), band(g, 0xFF), band(bsr(h, 8), 0xFF), band(h, 0xFF)}
  end

  defp ip_to_int({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
end
