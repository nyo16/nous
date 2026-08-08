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
  # converts another one.

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
end
