defmodule Nous.Eval.Trace.AgentRun do
  @moduledoc """
  One agent run in a `Nous.Eval.Trace`, from `Nous.Eval.Trace.runs/1`.

    * `:agent_run_id` / `:parent_agent_run_id` - the run and its parent
      (`nil` for the root run)
    * `:parent_tool_call_id` - the tool call that started a sub-agent run
    * `:role` - `:agent | :judge | :simulator | :reflector`
    * `:agent_name`, `:sub_agent_template`, `:sub_agent_index` - labels from
      the run start event
    * `:status` - `:ok` (run stop), `:error` (run exception) or
      `:incomplete` (no end event in the trace)
    * `:error` - the exception event's `reason`, if any
    * `:children` - the `agent_run_id`s of the runs this one started, in
      start order
    * `:seq` - the `seq` of the start event
  """

  @type t :: %__MODULE__{
          agent_run_id: String.t(),
          parent_agent_run_id: String.t() | nil,
          parent_tool_call_id: String.t() | nil,
          role: atom() | nil,
          agent_name: String.t() | nil,
          sub_agent_template: String.t() | nil,
          sub_agent_index: non_neg_integer() | nil,
          status: :ok | :error | :incomplete,
          error: term(),
          children: [String.t()],
          seq: non_neg_integer()
        }

  defstruct [
    :agent_run_id,
    :parent_agent_run_id,
    :parent_tool_call_id,
    :role,
    :agent_name,
    :sub_agent_template,
    :sub_agent_index,
    :error,
    :seq,
    status: :incomplete,
    children: []
  ]
end
