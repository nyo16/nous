defmodule Nous.Eval.Scorers.NoToolErrors do
  @moduledoc """
  Passes when no tool call failed.

      {Nous.Eval.Scorers.NoToolErrors, scope: :tree}

  A call failed when its outcome is one of `:outcomes`, or when it executed
  but its stop event reports an `error`. A tool that returns a domain error
  as its result (`%{success: false}`) executed successfully as far as the
  runner is concerned and does not count.

  ## Options

    * `:outcomes` - the failing outcomes (default `[:invalid_arguments,
      :not_found, :timeout, :crashed, :hook_stage_failed]`; denials and
      rejections are policy decisions, not errors, and `:incomplete` calls
      belong to a killed run)
    * `:scope` - `:root` (default), `:tree` or `{:sub_agent, template}`

  Passing on a truncated trace is a `:missing_trace` error. `details.errors`
  lists `%{tool_call_id:, name:, outcome:}`.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput, Trace}
  alias Nous.Eval.Scorers.Options
  alias Nous.Eval.Trace.ToolCall

  @id "no_tool_errors"
  @option_keys [:outcomes, :scope]
  @default_outcomes [:invalid_arguments, :not_found, :timeout, :crashed, :hook_stage_failed]

  @impl true
  def id, do: @id

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys) do
      Options.parse(map, [
        {:outcomes, @default_outcomes, &outcomes/1},
        {:scope, :root, &Options.scope(@id, &1)}
      ])
    end
  end

  defp outcomes(value) do
    case Options.include(@id, value) do
      {:ok, :all} -> {:ok, ToolCall.outcomes() -- [:executed]}
      {:ok, list} -> {:ok, list}
      error -> error
    end
  end

  @impl true
  def score(%ScoreInput{trace: %Trace{} = trace}, config) do
    errors =
      trace
      |> Trace.tool_calls(scope: config.scope, include: :all)
      |> Enum.filter(
        &(&1.outcome in config.outcomes or (&1.outcome == :executed and &1.error != nil))
      )
      |> Enum.map(&%{tool_call_id: &1.id, name: &1.name, outcome: &1.outcome})

    cond do
      errors != [] ->
        {:ok,
         %Score{
           Options.pass_fail(@id, false, "#{length(errors)} tool call(s) failed")
           | details: %{errors: errors}
         }}

      trace.truncated? ->
        Options.missing_trace(@id, "trace truncated; a failed call may be in the missing tail")

      true ->
        {:ok, %Score{Options.pass_fail(@id, true, nil) | details: %{errors: []}}}
    end
  end

  def score(%ScoreInput{}, _config), do: Options.missing_trace(@id, "no trace")

  @impl true
  def describe(config),
    do: Map.update!(config, :scope, &Nous.Eval.Scorers.Trajectory.describe_scope/1)
end
