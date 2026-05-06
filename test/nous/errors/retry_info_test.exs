defmodule Nous.Errors.RetryInfoTest do
  use ExUnit.Case, async: true

  alias Nous.Errors.RetryInfo

  describe "parse/1 — Google body shape" do
    test "extracts retryDelay from RetryInfo detail" do
      error = %{
        status: 429,
        body: %{
          "error" => %{
            "code" => 429,
            "status" => "RESOURCE_EXHAUSTED",
            "details" => [
              %{"@type" => "type.googleapis.com/google.rpc.QuotaFailure", "violations" => []},
              %{
                "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                "retryDelay" => "34s"
              }
            ]
          }
        }
      }

      assert RetryInfo.parse(error) == 34_000
    end

    test "handles fractional second durations" do
      error = %{
        body: %{
          "error" => %{
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                "retryDelay" => "1.5s"
              }
            ]
          }
        }
      }

      assert RetryInfo.parse(error) == 1500
    end

    test "returns nil when details exist but no RetryInfo entry" do
      # Daily-quota exhaustion deliberately omits RetryInfo — absence is
      # the signal not to retry-loop.
      error = %{
        status: 429,
        body: %{
          "error" => %{
            "details" => [
              %{"@type" => "type.googleapis.com/google.rpc.QuotaFailure", "violations" => []}
            ]
          }
        }
      }

      assert RetryInfo.parse(error) == nil
    end

    test "returns nil for malformed retryDelay" do
      error = %{
        body: %{
          "error" => %{
            "details" => [
              %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => "soon"}
            ]
          }
        }
      }

      assert RetryInfo.parse(error) == nil
    end

    test "returns nil for zero or negative delay" do
      error = %{
        body: %{
          "error" => %{
            "details" => [
              %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => "0s"}
            ]
          }
        }
      }

      assert RetryInfo.parse(error) == nil
    end

    test "returns nil when error body has no details key" do
      error = %{status: 500, body: %{"error" => %{"message" => "internal"}}}
      assert RetryInfo.parse(error) == nil
    end
  end

  describe "parse/1 — Retry-After header" do
    test "extracts integer seconds from Retry-After" do
      error = %{status: 429, headers: [{"retry-after", "60"}]}
      assert RetryInfo.parse(error) == 60_000
    end

    test "matches Retry-After case-insensitively" do
      error = %{status: 429, headers: [{"Retry-After", "30"}]}
      assert RetryInfo.parse(error) == 30_000
    end

    test "returns nil for non-integer Retry-After (e.g. HTTP-date)" do
      # HTTP-date form intentionally not handled; no LLM provider uses it.
      error = %{status: 429, headers: [{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}]}
      assert RetryInfo.parse(error) == nil
    end

    test "returns nil for negative seconds" do
      error = %{status: 429, headers: [{"retry-after", "-5"}]}
      assert RetryInfo.parse(error) == nil
    end
  end

  describe "parse/1 — precedence and edge cases" do
    test "body takes precedence over header when both present" do
      error = %{
        status: 429,
        body: %{
          "error" => %{
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                "retryDelay" => "10s"
              }
            ]
          }
        },
        headers: [{"retry-after", "60"}]
      }

      assert RetryInfo.parse(error) == 10_000
    end

    test "falls back to headers when body has no RetryInfo" do
      error = %{
        status: 429,
        body: %{"error" => %{"message" => "rate limited"}},
        headers: [{"retry-after", "5"}]
      }

      assert RetryInfo.parse(error) == 5_000
    end

    test "tolerates missing :headers key" do
      error = %{status: 429, body: %{"error" => %{"message" => "no info"}}}
      assert RetryInfo.parse(error) == nil
    end

    test "tolerates missing :body key" do
      error = %{status: 429, headers: [{"retry-after", "12"}]}
      assert RetryInfo.parse(error) == 12_000
    end

    test "returns nil for non-map input" do
      assert RetryInfo.parse(:transport_error) == nil
      assert RetryInfo.parse(nil) == nil
      assert RetryInfo.parse("oops") == nil
    end

    test "returns nil for entirely empty error map" do
      assert RetryInfo.parse(%{}) == nil
    end
  end
end
