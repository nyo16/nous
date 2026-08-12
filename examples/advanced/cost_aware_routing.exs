#!/usr/bin/env elixir

# Nous AI - Cost-Aware Model Routing
# Pick a model per request from a price/capability table, bill each run from
# %Nous.Usage{} (prompt-cache counters included), and fail over with :fallback.
#
# Three documented features, wired into one loop:
#
#   1. [:nous, :agent, :run, :stop] telemetry
#      Measurements: duration, total_tokens, input_tokens, output_tokens,
#      tool_calls, requests, iterations.
#      Metadata: agent_name, model_provider, model_name, active_model_provider,
#      active_model_name, fallback_used.
#      Only telemetry tells you WHICH model actually served the run, so it is
#      what decides who gets billed once a fallback fires.
#
#   2. %Nous.Usage{} prompt-cache counters (0.16.2)
#      cache_creation_input_tokens and cache_read_input_tokens are billed at
#      different rates than fresh input_tokens - a tracker that reads
#      input_tokens only is wrong in both directions. Note these two counters
#      are NOT in the run.stop measurements, so the cost math below reads
#      result.usage, not the telemetry payload.
#
#   3. :fallback on Nous.new/2
#      Provider failover, demonstrated for real: a primary pointed at a dead
#      loopback port, with a canned OpenAI-compatible stub server behind it.
#
# Runs offline, with no API key and no network egress:
#
#     mix run examples/advanced/cost_aware_routing.exs
#
# What is real and what is simulated:
#
#   * SIMULATED - the routing batch (section 4). The %Nous.Usage{} values are
#     hand-written literals so the cache-pricing paths are deterministic and
#     key-free. They flow through the exact same Ledger.record/4 -> Pricing.cost/2
#     code path as everything else.
#   * REAL, offline - the failover run (section 5). A real Nous.run/2, a real
#     [:nous, :agent, :run, :stop] event, real result.usage, served by a
#     loopback :gen_tcp stub. Local inference is priced at $0, matching the
#     Nous.Eval.Config defaults for lmstudio/ollama/vllm.
#   * REAL, network - section 6 only, and only if ANTHROPIC_API_KEY is set.
#     Anthropic is the interesting provider here: Nous.Messages.Anthropic
#     .parse_usage/1 is the one parser that fills BOTH cache counters.

require Logger

# The runner logs an info line per run; keep the demo output readable but leave
# warnings on, because the fallback hop in section 5 logs one.
Logger.configure(level: :warning)

IO.puts("=== Nous AI - Cost-Aware Model Routing ===\n")

# ============================================================================
# 1. Price Table
# ============================================================================
#
# USD per 1M tokens. Illustrative list prices - check your provider's pricing
# page before trusting a number here.
#
# :cache_write and :cache_read are separate columns on purpose. Anthropic bills
# a premium to WRITE a prompt-cache entry and ~10% of the input rate to READ
# one; OpenAI charges 50% for a cached read and nothing extra to write. One
# "cache multiplier" cannot express both.
#
# :convention says how the provider REPORTS the counters, which decides what
# "fresh input" means:
#
#   :separate  - cache_* tokens are not included in input_tokens.
#                See Nous.Messages.Anthropic.parse_usage/1.
#   :inclusive - cache_read_input_tokens is a subset of input_tokens, so fresh
#                input = input_tokens - cache_read_input_tokens. See
#                Nous.Messages.Gemini.parse_usage/1, which maps Gemini's
#                cachedContentTokenCount (part of promptTokenCount).
#
# Nous does ship a cost helper - Nous.Eval.Config.estimate_cost/3 - but it is
# per-PROVIDER, per-1K, and cache-blind. Section 7 contrasts the two.

