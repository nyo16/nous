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
  def validate(url, opts \\ [])

  def validate(url, _opts) when not is_binary(url) do
    {:error, "URL must be a string"}
  end

  def validate(url, opts) do
    allow_private = Keyword.get(opts, :allow_private_hosts, false)

    with {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri),
         :ok <- check_host(uri, allow_private) do
      {:ok, uri}
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

  defp check_host(_uri, true), do: :ok

  defp check_host(%URI{host: host}, false) do
    case resolve_host(host) do
      {:ok, addrs} ->
        if Enum.any?(addrs, &address_blocked?/1) do
          {:error,
           "URL resolves to a private/loopback/link-local address; refusing to fetch (#{host})"}
        else
          :ok
        end

      {:error, reason} ->
        {:error, "Could not resolve #{host}: #{inspect(reason)}"}
    end
  end

  # Resolve a host name to its IP addresses. If the input is already an IP
  # literal, just parse it.
  defp resolve_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} ->
        {:ok, [addr]}

      {:error, _} ->
        # Not a literal; do a DNS lookup
        case :inet.getaddrs(String.to_charlist(host), :inet) do
          {:ok, addrs} -> {:ok, addrs}
          {:error, _} = err -> err
        end
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

  # IPv6 - block loopback (::1) and unique local (fc00::/7) at minimum.
  defp address_blocked?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp address_blocked?({a, _, _, _, _, _, _, _})
       when band(a, 0xFE00) == 0xFC00,
       do: true

  defp address_blocked?(_), do: false

  defp ip_to_int({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
end
