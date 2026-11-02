defmodule Nous.Eval.Online.Content do
  @moduledoc """
  What a `Nous.Eval.Online.Redactor` sees: a captured trace split into a
  read-only **skeleton** and the **content** fields the redactor may
  rewrite.

    * `:trace_id` - the trace (read-only)
    * `:skeleton` - one map per event, in trace order: `%{seq, name, at,
      measurements, metadata}` with only the skeleton keys (read-only)
    * `:fields` - `%{path => value}`: every content value of the trace,
      as JSON (see "Values")

  ## Skeleton and content

  The skeleton is an allowlist: ids (`trace_id`, `agent_run_id`,
  `parent_agent_run_id`, `tool_call_id`, `parent_tool_call_id`,
  `profile_id`), agent, provider, model, tool and hook names, roles,
  iterations and counts, timings and token measurements, tool `outcome` and
  `approval`, guard `verdict`, `severity`, `action`, `surface` and `tier`,
  `finish_reason`, `fallback_used`, booleans, and `error_kind` (the module
  of an exception reason, or the atom of an atom reason). An allowlisted
  key is skeleton only while its value is a scalar (string, atom, number,
  boolean, `nil`); `tool_names` and `blocked_tool_names` may be lists of
  them, `requested_tool_calls` keeps only each call's id and tool name.
  A tool name the model chose (`tool_name`, a requested call's name) is
  skeleton only when it is one of the names the run's model requests
  offered or blocked (`tool_names` / `blocked_tool_names` of the same
  `agent_run_id`). Any other name is content: a `tool_name` moves to the
  fields, and a `requested_tool_calls` list naming an unoffered tool keeps
  that call's id without its name in the skeleton and is also a content
  field (ids and names), which then replaces the skeleton list on rebuild.
  Measurements that are not numbers are dropped.

  **Everything else is content**, including keys a later Nous version
  adds: `messages` (with each message's `metadata.content_parts`, which
  providers send in place of `content`), `response`, `arguments`,
  `result`, `reason`, `error`, `errors`, `details`, `stacktrace`,
  `probabilities`, `signatures`, `keys`, and `session_id` (application
  data). A content path is `{seq, key}`: the event's `seq` and the metadata
  key as a string.

  For score explanations (a `Nous.Eval.Score`'s `reason` and `details`, a
  `Nous.Eval.ScorerError`'s `reason` and `details`) the redactor is called
  once more with `skeleton: []` and paths `{{:score, index}, "reason" |
  "details"}` / `{{:scorer_error, index}, "reason" | "details"}`.

  ## Values

  Each value is the JSON form `Nous.Eval.Codec` stores (strings, numbers,
  booleans, `nil`, lists, string-keyed maps, with Codec tags such as
  `{"$msg": ...}` for a `Nous.Message`). A redactor may replace any value
  with another JSON value or with the atom `:redacted`; it may not add or
  remove paths or touch the skeleton. `Nous.Eval.Online.Redactor.map_text/2`
  rewrites every text leaf and leaves the Codec structure intact.
  """

  @type path ::
          {non_neg_integer() | {:score | :scorer_error, non_neg_integer()}, String.t()}

  @type skeleton_event :: %{
          seq: non_neg_integer(),
          name: [atom()],
          at: integer(),
          measurements: %{optional(atom()) => number()},
          metadata: map()
        }

  @type t :: %__MODULE__{
          trace_id: String.t(),
          skeleton: [skeleton_event()],
          fields: %{optional(path()) => term()}
        }

  @enforce_keys [:trace_id]
  defstruct [:trace_id, skeleton: [], fields: %{}]
end
