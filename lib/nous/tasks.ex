defmodule Nous.Tasks do
  @moduledoc false
  # Saturation-aware wrappers around `Nous.TaskSupervisor`.
  #
  # `Nous.Application` gives that supervisor a finite `:max_children`, so every
  # spawn through it can be REFUSED. `Task.Supervisor` reports refusal two
  # different ways, neither of them a typed error:
  #
  #   * `start_child/2`         -> `{:error, :max_children}`
  #   * `async_nolink/3`        -> RAISES a `RuntimeError` in the CALLING process
  #                                (`Task.Supervisor.async/6`, elixir 1.20
  #                                `lib/task/supervisor.ex:621-626`)
  #   * `async_stream_nolink/4` -> the same `RuntimeError`, re-raised out of the
  #                                enumeration by `Task.Supervised.stream/7`
  #                                AFTER the stream has already been closed, so
  #                                results already produced are gone
  #
  # Learning all three at seventeen callsites is how a ceiling turns into silent
  # data loss in one place and a wedged `GenServer.call` in another. Callers
  # funnel through here and handle one shape: `{:error, :saturated}`.
  #
  # This module deliberately does NOT decide what to do about refusal. Dropping a
  # fire-and-forget save, answering a caller with an error, and degrading a
  # parallel fan-out to sequential are all correct — for different callsites.

  require Logger

  @spec start_child((-> any())) :: {:ok, pid()} | {:error, :saturated}
  def start_child(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(Nous.TaskSupervisor, fun) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, :max_children} -> {:error, :saturated}
      {:error, reason} -> exit({:task_supervisor, reason})
    end
  end

  @spec async_nolink((-> any()), keyword()) :: {:ok, Task.t()} | {:error, :saturated}
  def async_nolink(fun, opts \\ []) when is_function(fun, 0) do
    {:ok, Task.Supervisor.async_nolink(Nous.TaskSupervisor, fun, opts)}
  rescue
    e in RuntimeError ->
      if saturated?(e), do: {:error, :saturated}, else: reraise(e, __STACKTRACE__)
  end

  # Eager by necessity: the refusal arrives DURING enumeration, so there is no
  # way to hand back a lazy stream and still convert it. Every caller in this
  # repo fully consumes the stream anyway.
  @spec async_stream_nolink(Enumerable.t(), (term() -> any()), keyword()) ::
          {:ok, [term()]} | {:error, :saturated}
  def async_stream_nolink(enumerable, fun, opts) do
    {:ok,
     Nous.TaskSupervisor
     |> Task.Supervisor.async_stream_nolink(enumerable, fun, opts)
     |> Enum.to_list()}
  rescue
    e in RuntimeError ->
      if saturated?(e), do: {:error, :saturated}, else: reraise(e, __STACKTRACE__)
  end

  @typedoc false
  @type stream_result :: {:ok, term()} | {:exit, term()}

  @doc false
  # Concurrent fan-out that degrades to SEQUENTIAL execution instead of failing.
  #
  # Emits exactly the tuples `Task.Supervisor.async_stream_nolink/4` emits, on
  # both paths, so a caller's collector is identical either way and "the fallback
  # is indistinguishable" is structural rather than argued per callsite. That is
  # the whole point of this function existing: the emulation is written once.
  #
  # THE ONE SEMANTIC IT CANNOT PRESERVE is `:timeout` / `:on_timeout` — there is
  # no separate process to kill, so a pathological item runs to completion in the
  # caller. A callsite whose per-item timeout is load-bearing (an LLM-supplied
  # regex, an unbounded tool call) must NOT use this; it should call
  # `async_stream_nolink/3` and answer `{:error, :saturated}` in its own terms.
  @spec stream(Enumerable.t(), (term() -> any()), keyword()) :: [stream_result()]
  def stream(enumerable, fun, opts) do
    case async_stream_nolink(enumerable, fun, opts) do
      {:ok, results} ->
        results

      {:error, :saturated} ->
        items = Enum.to_list(enumerable)
        warn_saturated("#{length(items)} concurrent item(s); running them sequentially")
        Enum.map(items, &sequential(&1, fun, opts))
    end
  end

  # Reproduces async_stream's per-item reporting. A task that raises exits with
  # `{exception, stacktrace}`; one that throws exits with
  # `{{:nocatch, value}, stacktrace}`; an explicit `exit/1` passes its reason
  # through unchanged. `:zip_input_on_exit` wraps the reason as `{input, reason}`.
  defp sequential(item, fun, opts) do
    {:ok, fun.(item)}
  catch
    :error, reason -> {:exit, exit_reason(item, {reason, __STACKTRACE__}, opts)}
    :throw, value -> {:exit, exit_reason(item, {{:nocatch, value}, __STACKTRACE__}, opts)}
    :exit, reason -> {:exit, exit_reason(item, reason, opts)}
  end

  defp exit_reason(item, reason, opts) do
    if Keyword.get(opts, :zip_input_on_exit, false), do: {item, reason}, else: reason
  end

  # One consistent warning naming the knob that fixes it. `what` describes the
  # work that was refused, e.g. "3 tool call(s)".
  @spec warn_saturated(String.t()) :: :ok
  def warn_saturated(what) do
    Logger.warning(
      "Nous.TaskSupervisor is at its :max_children ceiling; #{what} refused. " <>
        "Raise it with `config :nous, :task_supervisor_max_children`."
    )
  end

  # Task.Supervisor exposes no typed error for this, only prose, so the match is
  # on the stable prefix of its message. If Elixir ever rewords it this stops
  # matching and the error propagates exactly as it did before the ceiling
  # existed — fail-safe rather than silently swallowed.
  @max_children_message "reached the maximum number of tasks"

  @spec saturated?(Exception.t()) :: boolean()
  def saturated?(%RuntimeError{message: message}) do
    is_binary(message) and String.starts_with?(message, @max_children_message)
  end

  def saturated?(_other), do: false
end
