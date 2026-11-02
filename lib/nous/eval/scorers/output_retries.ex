defmodule Nous.Eval.Scorers.OutputRetries do
  @moduledoc """
  Bounds the structured-output retries (`[:nous, :agent,
  :structured_output, :retry]` events) the sample needed.

      {Nous.Eval.Scorers.OutputRetries, max: 1}

  ## Options

    * `:max` - retries allowed (default `0`)
    * `:scope` - `:root` (default), `:tree` or `{:sub_agent, template}`

  Passing on a truncated trace is a `:missing_trace` error.
  `details.retries` holds the count.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput, Trace}
  alias Nous.Eval.Scorers.Options

  @id "output_retries"
  @option_keys [:max, :scope]

  @impl true
  def id, do: @id

  @impl true
  def content, do: :none

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys) do
      Options.parse(map, [
        {:max, 0, &Options.non_neg_integer(@id, :max, &1)},
        {:scope, :root, &Options.scope(@id, &1)}
      ])
    end
  end

  @impl true
  def score(%ScoreInput{trace: %Trace{} = trace}, config) do
    retries = trace |> Trace.output_retries(scope: config.scope) |> length()
    passed? = retries <= config.max

    if passed? and trace.truncated? do
      Options.missing_trace(@id, "trace truncated; retries may be in the missing tail")
    else
      reason = unless passed?, do: "#{retries} retries, #{config.max} allowed"
      {:ok, %Score{Options.pass_fail(@id, passed?, reason) | details: %{retries: retries}}}
    end
  end

  def score(%ScoreInput{}, _config), do: Options.missing_trace(@id, "no trace")

  @impl true
  def describe(config),
    do: Map.update!(config, :scope, &Nous.Eval.Scorers.Trajectory.describe_scope/1)
end
