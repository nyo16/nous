# HTTP backend benchmark against a real LLM endpoint.
#
# Reads creds from env so no secrets land in source:
#
#     OPENROUTER_API_KEY=sk-or-... \
#     OPENROUTER_MODEL=nvidia/nemotron-nano-9b-v2:free \
#       mix run bench/http_backend_real.exs
#
# Companion to `bench/http_backend.exs` (localhost). The localhost run
# measures pure client overhead; this one measures what users actually
# experience — TLS handshake, real network latency, real LLM
# response-time variance.
#
# Custom timing (not Benchee) so we control exactly how many requests
# fire — important for free-tier endpoints where Benchee's `time:`
# config can blow past rate-limit caps and corrupt the measurement.

{:ok, _} = Application.ensure_all_started(:hackney)
{:ok, _} = Application.ensure_all_started(:req)

alias Nous.HTTP.Backend.{Hackney, Req}

api_key =
  System.get_env("OPENROUTER_API_KEY") ||
    raise "Set OPENROUTER_API_KEY before running this bench"

model = System.get_env("OPENROUTER_MODEL", "nvidia/nemotron-nano-9b-v2:free")
max_tokens = System.get_env("OPENROUTER_MAX_TOKENS", "8") |> String.to_integer()
url = "https://openrouter.ai/api/v1/chat/completions"

headers = [
  {"authorization", "Bearer #{api_key}"},
  {"content-type", "application/json"},
  # OpenRouter wants these for analytics; using nous's GitHub.
  {"http-referer", "https://github.com/nyo16/nous"},
  {"x-title", "Nous HTTP backend benchmark"}
]

body = %{
  "model" => model,
  "max_tokens" => max_tokens,
  "messages" => [
    %{"role" => "user", "content" => "Reply with exactly: pong"}
  ]
}

IO.puts("Model: #{model}")
IO.puts("Max tokens: #{max_tokens}")

# ----- Helpers ---------------------------------------------------------------

defmodule BenchHelper do
  def time_one(backend, url, body, headers) do
    {us, result} = :timer.tc(fn -> backend.post(url, body, headers, timeout: 120_000) end)

    status =
      case result do
        {:ok, _} -> :ok
        {:error, %{status: 429}} -> :rate_limited
        {:error, %{status: status}} -> {:http_error, status}
        {:error, err} -> {:transport_error, err}
      end

    %{us: us, status: status}
  end

  def percentile(samples, p) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    idx = max(0, min(n - 1, round(p / 100 * (n - 1))))
    Enum.at(sorted, idx)
  end

  def summarize(label, results) do
    {ok, errs} = Enum.split_with(results, &(&1.status == :ok))
    times_ms = Enum.map(ok, fn r -> r.us / 1000 end)
    rate_limited = Enum.count(errs, &(&1.status == :rate_limited))
    other_errs = Enum.count(errs) - rate_limited

    if times_ms == [] do
      IO.puts(
        "#{label}: no successful samples (#{rate_limited} rate-limited, #{other_errs} other errors)"
      )
    else
      total = Enum.sum(times_ms)
      n = length(times_ms)

      IO.puts(
        "#{label}: n=#{n} (#{rate_limited} rate-limited, #{other_errs} other) " <>
          "p50=#{Float.round(percentile(times_ms, 50), 1)}ms " <>
          "p95=#{Float.round(percentile(times_ms, 95), 1)}ms " <>
          "min=#{Float.round(Enum.min(times_ms), 1)}ms " <>
          "max=#{Float.round(Enum.max(times_ms), 1)}ms " <>
          "mean=#{Float.round(total / n, 1)}ms"
      )
    end
  end

  # Pace requests to stay under rate limits. 4s gap = 15 req/min,
  # comfortably under typical free-tier 20/min caps.
  def sequential(backend, url, body, headers, n, gap_ms) do
    Enum.map(1..n, fn i ->
      result = time_one(backend, url, body, headers)
      if i < n, do: Process.sleep(gap_ms)
      result
    end)
  end

  def parallel_batch(backend, url, body, headers, parallelism) do
    1..parallelism
    |> Enum.map(fn _ ->
      Task.async(fn -> time_one(backend, url, body, headers) end)
    end)
    |> Task.await_many(180_000)
  end
end

# ----- Smoke test ------------------------------------------------------------

IO.puts("=== Smoke test ===")
sm_req = BenchHelper.time_one(Req, url, body, headers)
sm_hk = BenchHelper.time_one(Hackney, url, body, headers)
IO.puts("Req: #{inspect(sm_req.status)} in #{Float.round(sm_req.us / 1000, 1)}ms")
IO.puts("Hackney: #{inspect(sm_hk.status)} in #{Float.round(sm_hk.us / 1000, 1)}ms")

if sm_req.status != :ok or sm_hk.status != :ok do
  IO.puts("Smoke test failed; aborting bench.")
  System.halt(1)
end

# ----- Sequential ------------------------------------------------------------
#
# 10 reqs per backend, 4s gap = ~40s per backend. Total budget:
# 20 reqs spread over ~80s. Stays under 20 req/min.

IO.puts("\n=== Sequential (n=10, 4s pacing) ===")
seq_req = BenchHelper.sequential(Req, url, body, headers, 10, 4_000)
BenchHelper.summarize("Req     sequential", seq_req)
seq_hk = BenchHelper.sequential(Hackney, url, body, headers, 10, 4_000)
BenchHelper.summarize("Hackney sequential", seq_hk)

# Pause to let the rate-limit bucket refill before parallel.
Process.sleep(20_000)

# ----- Parallel --------------------------------------------------------------
#
# 3 batches of 5 parallel reqs per backend = 30 reqs total, paced.

IO.puts("\n=== Parallel batches (3 × 5 concurrent, 15s gap between batches) ===")

par_req =
  Enum.flat_map(1..3, fn batch ->
    res = BenchHelper.parallel_batch(Req, url, body, headers, 5)
    if batch < 3, do: Process.sleep(15_000)
    res
  end)

BenchHelper.summarize("Req     parallel", par_req)

Process.sleep(20_000)

par_hk =
  Enum.flat_map(1..3, fn batch ->
    res = BenchHelper.parallel_batch(Hackney, url, body, headers, 5)
    if batch < 3, do: Process.sleep(15_000)
    res
  end)

BenchHelper.summarize("Hackney parallel", par_hk)

IO.puts("\nDone.")
