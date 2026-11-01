defmodule Nous.Eval.Scorers.ToolArgs do
  @moduledoc """
  Checks the arguments of one tool's calls in the trace.

      {Nous.Eval.Scorers.ToolArgs, tool: "search_orders", args: %{"order_id" => "123"}}

  The score is named `"tool_args.<tool>"`.

  ## Options

    * `:tool` - the tool name (required)
    * `:args` - the expected arguments, a map (required)
    * `:occurrence` - which calls must match: `:all` (default; every call of
      the tool), `:any`, `:first`, `:last`, or `n` (the n-th call, from 1)
    * `:match` - `:subset` (default; recursive), `:exact`, or a function
      `(actual, expected -> boolean)` (Elixir only)
    * `:ignore_args`, `:numbers` - as in `Nous.Eval.Scorers.Trajectory`
    * `:include` - which call outcomes count (default `[:executed]`)
    * `:scope` - `:root` (default), `:tree` or `{:sub_agent, template}`

  The sample fails when the tool was not called. On a truncated trace a
  result that later calls could change (not called, `:all`, `:last`, a
  missing n-th call, or `:any` without a match) is a `:missing_trace` error.
  `details.mismatches` lists `%{tool_call_id:, paths:}`.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput, Trace}
  alias Nous.Eval.Scorers.{Args, Options}

  @id "tool_args"
  @option_keys [:tool, :args, :occurrence, :match, :ignore_args, :numbers, :include, :scope]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys) do
      Options.parse(map, [
        {:tool, nil, &Options.string(@id, :tool, &1)},
        {:args, nil, &expected_args/1},
        {:occurrence, :all, &occurrence/1},
        {:match, :subset, &match_mode/1},
        {:ignore_args, nil, &Args.parse_ignore(@id, &1)},
        {:numbers, :exact, &Args.parse_numbers(@id, &1)},
        {:include, [:executed], &Options.include(@id, &1)},
        {:scope, :root, &Options.scope(@id, &1)}
      ])
    end
  end

  defp expected_args(%{} = args), do: {:ok, Args.normalize_expected(args)}
  defp expected_args(other), do: Options.invalid(@id, "args must be a map, got #{inspect(other)}")

  defp occurrence(n) when is_integer(n) and n >= 1, do: {:ok, n}
  defp occurrence(value), do: Options.enum(@id, :occurrence, value, [:all, :any, :first, :last])

  defp match_mode(value) do
    case Args.parse_mode(@id, :match, value) do
      {:ok, :ignore} -> Options.invalid(@id, "match :ignore would always pass")
      result -> result
    end
  end

  @impl true
  def score(%ScoreInput{trace: %Trace{} = trace}, config) do
    name = "#{@id}.#{config.tool}"

    calls =
      trace
      |> Trace.tool_calls(scope: config.scope, include: config.include)
      |> Enum.filter(&(&1.name == config.tool))

    arg_config =
      Args.config(%{args: config.match, ignore_args: config.ignore_args, numbers: config.numbers})

    diffs = fn calls ->
      calls
      |> Enum.map(
        &%{
          tool_call_id: &1.id,
          paths: Args.diff(config.tool, &1.arguments, config.args, arg_config)
        }
      )
      |> Enum.reject(&(&1.paths == []))
    end

    case select(calls, config.occurrence) do
      :none ->
        absent(trace, name, "tool_not_called")

      :short ->
        absent(trace, name, "fewer calls than occurrence #{config.occurrence}")

      {:any, selected} ->
        mismatches = diffs.(selected)
        passed? = length(mismatches) < length(selected)

        if passed? or not trace.truncated?,
          do: verdict(name, passed?, mismatches),
          else: Options.missing_trace(@id, "trace truncated before a matching call")

      {quantifier, selected} ->
        mismatches = diffs.(selected)
        passed? = mismatches == []

        if trace.truncated? and passed? and quantifier in [:all, :last],
          do: Options.missing_trace(@id, "trace truncated; later calls may not match"),
          else: verdict(name, passed?, mismatches)
    end
  end

  def score(%ScoreInput{}, _config), do: Options.missing_trace(@id, "no trace")

  defp select([], _occurrence), do: :none
  defp select(calls, :all), do: {:all, calls}
  defp select(calls, :any), do: {:any, calls}
  defp select([first | _], :first), do: {:first, [first]}
  defp select(calls, :last), do: {:last, [List.last(calls)]}

  defp select(calls, n) do
    case Enum.at(calls, n - 1) do
      nil -> :short
      call -> {:nth, [call]}
    end
  end

  defp absent(trace, name, reason) do
    if trace.truncated?,
      do: Options.missing_trace(@id, "trace truncated; the call may be in the missing tail"),
      else: {:ok, Options.pass_fail(name, false, reason)}
  end

  defp verdict(name, passed?, mismatches) do
    reason = unless passed?, do: "#{length(mismatches)} call(s) with mismatched arguments"
    {:ok, %Score{Options.pass_fail(name, passed?, reason) | details: %{mismatches: mismatches}}}
  end

  @impl true
  def describe(config) do
    config
    |> Map.update!(:match, &Nous.Eval.Scorers.Trajectory.describe_mode/1)
    |> Map.update!(:ignore_args, fn regexes -> Enum.map(regexes, &Regex.source/1) end)
    |> Map.update!(:numbers, &Nous.Eval.Scorers.Trajectory.describe_numbers/1)
    |> Map.update!(:scope, &Nous.Eval.Scorers.Trajectory.describe_scope/1)
  end
end