defmodule Pricing do
  @unpriced %{
    input: 0.0,
    cache_write: 0.0,
    cache_read: 0.0,
    output: 0.0,
    tier: :unknown,
    convention: :separate,
    note: "unpriced model"
  }

  @table %{
    "openai:gpt-4o-mini" => %{
      input: 0.15,
      cache_write: 0.15,
      cache_read: 0.075,
      output: 0.60,
      tier: :small,
      convention: :separate,
      note: "short answers, no tools"
    },
    "anthropic:claude-3-5-haiku-latest" => %{
      input: 0.80,
      cache_write: 1.00,
      cache_read: 0.08,
      output: 4.00,
      tier: :medium,
      convention: :separate,
      note: "tool use, medium context"
    },
    "anthropic:claude-sonnet-4-5" => %{
      input: 3.00,
      cache_write: 3.75,
      cache_read: 0.30,
      output: 15.00,
      tier: :large,
      convention: :separate,
      note: "hard reasoning, long refactors"
    },
    "gemini:gemini-2.5-flash" => %{
      input: 0.30,
      cache_write: 0.30,
      cache_read: 0.075,
      output: 2.50,
      tier: :medium,
      convention: :inclusive,
      note: "cache-inclusive usage counters"
    },
    # Failover target in section 5. Local inference is free, so it prices to
    # $0 - which is exactly why a router should prefer it when it is healthy.
    "lmstudio:stub-8b" => %{
      input: 0.0,
      cache_write: 0.0,
      cache_read: 0.0,
      output: 0.0,
      tier: :small,
      convention: :separate,
      note: "local, free"
    }
  }

  def table, do: @table

  def rates(model_key), do: Map.get(@table, model_key, @unpriced)

  # Fresh (uncached) input tokens, per the provider's reporting convention.
  def fresh_input_tokens(model_key, %Nous.Usage{} = usage) do
    case rates(model_key).convention do
      :separate -> usage.input_tokens
      :inclusive -> max(usage.input_tokens - usage.cache_read_input_tokens, 0)
    end
  end

  # The whole point of the example: four token buckets, four rates.
  def cost(model_key, %Nous.Usage{} = usage) do
    r = rates(model_key)
    fresh = fresh_input_tokens(model_key, usage)

    input = per_million(fresh, r.input)
    cache_write = per_million(usage.cache_creation_input_tokens, r.cache_write)
    cache_read = per_million(usage.cache_read_input_tokens, r.cache_read)
    output = per_million(usage.output_tokens, r.output)

    # Counterfactual: no prompt cache at all, so every input token is fresh.
    naive =
      per_million(
        fresh + usage.cache_creation_input_tokens + usage.cache_read_input_tokens,
        r.input
      ) + output

    %{
      fresh_input_tokens: fresh,
      input: input,
      cache_write: cache_write,
      cache_read: cache_read,
      output: output,
      total: input + cache_write + cache_read + output,
      uncached_total: naive
    }
  end

  defp per_million(tokens, rate_per_million), do: tokens / 1_000_000 * rate_per_million
end

# ============================================================================
# 2. Ledger (the single accounting path)
# ============================================================================
#
# One process holds the running spend. Elixir's Agent, not Nous.Agent: the
# telemetry handler runs in the caller process, so the router and the handler
# both need to read the same ledger.
#
# Every source of usage - simulated literals, the offline failover run, the
# optional live cloud run - is recorded through record/4. If the accounting
# lived in two places it would drift in two directions.

defmodule Ledger do
  use Agent

  def start_link(budget_usd) do
    Agent.start_link(fn -> %{budget: budget_usd, entries: []} end, name: __MODULE__)
  end

  def record(model_key, %Nous.Usage{} = usage, source, label) do
    breakdown = Pricing.cost(model_key, usage)

    entry = %{
      model: model_key,
      usage: usage,
      cost: breakdown,
      source: source,
      label: label
    }

    Agent.update(__MODULE__, fn state -> %{state | entries: [entry | state.entries]} end)
    breakdown
  end

  def entries, do: Agent.get(__MODULE__, fn s -> Enum.reverse(s.entries) end)
  def budget, do: Agent.get(__MODULE__, fn s -> s.budget end)
  def spent, do: Enum.reduce(entries(), 0.0, fn e, acc -> acc + e.cost.total end)
  def remaining, do: budget() - spent()
end

budget_usd = 0.05
{:ok, _ledger} = Ledger.start_link(budget_usd)

usd = fn amount -> "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 6) end
pad = fn value, width -> String.pad_trailing(to_string(value), width) end
rpad = fn value, width -> String.pad_leading(to_string(value), width) end

IO.puts("--- Price Table (USD per 1M tokens) ---\n")

