defmodule Nous.CallerLookup do
  @moduledoc false
  # Process-scoped values that follow work into the tasks it fans out.
  #
  # A value stored under `key` in a process dictionary is visible to that
  # process and to every process that lists it in `$callers`:
  # `Task.async/1`, `Task.async_stream/3` and `Task.Supervisor.async*/2` all
  # record the chain, nearest caller first. `$callers` does NOT cross
  # `GenServer.start_link/3` or a bare `spawn`, so a site that hops that way
  # must copy the value (or the chain) itself.
  #
  # Shared by `Nous.ModelDispatcher` (the test dispatcher seam) and
  # `Nous.Telemetry.RunScope` (run correlation ids), so the walk and its OTP
  # 25/26 split live in one place.

  @doc false
  # The value stored under `key` in this process, else the first caller in
  # `$callers` whose value satisfies `accept?`. `nil` when none does.
  @spec lookup(term(), (term() -> boolean())) :: term() | nil
  def lookup(key, accept? \\ &default_accept?/1) do
    case Process.get(key) do
      nil -> walk(Process.get(:"$callers", []), key, accept?)
      value -> value
    end
  end

  # Nothing to walk in the overwhelmingly common case, so production pays two
  # process-dictionary reads and stops here.
  defp walk([], _key, _accept?), do: nil

  defp walk(callers, key, accept?) when is_list(callers) do
    Enum.find_value(callers, fn caller ->
      value = caller_value(caller, key)
      if value != nil and accept?.(value), do: value
    end)
  end

  defp walk(_malformed, _key, _accept?), do: nil

  defp default_accept?(_value), do: true

  # `process_info/2` raises on a remote pid and on anything that is not a pid
  # (a registered name someone pushed onto `$callers` by hand); neither has a
  # local dictionary to read.
  defp caller_value(pid, key) when is_pid(pid) and node(pid) == node(), do: read(pid, key)
  defp caller_value(_not_a_local_pid, _key), do: nil

  # `process_info(pid, {:dictionary, key})` fetches one entry instead of
  # copying the whole dictionary out of the other process. It landed in OTP 26;
  # `elixir ~> 1.18` still supports OTP 25, so keep the copying form for it.
  if String.to_integer(System.otp_release()) >= 26 do
    defp read(pid, key) do
      case :erlang.process_info(pid, {:dictionary, key}) do
        {_item, :undefined} -> nil
        {_item, value} -> value
        :undefined -> nil
      end
    end
  else
    defp read(pid, key) do
      case :erlang.process_info(pid, :dictionary) do
        {:dictionary, dict} -> :proplists.get_value(key, dict, nil)
        :undefined -> nil
      end
    end
  end
end
