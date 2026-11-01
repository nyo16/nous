defmodule Nous.Eval.Scorers.ToolCount do
  @moduledoc """
  Bounds the number of tool calls, for one tool or in total.

      {Nous.Eval.Scorers.ToolCount, tool: "search", max: 3}
      {Nous.Eval.Scorers.ToolCount, max: 10}

  The score is named `"tool_count"` (all tools) or `"tool_count.<tool>"`.

  ## Options

    * `:tool` - count only this tool (default: every tool)
    * `:min`, `:max` - inclusive bounds; or `:exact` alone. At least one
      bound is required
    * `:include` - which call outcomes count (default `:all`: failed and
      denied attempts still cost time and tokens)
    * `:scope` - `:root` (default), `:tree` or `{:sub_agent, template}`

  On a truncated trace the observed count is a lower bound: a count already
  above `:max`/`:exact` fails and a satisfied `:min` alone passes, anything
  else is a `:missing_trace` error. `details.count` holds the count.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput, Trace}
  alias Nous.Eval.Scorers.Options

  @id "tool_count"
  @option_keys [:tool, :min, :max, :exact, :include, :scope]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys),
         {:ok, config} <-
           Options.parse(map, [
             {:tool, nil, &optional(&1, fn v -> Options.string(@id, :tool, v) end)},
             {:min, nil, &optional(&1, fn v -> Options.non_neg_integer(@id, :min, v) end)},
             {:max, nil, &optional(&1, fn v -> Options.non_neg_integer(@id, :max, v) end)},
             {:exact, nil, &optional(&1, fn v -> Options.non_neg_integer(@id, :exact, v) end)},
             {:include, :all, &Options.include(@id, &1)},
             {:scope, :root, &Options.scope(@id, &1)}
           ]) do
      check_bounds(config)
    end
  end

  defp optional(nil, _parser), do: {:ok, nil}
  defp optional(value, parser), do: parser.(value)

  defp check_bounds(%{exact: exact, min: min, max: max} = config) do
    cond do
      exact != nil and (min != nil or max != nil) ->
        Options.invalid(@id, "exact excludes min and max")

      exact == nil and min == nil and max == nil ->
        Options.invalid(@id, "set min, max or exact")

      min != nil and max != nil and min > max ->
        Options.invalid(@id, "min #{min} is above max #{max}")

      true ->
        {:ok, config}
    end
  end

  @impl true
  def score(%ScoreInput{trace: %Trace{} = trace}, config) do
    name = if config.tool, do: "#{@id}.#{config.tool}", else: @id

    count =
      trace
      |> Trace.tool_calls(scope: config.scope, include: config.include)
      |> Enum.count(&(config.tool == nil or &1.name == config.tool))

    {min, max} =
      if config.exact, do: {config.exact, config.exact}, else: {config.min || 0, config.max}

    over? = max != nil and count > max
    under? = count < min

    cond do
      over? ->
        verdict(name, false, "count #{count} above #{max}", count)

      trace.truncated? and (max != nil or under?) ->
        Options.missing_trace(@id, "trace truncated; the count is only a lower bound")

      under? ->
        verdict(name, false, "count #{count} below #{min}", count)

      true ->
        verdict(name, true, nil, count)
    end
  end

  def score(%ScoreInput{}, _config), do: Options.missing_trace(@id, "no trace")

  defp verdict(name, passed?, reason, count) do
    {:ok, %Score{Options.pass_fail(name, passed?, reason) | details: %{count: count}}}
  end

  @impl true
  def describe(config),
    do: Map.update!(config, :scope, &Nous.Eval.Scorers.Trajectory.describe_scope/1)
end
