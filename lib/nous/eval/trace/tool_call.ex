defmodule Nous.Eval.Trace.ToolCall do
  @moduledoc """
  One tool call reconstructed from a `Nous.Eval.Trace` by
  `Nous.Eval.Trace.tool_calls/2`.

  Built by pairing `[:nous, :agent, :tool_call, :start]` and `:stop` on
  `tool_call_id`.

    * `:id` - the `tool_call_id`
    * `:name` - the tool name
    * `:arguments` - the arguments the tool ran with: the post-edit
      arguments when `approval` is `:edited`, else the requested ones
    * `:original_arguments` - the arguments the model requested (differs from
      `:arguments` only when the call was edited at approval)
    * `:outcome` - `:executed | :invalid_arguments | :collapsed |
      :hook_denied | :hook_stage_failed | :approval_rejected | :not_found |
      :timeout | :crashed`, or `:incomplete` when the trace holds a start
      without a stop (the run was killed mid-call, or the tail was truncated)
    * `:approval` - `:not_required | :approved | :edited | :rejected`, `nil`
      when incomplete
    * `:result` / `:error` - from the stop event
    * `:iteration` - the agent loop iteration that requested the call
    * `:agent_run_id` / `:parent_agent_run_id` - the run that made the call
      and its parent run (`nil` for the root run)
    * `:batch` - `{agent_run_id, iteration}`; calls requested by the same model
      response share it and may have run in parallel
    * `:seq` - the `seq` of the start event (or of the stop event when the
      start is missing); orders calls within the trace
  """

  @type outcome ::
          :executed
          | :invalid_arguments
          | :collapsed
          | :hook_denied
          | :hook_stage_failed
          | :approval_rejected
          | :not_found
          | :timeout
          | :crashed
          | :incomplete

  @type approval :: :not_required | :approved | :edited | :rejected

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          arguments: map() | nil,
          original_arguments: map() | nil,
          outcome: outcome(),
          approval: approval() | nil,
          result: term(),
          error: term(),
          iteration: non_neg_integer() | nil,
          agent_run_id: String.t() | nil,
          parent_agent_run_id: String.t() | nil,
          batch: {String.t() | nil, non_neg_integer() | nil},
          seq: non_neg_integer()
        }

  defstruct [
    :id,
    :name,
    :arguments,
    :original_arguments,
    :outcome,
    :approval,
    :result,
    :error,
    :iteration,
    :agent_run_id,
    :parent_agent_run_id,
    :batch,
    :seq
  ]

  @outcomes [
    :executed,
    :invalid_arguments,
    :collapsed,
    :hook_denied,
    :hook_stage_failed,
    :approval_rejected,
    :not_found,
    :timeout,
    :crashed,
    :incomplete
  ]

  @doc "Every outcome a reconstructed call may have, including `:incomplete`."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes
end
