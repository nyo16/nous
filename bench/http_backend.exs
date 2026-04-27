# HTTP backend benchmark.
#
# Compares Nous.HTTP.Backend.Req vs Nous.HTTP.Backend.Hackney across three
# scenarios: single small POST, 50-way parallel, and a large body.
#
# Run with:
#
#     mix run bench/http_backend.exs
#
# Spins up an in-process Cowboy server on a random port — the network is
# local loopback only, so the numbers reflect HTTP-client overhead
# (connection pooling, encode/decode, scheduler interaction), not
# real-world LLM latency.

{:ok, _} = Application.ensure_all_started(:hackney)
{:ok, _} = Application.ensure_all_started(:plug_cowboy)
{:ok, _} = Application.ensure_all_started(:req)

alias Nous.HTTP.Backend.{Hackney, Req}

# ----- In-process Plug server ------------------------------------------------

defmodule HTTPBackendBench.Server do
  @moduledoc false
  @behaviour Plug

  @small_resp JSON.encode!(%{"ok" => true, "data" => String.duplicate("b", 900)})
  @large_resp JSON.encode!(%{"echo" => String.duplicate("y", 256 * 1024)})

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    body =
      case Plug.Conn.get_req_header(conn, "x-scenario") do
        ["large"] -> @large_resp
        _ -> @small_resp
      end

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.send_resp(200, body)
  end
end

{:ok, _} = Plug.Cowboy.http(HTTPBackendBench.Server, [], port: 0, ref: :http_backend_bench)
port = :ranch.get_port(:http_backend_bench)
url = "http://localhost:#{port}/v1/test"

# 1 KB JSON
small_body = %{"hello" => String.duplicate("a", 900)}
# 256 KB JSON
large_body = %{"data" => String.duplicate("x", 256 * 1024)}

# ----- Scenarios -------------------------------------------------------------

small_post = fn backend ->
  {:ok, _} = backend.post(url, small_body, [], [])
end

parallel_50 = fn backend ->
  1..50
  |> Enum.map(fn _ -> Task.async(fn -> backend.post(url, small_body, [], []) end) end)
  |> Task.await_many(30_000)
end

large_body_fn = fn backend ->
  1..10
  |> Enum.map(fn _ ->
    Task.async(fn -> backend.post(url, large_body, [{"x-scenario", "large"}], []) end)
  end)
  |> Task.await_many(30_000)
end

# ----- Run -------------------------------------------------------------------

Benchee.run(
  %{
    "Req — small_post" => fn -> small_post.(Req) end,
    "Hackney — small_post" => fn -> small_post.(Hackney) end,
    "Req — parallel_50" => fn -> parallel_50.(Req) end,
    "Hackney — parallel_50" => fn -> parallel_50.(Hackney) end,
    "Req — large_body" => fn -> large_body_fn.(Req) end,
    "Hackney — large_body" => fn -> large_body_fn.(Hackney) end
  },
  warmup: 2,
  time: 10,
  print: [fast_warning: false],
  formatters: [
    {Benchee.Formatters.Console, comparison: false, extended_statistics: true}
  ]
)

:ok = Plug.Cowboy.shutdown(:http_backend_bench)
