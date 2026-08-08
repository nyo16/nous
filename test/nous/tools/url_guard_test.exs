defmodule Nous.Tools.UrlGuardTest do
  use ExUnit.Case, async: true

  alias Nous.Tools.UrlGuard

  describe "validate/2" do
    test "accepts a public https URL" do
      assert {:ok, _uri} = UrlGuard.validate("https://example.com/foo")
    end

    test "rejects file:// scheme" do
      # file:/// has no authority, so URI returns "no host" - either failure
      # mode is acceptable, both block the SSRF.
      assert {:error, reason} = UrlGuard.validate("file://localhost/etc/passwd")
      assert reason =~ "scheme"
    end

    test "rejects gopher:// scheme" do
      assert {:error, reason} = UrlGuard.validate("gopher://example.com/foo")
      assert reason =~ ~s(scheme "gopher" is blocked)
    end

    test "rejects URLs without a scheme" do
      # "example.com/foo" has no authority at all, so URI parses the whole
      # thing as a path and the host check fires first. The scheme-missing
      # branch is reached by the protocol-relative form below. Both refuse.
      assert {:error, reason} = UrlGuard.validate("example.com/foo")
      assert reason =~ "no host"

      assert {:error, reason} = UrlGuard.validate("//example.com/foo")
      assert reason =~ "must include a scheme"
    end

    test "rejects URLs without a host" do
      assert {:error, reason} = UrlGuard.validate("https:///")
      assert reason =~ "no host"
    end

    test "rejects AWS metadata IP (169.254.169.254)" do
      assert {:error, reason} = UrlGuard.validate("http://169.254.169.254/latest/meta-data/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects loopback (127.0.0.1)" do
      assert {:error, reason} = UrlGuard.validate("http://127.0.0.1:8080/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects RFC1918 private ranges" do
      for host <- ["10.0.0.1", "192.168.1.1", "172.16.0.1"] do
        assert {:error, reason} = UrlGuard.validate("http://#{host}/")
        assert reason =~ "private/loopback/link-local"
        # The message names the offending host, so a copy/paste regression that
        # checked the wrong URL would be visible.
        assert reason =~ host
      end
    end

    test "rejects IPv6 loopback ::1" do
      assert {:error, reason} = UrlGuard.validate("http://[::1]/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects IPv6 unspecified ::" do
      assert {:error, reason} = UrlGuard.validate("http://[::]/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects IPv4-mapped IPv6 pointing at cloud metadata" do
      # ::ffff:169.254.169.254 must normalize to the v4 blocklist, not slip
      # through the IPv6 catch-all.
      assert {:error, reason} = UrlGuard.validate("http://[::ffff:169.254.169.254]/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects IPv4-mapped IPv6 loopback" do
      assert {:error, reason} = UrlGuard.validate("http://[::ffff:127.0.0.1]/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects IPv6 link-local fe80::/10" do
      assert {:error, reason} = UrlGuard.validate("http://[fe80::1]/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects IPv6 unique-local fc00::/7" do
      # ULA is the default address space for container and K8s overlay
      # networks, so this is the range an in-cluster SSRF actually targets.
      # Both halves of the /7 are covered: fc00::/8 and fd00::/8.
      for host <- ["fc00::1", "fd00::1", "fdff:ffff::1"] do
        assert {:error, reason} = UrlGuard.validate("http://[#{host}]/")
        assert reason =~ "private/loopback/link-local"
      end
    end

    test "still accepts a public IPv6 literal" do
      # Negative control for the two IPv6 masks above: a mask wide enough to
      # swallow global unicast would pass every fc00::/7 case and break every
      # real fetch, which no other test in this file would notice.
      assert {:ok, _uri} = UrlGuard.validate("http://[2606:4700:4700::1111]/")
    end

    test "rejects NAT64-embedded metadata (64:ff9b::169.254.169.254)" do
      assert {:error, reason} = UrlGuard.validate("http://[64:ff9b::a9fe:a9fe]/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects alternate-encoding IP forms for loopback/metadata" do
      # Classic SSRF bypasses: the host is an obfuscated encoding of a blocked
      # address. The BEAM resolver expands decimal/hex/octal integer hosts to
      # their real address, which then trips the private/loopback blocklist; the
      # %2F form fails to resolve. All must be refused, never fetched.
      bypasses = [
        # 0x7f000001 -> 127.0.0.1 (hex)
        "http://0x7f000001/",
        # 2130706433 -> 127.0.0.1 (decimal)
        "http://2130706433/",
        # 0177.0.0.1 -> 127.0.0.1 (octal first octet)
        "http://0177.0.0.1/",
        # url-encoded slash smuggled into the metadata authority
        "http://169.254.169.254%2F"
      ]

      for url <- bypasses do
        assert {:error, reason} = UrlGuard.validate(url), "expected #{url} to be refused"

        # Unlike the IP-literal cases above, which stage catches these depends
        # on the host resolver: an expanding resolver hands back 127.0.0.1 and
        # the blocklist fires, a strict one fails to resolve the bogus name.
        # Either is a correct refusal; a scheme- or parse-stage rejection is
        # NOT, because it would mean the host was never examined and the same
        # address in a plain dotted-quad wrapper could slip through.
        assert reason =~ "private/loopback/link-local" or reason =~ "Could not resolve",
               "#{url} was refused at the wrong stage: #{reason}"
      end
    end

    test "allows private hosts when allow_private_hosts: true" do
      assert {:ok, _} = UrlGuard.validate("http://127.0.0.1/", allow_private_hosts: true)
    end

    test "non-binary input is rejected" do
      assert {:error, reason} = UrlGuard.validate(123)
      assert reason =~ "must be a string"
    end
  end

  describe "validate_pinned/2 (DNS-rebinding defense)" do
    test "returns a validated IP to pin the connection to" do
      assert {:ok, %URI{host: "1.1.1.1"}, {1, 1, 1, 1}} =
               UrlGuard.validate_pinned("https://1.1.1.1/foo")
    end

    test "rejects a blocked address (no IP returned to pin)" do
      assert {:error, reason} = UrlGuard.validate_pinned("http://169.254.169.254/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects IPv4-mapped IPv6 metadata via pinned path too" do
      assert {:error, reason} = UrlGuard.validate_pinned("http://[::ffff:169.254.169.254]/")
      assert reason =~ "private/loopback/link-local"
    end

    test "skips resolution and returns nil IP when allow_private_hosts: true" do
      assert {:ok, %URI{}, nil} =
               UrlGuard.validate_pinned("http://127.0.0.1/", allow_private_hosts: true)
    end
  end

  # The escape hatch that lets Bypass-backed tests reach 127.0.0.1 lives in
  # address_blocked?/1. Pin the default so a future refactor cannot quietly
  # ship a non-empty allowlist and silently open loopback to every caller.
  describe ":url_guard_allow_ips escape hatch" do
    test "defaults to empty, so loopback is still blocked with no config set" do
      assert Application.get_env(:nous, :url_guard_allow_ips, :unset) in [:unset, []]

      assert {:error, reason} = UrlGuard.validate("http://127.0.0.1/")
      assert reason =~ "private/loopback/link-local"

      assert {:error, reason} = UrlGuard.validate_pinned("http://127.0.0.1/")
      assert reason =~ "private/loopback/link-local"
    end
  end
end
