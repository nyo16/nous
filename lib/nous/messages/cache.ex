defmodule Nous.Messages.Cache do
  @moduledoc false

  # Memoized `Enum.map/2` for the provider-payload conversion on the agent loop.
  #
  # `Provider.build_request_params/3` converts the *whole* message history on
  # every iteration, so an N-iteration run over a history reaching M messages
  # rebuilds O(N x M) maps even though messages are immutable and an
  # already-sent one can never convert differently.
  #
  # The history only ever grows at the tail (`Agent.Context.add_message/2`
  # appends), and appending copies list cells but never the elements: every
  # message shared with the previous iteration is the *same term*, so comparing
  # them is a pointer check rather than a deep compare. `map/3` walks the new
  # list against the previous one, takes the already-converted payload for each
  # pointer-identical head, and calls `fun` only for the genuinely new tail.
  #
  # The result is `=:=` to the uncached `Enum.map/2` it replaces -- callers
  # cannot observe the cache, only its absence from the allocation profile.
  # A diverging list (a trimmed history, a different conversation) simply misses
  # and reconverts, so correctness never depends on the caller's usage pattern.
  #
  # State lives in the process dictionary, as in `Teams.SharedState.cached_table/2`:
  # the agent loop is one process, there is one entry per converter, and the
  # cache dies with the process instead of needing eviction or supervision. The
  # price is that a process retains its most recent converted history until it
  # converts another one -- which is why `clear/0` exists, and why the runner and
  # `Nous.LLM` call it on the way out of a run.
  #
  # Ownership rule: **whoever warms the cache releases it.** The agent runner and
  # `Nous.LLM` warm it as a side effect of dispatching a request the caller never
  # asked to be memoized, so they clear it in an `after`. A host that calls the
  # public `Nous.Messages.to_openai_format/1` (and siblings) directly warms its
  # own process dictionary knowingly and owns it -- typically a LiveView, per
  # `AGENTS.md`, which can call `clear/0` from `terminate/2` or between
  # conversations. The formatters deliberately do NOT self-clear: an entry that is
  # dropped on the way out of the very call that wrote it can never be reused, so
  # a self-clearing formatter is a cache with a 0% hit rate -- it would delete the
  # only thing the memo exists to serve.

  @spec map(term(), [term()], (term() -> term())) :: [term()]
  def map(key, items, fun) when is_list(items) and is_function(fun, 1) do
    pd_key = {__MODULE__, key}
    {cached_in, cached_out} = Process.get(pd_key, {[], []})
    converted = extend(items, cached_in, cached_out, fun, [])
    Process.put(pd_key, {items, converted})
    converted
  end

  # Repeating `item` in the pattern is `=:=`, which short-circuits on pointer
  # equality for the shared prefix.
  defp extend([item | items], [item | cached_in], [out | cached_out], fun, acc) do
    extend(items, cached_in, cached_out, fun, [out | acc])
  end

  # First divergence, or the cache ran out: convert the rest for real.
  defp extend(items, _cached_in, _cached_out, fun, acc) do
    Enum.reverse(acc, Enum.map(items, fun))
  end

  @doc """
  Drop every entry this module owns in the calling process's dictionary.

  Releases the retained converted history. Purely a memory operation: the next
  `map/3` misses and reconverts, which is `=:=` to what the cache would have
  returned, so no caller can observe a clear other than in its allocation
  profile.

  Only keys of the shape `{#{inspect(__MODULE__)}, _}` are removed -- the rest of
  the process dictionary (including `Nous.ModelDispatcher`'s override) is left
  alone.
  """
  @spec clear() :: :ok
  def clear do
    Enum.each(Process.get_keys(), fn
      {__MODULE__, _} = pd_key -> Process.delete(pd_key)
      _other -> :ok
    end)
  end
end
