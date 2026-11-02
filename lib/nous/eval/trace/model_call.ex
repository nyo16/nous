defmodule Nous.Eval.Trace.ModelCall do
  @moduledoc """
  One model request reconstructed from a `Nous.Eval.Trace` by
  `Nous.Eval.Trace.model_calls/1`.

  Built by pairing `[:nous, :agent, :model, :start]` with the next `:stop` or
  `:exception` of the same `agent_run_id` (a run makes one model request at a
  time).

    * `:outcome` - `:ok` (stop), `:error` (exception) or `:incomplete` (a
      start without a stop: the run was killed or the trace truncated)
    * `:iteration`, `:model_provider`, `:model_name` - as requested
    * `:active_model_provider`, `:active_model_name`, `:fallback_used` -
      the model that actually answered (differs on fallback)
    * `:messages` - the request messages (start), `:response` - the
      response `Nous.Message` (stop)
    * `:usage` - a `Nous.Usage` with this request's tokens (`requests: 1`)
    * `:finish_reason`, `:requested_tool_calls` - from the stop event
    * `:error` - `{kind, reason}` from the exception event
    * `:duration` - native time units, from the stop/exception measurements
    * `:seq` - the `seq` of the first event of the pair
  """

  @type t :: %__MODULE__{
          agent_run_id: String.t() | nil,
          parent_agent_run_id: String.t() | nil,
          iteration: non_neg_integer() | nil,
          outcome: :ok | :error | :incomplete,
          model_provider: atom() | nil,
          model_name: String.t() | nil,
          active_model_provider: atom() | nil,
          active_model_name: String.t() | nil,
          fallback_used: boolean() | nil,
          stream: boolean() | nil,
          tool_names: [String.t()] | nil,
          messages: [Nous.Message.t()] | nil,
          response: Nous.Message.t() | nil,
          finish_reason: term(),
          requested_tool_calls: [map()] | nil,
          usage: Nous.Usage.t(),
          error: {term(), term()} | nil,
          duration: integer() | nil,
          seq: non_neg_integer()
        }

  defstruct [
    :agent_run_id,
    :parent_agent_run_id,
    :iteration,
    :outcome,
    :model_provider,
    :model_name,
    :active_model_provider,
    :active_model_name,
    :fallback_used,
    :stream,
    :tool_names,
    :messages,
    :response,
    :finish_reason,
    :requested_tool_calls,
    :error,
    :duration,
    :seq,
    usage: %Nous.Usage{}
  ]
end