IO.puts(
  pad.("model", 36) <>
    rpad.("input", 8) <>
    rpad.("c-write", 9) <> rpad.("c-read", 8) <> rpad.("output", 8) <> "  tier"
)

Pricing.table()
|> Enum.sort_by(fn {_key, r} -> {r.input, r.output} end)
|> Enum.each(fn {key, r} ->
  IO.puts(
    pad.(key, 36) <>
      rpad.(r.input, 8) <>
      rpad.(r.cache_write, 9) <>
      rpad.(r.cache_read, 8) <>
      rpad.(r.output, 8) <>
      "  #{r.tier} (#{r.note})"
  )
end)

IO.puts("\nBudget for this run: #{usd.(budget_usd)}\n")

# ============================================================================
# 3. The Router
# ============================================================================
#
# Two inputs: the shape of the request, and how much budget is left. The
# decision and its reason are returned so they can be printed, logged, or
# asserted on in a test - a router whose choices are invisible is untestable.

defmodule Router do
  @tier_models %{
    small: "openai:gpt-4o-mini",
    medium: "anthropic:claude-3-5-haiku-latest",
    large: "anthropic:claude-sonnet-4-5"
  }

  # Words that reliably mean "this is not a one-liner".
  @hard_words ~w(prove refactor design architect debug why derive migrate audit)

  def route(prompt, opts \\ []) do
    needs_tools = Keyword.get(opts, :needs_tools, false)
    remaining = Keyword.get(opts, :remaining, :infinity)
    budget = Keyword.get(opts, :budget, :infinity)

    score = complexity(prompt, needs_tools)
    wanted = tier_for(score)
    {tier, reason} = apply_budget_guard(wanted, score, remaining, budget)

    %{
      model: Map.fetch!(@tier_models, tier),
      tier: tier,
      wanted_tier: wanted,
      score: score,
      reason: reason
    }
  end

  # Deterministic, offline, and cheap: length, hard-word hits, tool need.
  def complexity(prompt, needs_tools) do
    words = prompt |> String.split(~r/\s+/, trim: true) |> length()
    length_points = min(words / 40, 3.0)

    hard_points =
      @hard_words
      |> Enum.count(&String.contains?(String.downcase(prompt), &1))
      |> Kernel.*(2)

    tool_points = if needs_tools, do: 1.5, else: 0.0

    Float.round(length_points + hard_points + tool_points, 2)
  end

  defp tier_for(score) when score < 1.5, do: :small
  defp tier_for(score) when score < 4.0, do: :medium
  defp tier_for(_score), do: :large

  # A budget guard is the reason routing needs the ledger and not just the
  # prompt: past the threshold, expensive tiers are refused outright.
  defp apply_budget_guard(wanted, score, remaining, budget)
       when is_number(remaining) and is_number(budget) do
    headroom = if budget > 0, do: remaining / budget, else: 0.0
    pct = Float.round(headroom * 100, 1)

    cond do
      headroom <= 0.2 and wanted != :small ->
        {:small, "budget guard: #{pct}% headroom, downgraded #{wanted} -> small"}

      wanted == :large and headroom < 0.5 ->
        {:medium, "budget guard: #{pct}% headroom, capped large -> medium"}

      true ->
        {wanted, "complexity #{score} -> #{wanted}"}
    end
  end

  defp apply_budget_guard(wanted, score, _remaining, _budget),
    do: {wanted, "complexity #{score} -> #{wanted}"}
end

# ============================================================================
# 4. SIMULATED batch - routing decisions and cache-aware billing
# ============================================================================
#
# The %Nous.Usage{} literals below stand in for provider responses so this
# section needs no key and no network. Note how requests 2 and 3 send the same
# 4,200-token shared prefix: request 2 pays the cache WRITE premium, request 3
# reads it back at a tenth of the input rate.

IO.puts("--- Routing Batch (SIMULATED usage) ---\n")

