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
      assert {:error, _} = UrlGuard.validate("gopher://example.com/foo")
    end

    test "rejects URLs without a scheme" do
      assert {:error, _} = UrlGuard.validate("example.com/foo")
    end

    test "rejects URLs without a host" do
      assert {:error, _} = UrlGuard.validate("https:///")
    end

    test "rejects AWS metadata IP (169.254.169.254)" do
      assert {:error, reason} = UrlGuard.validate("http://169.254.169.254/latest/meta-data/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects loopback (127.0.0.1)" do
      assert {:error, _} = UrlGuard.validate("http://127.0.0.1:8080/")
    end

    test "rejects RFC1918 private ranges" do
      for host <- ["10.0.0.1", "192.168.1.1", "172.16.0.1"] do
        assert {:error, _} = UrlGuard.validate("http://#{host}/")
      end
    end

    test "rejects IPv6 loopback ::1" do
      assert {:error, _} = UrlGuard.validate("http://[::1]/")
    end

    test "rejects IPv6 unspecified ::" do
      assert {:error, _} = UrlGuard.validate("http://[::]/")
    end

    test "rejects IPv4-mapped IPv6 pointing at cloud metadata" do
      # ::ffff:169.254.169.254 must normalize to the v4 blocklist, not slip
      # through the IPv6 catch-all.
      assert {:error, reason} = UrlGuard.validate("http://[::ffff:169.254.169.254]/")
      assert reason =~ "private/loopback/link-local"
    end

    test "rejects IPv4-mapped IPv6 loopback" do
      assert {:error, _} = UrlGuard.validate("http://[::ffff:127.0.0.1]/")
    end

    test "rejects IPv6 link-local fe80::/10" do
      assert {:error, _} = UrlGuard.validate("http://[fe80::1]/")
    end

    test "rejects NAT64-embedded metadata (64:ff9b::169.254.169.254)" do
      assert {:error, _} = UrlGuard.validate("http://[64:ff9b::a9fe:a9fe]/")
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
        assert {:error, _} = UrlGuard.validate(url), "expected #{url} to be refused"
      end
    end

    test "allows private hosts when allow_private_hosts: true" do
      assert {:ok, _} = UrlGuard.validate("http://127.0.0.1/", allow_private_hosts: true)
    end

    test "non-binary input is rejected" do
      assert {:error, _} = UrlGuard.validate(123)
    end
  end

  describe "validate_pinned/2 (DNS-rebinding defense)" do
    test "returns a validated IP to pin the connection to" do
      assert {:ok, %URI{host: "1.1.1.1"}, {1, 1, 1, 1}} =
               UrlGuard.validate_pinned("https://1.1.1.1/foo")
    end

    test "rejects a blocked address (no IP returned to pin)" do
      assert {:error, _} = UrlGuard.validate_pinned("http://169.254.169.254/")
    end

    test "rejects IPv4-mapped IPv6 metadata via pinned path too" do
      assert {:error, _} = UrlGuard.validate_pinned("http://[::ffff:169.254.169.254]/")
    end

    test "skips resolution and returns nil IP when allow_private_hosts: true" do
      assert {:ok, %URI{}, nil} =
               UrlGuard.validate_pinned("http://127.0.0.1/", allow_private_hosts: true)
    end
  end
end
