defmodule Nous.CodeRuntime.JS do
  @moduledoc """
  Code Mode's JavaScript runtime: an embedded Deno isolate, one per run.

  Requires [tyrex](https://hex.pm/packages/tyrex) `~> 0.4`, an optional
  dependency. Add it to your own deps to unlock this provider:

      {:tyrex, "~> 0.4"}

      config :nous, :code_runtime, {Nous.CodeRuntime.JS, timeout_ms: 30_000}

  ## Isolation, stated exactly

  A program runs in a V8 isolate inside the BEAM, with Deno's permission model
  set to `:none` by default. It is not an OS sandbox and does not claim to be:
  there is no separate process, so a V8 escape is an escape into the BEAM. What
  it does enforce, and what was verified on this substrate rather than assumed:

    * **No filesystem, network, env or subprocess.** Deno denies each with
      `NotCapable` under `permissions: :none`.
    * **No route into Elixir except the tools you granted.** tyrex's
      arbitrary-module bridge is opt-in, and this provider narrows it to a
      single function - `{Nous.CodeRuntime.JS.Bridge, :call, 1}` - then removes
      the gateway from the isolate before any model-authored code runs.
      Afterwards a program cannot reach `Deno.core`, `ext:core/ops`,
      `__bootstrap`, or reconstruct the gateway through `new Function`.
    * **A real kill.** A deadline that leaves the program running is not a
      deadline. `while (true) {}` is terminated, and the worker's OS thread is
      reclaimed - not merely abandoned, which is the failure mode that makes a
      "timeout" quietly leak a core per run.

  ## Budgets

  Provider configuration, never per request, so a program cannot ask for more
  rope than the operator gave it:

    * `:timeout_ms` (default `30_000`) - wall clock for the whole run, enforced
      by a BEAM timer that kills the isolate. This is the authoritative deadline
      because the substrate's own timeout does not cover time spent inside tool
      calls; see `Nous.CodeRuntime.JS.Session` for why.
    * `:max_heap_mb` (default `256`) - V8 heap cap. Exceeding it ends the run
      with an `:abort` failure; the BEAM is unaffected.
    * `:max_output_bytes` (default `1_000_000`) - byte-accurate ledger over
      everything the program logs. On overflow the fitting prefix is kept and a
      truncation notice is appended.
    * `:permissions` (default `:none`) - passed through to tyrex. Widening this
      hands model-authored code the capability you name.
    * `:poll_backoff_ms` (default `[1, 2, 5, 10, 25]`) - how the guest waits for
      a sub-call to finish. The last value is the worst-case delay between a
      tool completing and the program seeing it.

  There is deliberately **no instruction budget**. This substrate has no fuel
  metering, and rather than imply otherwise: the wall-clock deadline is the only
  bound on a compute-bound program, and it is a real one.

  ## Cost

  A fresh isolate per run costs ~172ms (measured, median 174ms over 12 runs).
  Nothing is pooled, so no state survives a run - not a patched prototype, not a
  cached module, not a `globalThis` the last program wrote to. Reuse would buy
  back that 172ms at the price of the isolation this provider exists to give.
  """

  @behaviour Nous.CodeRuntime

  alias Nous.CodeRuntime.JS.Session
  alias Nous.CodeRuntime.Request

  @defaults [
    timeout_ms: 30_000,
    max_heap_mb: 256,
    max_output_bytes: 1_000_000,
    permissions: :none,
    poll_backoff_ms: [1, 2, 5, 10, 25]
  ]

  @doc """
  Whether the optional tyrex dependency is available.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Tyrex)

  @doc """
  The defaults every budget falls back to.
  """
  @spec defaults() :: keyword()
  def defaults, do: @defaults

  @impl Nous.CodeRuntime
  def language(_config), do: "javascript"

  @impl Nous.CodeRuntime
  def isolation(config) do
    budgets = validate(config) |> elem(1)

    "V8 isolate in-process (Deno permissions: #{inspect(budgets[:permissions])}), " <>
      "#{budgets[:timeout_ms]}ms deadline with a real kill, #{budgets[:max_heap_mb]}MB heap cap, " <>
      "one fresh isolate per run. Not an OS sandbox."
  end

  @impl Nous.CodeRuntime
  def start_run(%Request{} = request, config) do
    with :ok <- check_available(),
         {:ok, budgets} <- validate(config) do
      ref = make_ref()

      case DynamicSupervisor.start_child(
             Nous.CodeRuntime.JS.Supervisor,
             {Session, {request, budgets, ref}}
           ) do
        {:ok, pid} ->
          {:ok, {pid, ref}}

        {:error, reason} ->
          {:error, {:contract, "could not start the run: #{inspect(reason)}"}}
      end
    end
  end

  def start_run(other, _config) do
    {:error, {:contract, "expected a %Nous.CodeRuntime.Request{}, got #{inspect(other)}"}}
  end

  @impl Nous.CodeRuntime
  def cancel({session, _ref}, reason) when is_pid(session) do
    Session.cancel(session, reason)
  end

  def cancel(_ref, _reason), do: :ok

  @doc """
  Validate provider configuration, filling in defaults.

  Budgets are checked here - when the provider is configured - rather than when
  a run starts, because a typo in a budget should fail before a model is ever
  handed a tool that depends on it.
  """
  @spec validate(keyword() | nil) :: {:ok, keyword()} | {:error, {:contract, String.t()}}
  def validate(config) when is_list(config) do
    budgets = Keyword.merge(@defaults, config)

    Enum.reduce_while(
      [
        {:timeout_ms, &pos_integer?/1, "a positive integer of milliseconds"},
        {:max_heap_mb, &pos_integer?/1, "a positive integer of megabytes"},
        {:max_output_bytes, &pos_integer?/1, "a positive integer of bytes"},
        {:poll_backoff_ms, &backoff?/1, "a non-empty list of positive integers"}
      ],
      {:ok, budgets},
      fn {key, valid?, expected}, acc ->
        value = Keyword.fetch!(budgets, key)

        if valid?.(value) do
          {:cont, acc}
        else
          {:halt,
           {:error, {:contract, "#{inspect(key)} must be #{expected}, got #{inspect(value)}"}}}
        end
      end
    )
  end

  def validate(nil), do: {:ok, @defaults}

  def validate(other) do
    {:error, {:contract, "config must be a keyword list, got #{inspect(other)}"}}
  end

  defp pos_integer?(value), do: is_integer(value) and value > 0

  defp backoff?(value) do
    is_list(value) and value != [] and Enum.all?(value, &pos_integer?/1)
  end

  defp check_available do
    if available?() do
      :ok
    else
      {:error,
       {:contract,
        "Nous.CodeRuntime.JS requires the optional :tyrex dependency. " <>
          ~s|Add {:tyrex, "~> 0.4"} to your deps.|}}
    end
  end
end