simulated = [
  %{
    prompt: "Convert 32F to Celsius.",
    needs_tools: false,
    usage: %Nous.Usage{
      requests: 1,
      input_tokens: 24,
      output_tokens: 12,
      total_tokens: 36
    }
  },
  %{
    prompt:
      "Using the attached 4k-token style guide, rewrite this release note in one sentence. " <>
        "Keep the product name and the version number intact.",
    needs_tools: true,
    usage: %Nous.Usage{
      requests: 1,
      input_tokens: 190,
      output_tokens: 70,
      total_tokens: 260,
      # First call with this prefix: Nous pays to warm the cache.
      cache_creation_input_tokens: 4200
    }
  },
  %{
    prompt:
      "Using the attached 4k-token style guide, rewrite this changelog entry in one sentence. " <>
        "Keep the ticket reference intact.",
    needs_tools: true,
    usage: %Nous.Usage{
      requests: 1,
      input_tokens: 180,
      output_tokens: 65,
      total_tokens: 245,
      # Same prefix, second call: cache hit.
      cache_read_input_tokens: 4200
    }
  },
  %{
    prompt:
      "Prove that the retry loop below terminates for every input, then refactor it to " <>
        "use exponential backoff with jitter and explain why the new bound holds. " <>
        "Walk through the failure modes you considered and why you rejected each one.",
    needs_tools: false,
    usage: %Nous.Usage{
      requests: 1,
      input_tokens: 1450,
      output_tokens: 1100,
      total_tokens: 2550,
      cache_read_input_tokens: 3900
    }
  },
  %{
    prompt:
      "Design the sharding strategy for the audit log and prove the rebalance is safe " <>
        "under concurrent writes.",
    needs_tools: true,
    usage: %Nous.Usage{
      requests: 1,
      input_tokens: 900,
      output_tokens: 400,
      total_tokens: 1300,
      cache_read_input_tokens: 4200
    }
  }
]

Enum.each(simulated, fn request ->
  decision =
    Router.route(request.prompt,
      needs_tools: request.needs_tools,
      remaining: Ledger.remaining(),
      budget: Ledger.budget()
    )

  cost = Ledger.record(decision.model, request.usage, :simulated, decision.reason)

  IO.puts("prompt:   #{String.slice(request.prompt, 0, 68)}...")
  IO.puts("route:    #{decision.model}  [#{decision.reason}]")

  IO.puts(
    "tokens:   fresh_in=#{cost.fresh_input_tokens} " <>
      "cache_write=#{request.usage.cache_creation_input_tokens} " <>
      "cache_read=#{request.usage.cache_read_input_tokens} " <>
      "out=#{request.usage.output_tokens}"
  )

  IO.puts(
    "cost:     #{usd.(cost.total)} " <>
      "(in #{usd.(cost.input)} + write #{usd.(cost.cache_write)} + " <>
      "read #{usd.(cost.cache_read)} + out #{usd.(cost.output)})"
  )

  cond do
    cost.uncached_total > cost.total ->
      saved = cost.uncached_total - cost.total
      IO.puts("cache:    saved #{usd.(saved)} vs. #{usd.(cost.uncached_total)} with no cache")

    cost.uncached_total < cost.total ->
      premium = cost.total - cost.uncached_total
      IO.puts(
        "cache:    paid #{usd.(premium)} extra to WARM the prefix " <>
          "(pays back on the next hit)"
      )

    true ->
      :ok
  end

  IO.puts("budget:   #{usd.(Ledger.remaining())} of #{usd.(Ledger.budget())} left\n")
end)

# ============================================================================
# 4b. Why :convention is a column and not a constant
# ============================================================================
#
# The SAME counters mean different things per provider. Price one usage struct
# both ways: under :separate the cached tokens are extra, under :inclusive they
# are already inside input_tokens and must be subtracted or they get billed
# twice.

IO.puts("--- Reporting Conventions (SIMULATED usage) ---\n")

shared_usage = %Nous.Usage{
  requests: 1,
  input_tokens: 5000,
  output_tokens: 200,
  total_tokens: 5200,
  cache_read_input_tokens: 4500
}

Enum.each(
  ["anthropic:claude-3-5-haiku-latest", "gemini:gemini-2.5-flash"],
  fn model_key ->
    r = Pricing.rates(model_key)
    cost = Pricing.cost(model_key, shared_usage)

    IO.puts(
      "#{pad.(model_key, 36)} convention=#{pad.(r.convention, 11)} " <>
        "fresh_in=#{rpad.(cost.fresh_input_tokens, 5)} total=#{usd.(cost.total)}"
    )
  end
)

