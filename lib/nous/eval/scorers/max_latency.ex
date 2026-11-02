defmodule Nous.Eval.Scorers.MaxLatency do
  @moduledoc """
  Passes when the sample's wall time is at most `:max_ms`.

      {Nous.Eval.Scorers.MaxLatency, max_ms: 5_000, required: false, weight: 0}

  Latency varies with provider load, so declare it track-only (`required:
  false, weight: 0`) unless the budget is a hard requirement: the result is
  then recorded for every sample without deciding the verdict.

  ## Options

    * `:max_ms` - the limit in milliseconds (required)

  `details.duration_ms` holds the measured time.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput}
  alias Nous.Eval.Scorers.Options

  @id "max_latency"
  @option_keys [:max_ms]

  @impl true
  def id, do: @id

  @impl true
  def content, do: :none

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys) do
      Options.parse(map, [{:max_ms, nil, &Options.non_neg_number(@id, :max_ms, &1)}])
    end
  end

  @impl true
  def score(%ScoreInput{duration_ms: duration}, config)
      when is_integer(duration) and duration >= 0 do
    passed? = duration <= config.max_ms
    reason = unless passed?, do: "took #{duration} ms, limit #{config.max_ms} ms"
    {:ok, %Score{Options.pass_fail(@id, passed?, reason) | details: %{duration_ms: duration}}}
  end

  def score(%ScoreInput{duration_ms: other}, _config),
    do: Options.scorer_error(@id, :invalid_config, "no sample duration (got #{inspect(other)})")

  @impl true
  def describe(config), do: config
end
