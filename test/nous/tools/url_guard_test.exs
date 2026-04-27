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

    test "allows private hosts when allow_private_hosts: true" do
      assert {:ok, _} = UrlGuard.validate("http://127.0.0.1/", allow_private_hosts: true)
    end

    test "non-binary input is rejected" do
      assert {:error, _} = UrlGuard.validate(123)
    end
  end
end
