defmodule Nous.Eval.Online.Counters do
  @moduledoc false
  # The `:atomics` of one online instance: two gauges (captured traces not
  # yet finalized, finalize jobs queued) and the window counters reported by
  # `[:nous, :eval, :online, :window]`. Written from the request path, the
  # coordinator and the job tasks; read-and-reset once per window.

  @gauges [:in_flight, :queued]

  @window [
    :seen_roots,
    :sampled,
    :captured,
    :dropped_admission,
    :dropped_queue,
    :dropped_store,
    :lost,
    :filter_error,
    :session_key_missing,
    :redaction_failed,
    :scored,
    :score_failed,
    :skipped_budget,
    :abandoned,
    :stored
  ]

  @index (@gauges ++ @window) |> Enum.with_index(1) |> Map.new()

  @drop_reasons %{
    dropped_admission: :admission,
    dropped_queue: :queue,
    dropped_store: :store,
    lost: :lost
  }

  @type t :: :atomics.atomics_ref()

  @spec new() :: t()
  def new, do: :atomics.new(map_size(@index), signed: true)

  @spec window_keys() :: [atom()]
  def window_keys, do: @window

  @spec add(t(), atom(), integer()) :: :ok
  def add(ref, key, n \\ 1), do: :atomics.add(ref, Map.fetch!(@index, key), n)

  @spec add_get(t(), atom(), integer()) :: integer()
  def add_get(ref, key, n), do: :atomics.add_get(ref, Map.fetch!(@index, key), n)

  @spec get(t(), atom()) :: integer()
  def get(ref, key), do: :atomics.get(ref, Map.fetch!(@index, key))

  # Takes the window counters, resetting them.
  @spec take_window(t()) :: %{atom() => non_neg_integer()}
  def take_window(ref),
    do: Map.new(@window, &{&1, :atomics.exchange(ref, Map.fetch!(@index, &1), 0)})

  @spec drop_reasons() :: %{atom() => atom()}
  def drop_reasons, do: @drop_reasons
end
