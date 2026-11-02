defmodule Nous.Eval.Simulator.Scorers.Tools do
  @moduledoc """
  Checks the episode's tool use against the case's `expected.tools`
  (`"sim.tools"`): no `forbidden` tool executed, and every `required` tool
  executed at least once, anywhere in the run tree (sub-agents included),
  over all turns.

  A call counts once it executed (outcome `:executed`); a call a hook or an
  approval denied did not run, and is listed in `details["attempts"]`.
  Required tools are opt-in: many conversations reach the same end state
  along different tool paths.

  Attached to simulated cases by `Nous.Eval.Simulator`; it takes no
  options. How the episode ended is decided first, as for every simulation
  scorer (see "Termination" in `Nous.Eval.Simulator`). Passing on a
  truncated trace is a `:missing_trace` error: the missing tail may hold
  the call.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput, Trace}
  alias Nous.Eval.Simulator.Scorers.Common

  @id "sim.tools"

  @impl true
  def id, do: @id

  @impl true
  def init([]), do: {:ok, %{}}
  def init(opts), do: {:error, "#{@id}: takes no options, got #{inspect(opts)}"}

  @impl true
  def score(%ScoreInput{trace: %Trace{} = trace} = input, _config) do
    Common.score(input, @id, fn _episode -> check(trace, input.case.expected["tools"]) end)
  end

  def score(%ScoreInput{}, _config), do: Common.scorer_error(@id, :missing_trace, "no trace")

  defp check(_trace, nil),
    do: Common.scorer_error(@id, :invalid_config, "the case has no expected.tools")

  defp check(trace, %{"forbidden" => forbidden, "required" => required}) do
    calls = Trace.tool_calls(trace, scope: :tree, include: :all)
    executed = for call <- calls, call.outcome == :executed, uniq: true, do: call.name

    attempts =
      for call <- calls,
          call.outcome != :executed,
          call.name in forbidden,
          do: %{"name" => call.name, "outcome" => Atom.to_string(call.outcome)}

    used = Enum.filter(forbidden, &(&1 in executed))
    missing = Enum.reject(required, &(&1 in executed))
    details = %{"forbidden_used" => used, "required_missing" => missing, "attempts" => attempts}

    cond do
      used != [] ->
        fail("forbidden tool(s) executed: #{Enum.join(used, ", ")}", details)

      missing != [] and not trace.truncated? ->
        fail("required tool(s) never executed: #{Enum.join(missing, ", ")}", details)

      trace.truncated? and (forbidden != [] or missing != []) ->
        Common.scorer_error(
          @id,
          :missing_trace,
          "the trace is truncated; a tool call may be in the missing tail"
        )

      true ->
        {:ok, %Score{name: @id, value: :pass, passed?: true, details: details}}
    end
  end

  defp fail(reason, details),
    do: {:ok, %Score{name: @id, value: :fail, passed?: false, reason: reason, details: details}}
end