IO.puts("""

input_tokens=5000 with cache_read_input_tokens=4500 is 5000 fresh tokens on
Anthropic and only 500 on Gemini. Same struct, different bill.
""")

# ============================================================================
# 5. REAL run, offline - telemetry + :fallback failover
# ============================================================================
#
# A dependency-free loopback HTTP server returns one canned OpenAI-shaped chat
# completion, so the failover below is a real Nous.run/2 with real telemetry and
# no network egress.

defmodule StubServer do
  # Bound to 127.0.0.1 on an ephemeral port. The listening socket is created
  # inside the spawned process because inet sockets are only usable by their
  # controlling process.
  def start(response_body) do
    parent = self()

    spawn_link(fn ->
      case :gen_tcp.listen(0, [
             :binary,
             ip: {127, 0, 0, 1},
             packet: :raw,
             active: false,
             reuseaddr: true
           ]) do
        {:ok, listen} ->
          {:ok, port} = :inet.port(listen)
          send(parent, {:stub_port, port})
          accept_loop(listen, response_body)

        {:error, reason} ->
          send(parent, {:stub_failed, reason})
      end
    end)

    receive do
      {:stub_port, port} -> {:ok, port}
      {:stub_failed, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp accept_loop(listen, body) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        read_request(socket, "")
        :gen_tcp.send(socket, http_response(body))
        :gen_tcp.close(socket)
        accept_loop(listen, body)

      {:error, _closed} ->
        :ok
    end
  end

  # Read until the request body is complete, so the client never sees a reply
  # to a request it has not finished sending.
  defp read_request(socket, acc) do
    if complete?(acc) do
      :ok
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> read_request(socket, acc <> data)
        {:error, _} -> :ok
      end
    end
  end

  defp complete?(acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
          [_, len] -> byte_size(body) >= String.to_integer(len)
          nil -> true
        end

      _ ->
        false
    end
  end

  defp http_response(body) do
    "HTTP/1.1 200 OK\r\n" <>
      "content-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <> body
  end
end

IO.puts("--- Failover (REAL run, offline) ---\n")

stub_body =
  JSON.encode!(%{
    "id" => "chatcmpl-stub",
    "object" => "chat.completion",
    "model" => "stub-8b",
    "choices" => [
      %{
        "index" => 0,
        "message" => %{"role" => "assistant", "content" => "4"},
        "finish_reason" => "stop"
      }
    ],
    "usage" => %{"prompt_tokens" => 412, "completion_tokens" => 6, "total_tokens" => 418}
  })

# Telemetry: the run.stop handler is the only place that knows which model
# actually answered, so it forwards that to the script process. Cost is billed
# from result.usage, because run.stop measurements carry no cache counters.
:telemetry.attach(
  "cost-routing-run-stop",
  [:nous, :agent, :run, :stop],
  fn _event, measurements, metadata, pid ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    intended = "#{metadata.model_provider}:#{metadata.model_name}"
    active = "#{metadata.active_model_provider}:#{metadata.active_model_name}"

    IO.puts("[run.stop] agent=#{metadata.agent_name} #{duration_ms}ms")
    IO.puts(
      "[run.stop] intended=#{intended} active=#{active} " <>
        "fallback_used=#{metadata.fallback_used}"
    )

    IO.puts(
      "[run.stop] measurements: in=#{measurements.input_tokens} " <>
        "out=#{measurements.output_tokens} total=#{measurements.total_tokens} " <>
        "requests=#{measurements.requests} iterations=#{measurements.iterations} " <>
        "tool_calls=#{measurements.tool_calls}"
    )

    send(pid, {:run_stop, active})
  end,
  self()
)

:telemetry.attach(
  "cost-routing-fallback-hop",
  [:nous, :fallback, :activated],
  fn _event, _measurements, metadata, _config ->
    IO.puts(
      "[fallback.activated] #{metadata.failed_provider}:#{metadata.failed_model} -> " <>
        "#{metadata.next_provider}:#{metadata.next_model}"
    )
  end,
  nil
)

:telemetry.attach(
  "cost-routing-fallback-used",
  [:nous, :agent, :fallback, :used],
  fn _event, _measurements, metadata, _config ->
    IO.puts(
      "[agent.fallback.used] #{metadata.agent_name} ran on " <>
        "#{metadata.active_provider}:#{metadata.active_model}"
    )
  end,
  nil
)

case StubServer.start(stub_body) do
  {:ok, stub_port} ->
    IO.puts("Loopback stub listening on 127.0.0.1:#{stub_port}\n")

    # The endpoint override MUST go through :base_url. There is no
    # "provider:model@http://host" model-string syntax - Nous.Model.parse/2
    # would treat the whole tail as the model NAME.
    #
    # Nous.Agent.new/2 parses fallback STRINGS with no options, so a fallback
    # that needs its own base_url has to be passed as a %Nous.Model{} struct.
    stub_model =
      Nous.Model.parse("lmstudio:stub-8b", base_url: "http://127.0.0.1:#{stub_port}/v1")

    failover_agent =
      Nous.new("lmstudio:primary-down",
        name: "cost-router",
        instructions: "Answer with just the number.",
        # Port 1 has nothing listening: the request fails with a ProviderError,
        # which is the error class :fallback is eligible for.
        base_url: "http://127.0.0.1:1/v1",
        fallback: [stub_model]
      )

    IO.puts("primary:  lmstudio:primary-down @ http://127.0.0.1:1/v1 (dead)")
    IO.puts("fallback: #{stub_model.provider}:#{stub_model.model} @ #{stub_model.base_url}\n")

    case Nous.run(failover_agent, "What is 2+2?") do
      {:ok, result} ->
        # Bill the model that actually served the run, not the one we asked for.
        billed =
          receive do
            {:run_stop, active} -> active
          after
            0 -> "lmstudio:primary-down"
          end

        cost = Ledger.record(billed, result.usage, :live_offline, "served after failover")

        IO.puts("\noutput:   #{inspect(result.output)}")
        IO.puts("billed:   #{billed} -> #{usd.(cost.total)} (local inference is free)")

        IO.puts(
          "usage:    in=#{result.usage.input_tokens} out=#{result.usage.output_tokens} " <>
            "cache_write=#{result.usage.cache_creation_input_tokens} " <>
            "cache_read=#{result.usage.cache_read_input_tokens} " <>
            "iterations=#{result.iterations}"
        )

        IO.puts("""

        The cache counters are 0 here because the OpenAI-compatible parser
        (Nous.Messages.OpenAI.parse_usage/1) reads prompt_tokens and
        completion_tokens only. Anthropic responses fill both cache fields -
        that is the path section 6 exercises when a key is present.
        """)

      {:error, error} ->
        IO.puts("\nBoth legs failed: #{Exception.message(error)}")
        IO.puts("(Nothing was billed; the routing and cost math above still hold.)")
    end

  {:error, reason} ->
    IO.puts("Could not start the loopback stub (#{inspect(reason)}) - skipping the live leg.")
end

# ============================================================================
# 6. Optional REAL cloud run
# ============================================================================

IO.puts("--- Live Cloud Run (optional) ---\n")

case System.get_env("ANTHROPIC_API_KEY") do
  key when key in [nil, ""] ->
    IO.puts("""
    ANTHROPIC_API_KEY is not set, so no network call was made. Everything above
    ran offline. Set the key to add one real Anthropic run, whose usage fills
    cache_creation_input_tokens / cache_read_input_tokens for real:

        ANTHROPIC_API_KEY=sk-ant-... mix run examples/advanced/cost_aware_routing.exs
    """)

  _key ->
    prompt = "Name the capital of France. One word."

    decision =
      Router.route(prompt,
        needs_tools: false,
        remaining: Ledger.remaining(),
        budget: Ledger.budget()
      )

    # Route says :small (a one-liner), but the small tier is an OpenAI model and
    # only ANTHROPIC_API_KEY is set, so use the cheapest Anthropic entry.
    model_key = "anthropic:claude-3-5-haiku-latest"
    IO.puts("router said #{decision.model} (#{decision.reason}); using #{model_key}\n")

    live_agent = Nous.new(model_key, name: "cost-router-live", instructions: "Be terse.")

    case Nous.run(live_agent, prompt) do
      {:ok, result} ->
        billed =
          receive do
            {:run_stop, active} -> active
          after
            0 -> model_key
          end

        cost = Ledger.record(billed, result.usage, :live_cloud, "live run")
        IO.puts("output:   #{inspect(result.output)}")
        IO.puts("billed:   #{billed} -> #{usd.(cost.total)}")

      {:error, error} ->
        IO.puts("Live run failed: #{Exception.message(error)}")
    end
end

:telemetry.detach("cost-routing-run-stop")
:telemetry.detach("cost-routing-fallback-hop")
:telemetry.detach("cost-routing-fallback-used")

# ============================================================================
# 7. Cost / Usage Summary
# ============================================================================

IO.puts("\n--- Summary ---\n")

entries = Ledger.entries()

by_model =
  Enum.reduce(entries, %{}, fn entry, acc ->
    Map.update(
      acc,
      entry.model,
      %{usage: entry.usage, cost: entry.cost.total, runs: 1},
      fn agg ->
        %{
          usage: Nous.Usage.add(agg.usage, entry.usage),
          cost: agg.cost + entry.cost.total,
          runs: agg.runs + 1
        }
      end
    )
  end)

IO.puts(
  pad.("model", 36) <>
    rpad.("runs", 5) <>
    rpad.("fresh_in", 10) <>
    rpad.("c-write", 9) <>
    rpad.("c-read", 9) <>
    rpad.("out", 8) <>
    "  cost"
)

by_model
|> Enum.sort_by(fn {_model, agg} -> -agg.cost end)
|> Enum.each(fn {model, agg} ->
  IO.puts(
    pad.(model, 36) <>
      rpad.(agg.runs, 5) <>
      rpad.(Pricing.fresh_input_tokens(model, agg.usage), 10) <>
      rpad.(agg.usage.cache_creation_input_tokens, 9) <>
      rpad.(agg.usage.cache_read_input_tokens, 9) <>
      rpad.(agg.usage.output_tokens, 8) <>
      "  #{usd.(agg.cost)}"
  )
end)

total_usage =
  Enum.reduce(entries, Nous.Usage.new(), fn e, acc -> Nous.Usage.add(acc, e.usage) end)
total_cost = Enum.reduce(entries, 0.0, fn e, acc -> acc + e.cost.total end)
uncached_cost = Enum.reduce(entries, 0.0, fn e, acc -> acc + e.cost.uncached_total end)

by_source =
  entries
  |> Enum.group_by(& &1.source)
  |> Enum.map(fn {source, es} ->
    "#{source}=#{length(es)} run(s) / #{usd.(Enum.reduce(es, 0.0, &(&2 + &1.cost.total)))}"
  end)
  |> Enum.join(", ")

IO.puts("""

requests:        #{total_usage.requests}
tokens:          in=#{total_usage.input_tokens} out=#{total_usage.output_tokens} \
total=#{total_usage.total_tokens}
cache tokens:    write=#{total_usage.cache_creation_input_tokens} \
read=#{total_usage.cache_read_input_tokens}
total cost:      #{usd.(total_cost)}
without caching: #{usd.(uncached_cost)}  (prompt cache saved #{usd.(uncached_cost - total_cost)})
budget:          #{usd.(Ledger.remaining())} of #{usd.(Ledger.budget())} left
by source:       #{by_source}
""")

# Nous.Eval.Config.estimate_cost/3 is the built-in helper. It is per-provider,
# per-1K, and reads input/output tokens only - so on the cache-heavy traffic
# above it prices a different (and, for anything using a prompt cache, wrong)
# number. Useful for eval-suite comparisons; not a billing model.
builtin =
  Enum.reduce(entries, 0.0, fn e, acc ->
    acc + Nous.Eval.Config.estimate_cost(e.model, e.usage.input_tokens, e.usage.output_tokens)
  end)

IO.puts("""
Cross-check with the built-in helper:

  Nous.Eval.Config.estimate_cost/3 total: #{usd.(builtin)}
  cache-aware table total:                #{usd.(total_cost)}

The helper keys rates by PROVIDER (not model), bills per 1K tokens, and ignores
cache_creation_input_tokens / cache_read_input_tokens entirely. Use it for
relative eval comparisons; use a per-model, cache-aware table like the one in
section 1 when the number has to match an invoice.
""")
