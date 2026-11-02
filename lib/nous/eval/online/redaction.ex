defmodule Nous.Eval.Online.Redaction do
  @moduledoc false
  # Splits a captured trace into skeleton and content
  # (`Nous.Eval.Online.Content`), runs the redactor under its contract, and
  # rebuilds the trace (or a sample's score explanations) from the result.
  #
  # Raw content exists only in the job process (and the redactor's own
  # process, which is killed on timeout). On any redactor failure the
  # content is dropped and only the failure kind survives; the exception,
  # its message and the offending value are discarded unread, because they
  # may quote the content.

  alias Nous.Eval.{Codec, Score, ScorerError, Trace}
  alias Nous.Eval.Online.Content
  alias Nous.Eval.Trace.Event

  # Metadata keys that are skeleton while their value is a scalar. Every
  # other key - including ones a later Nous adds - is content.
  @skeleton_keys MapSet.new([
                   :trace_id,
                   :agent_run_id,
                   :parent_agent_run_id,
                   :tool_call_id,
                   :parent_tool_call_id,
                   :profile_id,
                   :role,
                   :sub_agent_template,
                   :sub_agent_index,
                   :agent_name,
                   :model_provider,
                   :model_name,
                   :tool_count,
                   :has_tools,
                   :active_model_provider,
                   :active_model_name,
                   :fallback_used,
                   :kind,
                   :iteration,
                   :max_iterations,
                   :needs_response,
                   :tool_calls,
                   :original_provider,
                   :original_model,
                   :active_provider,
                   :active_model,
                   :failed_provider,
                   :failed_model,
                   :next_provider,
                   :next_model,
                   :router,
                   :granularity,
                   :turn,
                   :tier,
                   :confidence,
                   :count,
                   :provider,
                   :message_count,
                   :has_tool_calls,
                   :tool_module,
                   :attempt,
                   :max_retries,
                   :has_timeout,
                   :success,
                   :will_retry,
                   :callback_type,
                   :event,
                   :hook_name,
                   :hook_type,
                   :verdict,
                   :canary_failed,
                   :backend,
                   :model,
                   :chunk_count,
                   :surface,
                   :aggregation,
                   :fail_closed,
                   :strategy,
                   :severity,
                   :skill_name,
                   :group,
                   :activation_type,
                   :messages_before,
                   :messages_after,
                   :llm_called,
                   :question_count,
                   :mode,
                   :workflow_id,
                   :workflow_name,
                   :node_count,
                   :status,
                   :nodes_executed,
                   :node_id,
                   :node_type,
                   :stream,
                   :finish_reason,
                   :outcome,
                   :approval,
                   :result_modified,
                   :retries_left,
                   :action,
                   :chain_length,
                   :threshold,
                   :error_kind
                 ])

  @name_lists [:tool_names, :blocked_tool_names]

  # Keys whose value is a tool name the model chose. Skeleton only when the
  # name is one the run offered (`tool_names` / `blocked_tool_names` of the
  # run's model requests); any other name is content.
  @chosen_tool_name_keys [:tool_name]

  # Score metadata that describes the instrument, not the sample.
  @score_metadata_keys [
    :label,
    :labels,
    :label_values,
    :scale,
    :prompt_hash,
    :fingerprint_id,
    :model,
    :usage,
    :judge_trace_id
  ]

  @type status :: :redacted | :dropped | {:failed, atom()}

  # ── split ──────────────────────────────────────────────────────────────────

  @doc false
  # `{content, keys}`: the Content handed to the redactor and the original
  # metadata key of each field name, for `rebuild/3`.
  @spec split(Trace.t()) :: {Content.t(), %{String.t() => term()}}
  def split(%Trace{trace_id: trace_id, events: events}) do
    offered = offered_tools(events)

    {skeleton, fields, keys} =
      Enum.reduce(events, {[], %{}, %{}}, fn %Event{} = event, {skel, fields, keys} ->
        {meta, content} = split_metadata(event.metadata, offered)

        entry = %{
          seq: event.seq,
          name: event.name,
          at: event.at,
          measurements: numeric(event.measurements),
          metadata: meta
        }

        {fields, keys} =
          Enum.reduce(content, {fields, keys}, fn {key, value}, {fields, keys} ->
            field = field_name(key)

            {Map.put(fields, {event.seq, field}, Codec.encode_value(value)),
             Map.put(keys, field, key)}
          end)

        {[entry | skel], fields, keys}
      end)

    {%Content{trace_id: trace_id, skeleton: Enum.reverse(skeleton), fields: fields}, keys}
  end

  # `%{agent_run_id => MapSet of tool names}`: every name a run's model
  # requests offered or blocked. A model can answer with any string as a tool
  # name; only these names are the developer's, not the model's.
  defp offered_tools(events) do
    for %Event{metadata: %{} = meta} <- events,
        key <- @name_lists,
        names when is_list(names) <- [Map.get(meta, key)],
        name when is_binary(name) <- names,
        reduce: %{} do
      acc ->
        Map.update(acc, Map.get(meta, :agent_run_id), MapSet.new([name]), &MapSet.put(&1, name))
    end
  end

  defp split_metadata(metadata, offered) when is_map(metadata) do
    offered = Map.get(offered, Map.get(metadata, :agent_run_id), MapSet.new())

    Enum.reduce(metadata, {error_kind(metadata), []}, fn {key, value}, {meta, content} ->
      case skeleton_value(key, value, offered) do
        {:ok, kept} -> {Map.put(meta, key, kept), content}
        {:both, kept, also} -> {Map.put(meta, key, kept), [{key, also} | content]}
        :content -> {meta, [{key, value} | content]}
      end
    end)
  end

  defp split_metadata(_metadata, _offered), do: {%{}, []}

  # Each requested call's id is skeleton, its tool name only when offered.
  # When a call names any other tool, the ids and names are content as well,
  # so the redactor decides what survives of them.
  defp skeleton_value(:requested_tool_calls, calls, offered) when is_list(calls) do
    calls =
      for %{} = call <- calls do
        for key <- [:tool_call_id, :tool_name],
            is_binary(Map.get(call, key)),
            into: %{},
            do: {key, Map.fetch!(call, key)}
      end

    kept = Enum.map(calls, &offered_name(&1, offered))

    if kept == calls, do: {:ok, kept}, else: {:both, kept, calls}
  end

  defp skeleton_value(key, name, offered) when key in @chosen_tool_name_keys do
    if is_binary(name) and MapSet.member?(offered, name), do: {:ok, name}, else: :content
  end

  defp skeleton_value(key, names, _offered) when key in @name_lists and is_list(names) do
    if Enum.all?(names, &scalar?/1), do: {:ok, names}, else: :content
  end

  defp skeleton_value(key, value, _offered) do
    if MapSet.member?(@skeleton_keys, key) and scalar?(value), do: {:ok, value}, else: :content
  end

  defp offered_name(%{tool_name: name} = call, offered) do
    if MapSet.member?(offered, name), do: call, else: Map.delete(call, :tool_name)
  end

  defp offered_name(call, _offered), do: call

  defp scalar?(value),
    do: is_nil(value) or is_binary(value) or is_atom(value) or is_number(value)

  # The kind of a failure, never its text: the exception module, or the
  # atom of an atom / tagged-tuple reason.
  defp error_kind(%{reason: reason}) do
    case kind_of(reason) do
      nil -> %{}
      kind -> %{error_kind: kind}
    end
  end

  defp error_kind(_metadata), do: %{}

  defp kind_of(%{__exception__: true, __struct__: module}), do: inspect(module)
  defp kind_of(reason) when is_atom(reason) and not is_nil(reason), do: Atom.to_string(reason)

  defp kind_of(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) and not is_nil(tag) -> Atom.to_string(tag)
      _ -> nil
    end
  end

  defp kind_of(_reason), do: nil

  defp numeric(measurements) when is_map(measurements),
    do: for({k, v} <- measurements, is_atom(k) and is_number(v), into: %{}, do: {k, v})

  defp numeric(_measurements), do: %{}

  defp field_name(key) when is_atom(key), do: Atom.to_string(key)
  defp field_name(key) when is_binary(key), do: key
  defp field_name(key), do: inspect(key)

  # ── redact ─────────────────────────────────────────────────────────────────

  @doc false
  # Applies `redact` (`:drop_content`, a 1-arity fun or a redactor module)
  # to `content` in a task under `supervisor`, killed after `timeout` ms.
  # `{:ok, content, :redacted | :dropped}`, or `{:error, kind}` with only the
  # failure kind (the caller then keeps the skeleton alone).
  @spec redact(term(), Content.t(), timeout(), GenServer.server()) ::
          {:ok, Content.t(), status()} | {:error, atom()}
  def redact(:drop_content, %Content{} = content, _timeout, _supervisor),
    do: {:ok, %Content{content | fields: %{}}, :dropped}

  def redact(_redactor, %Content{fields: fields} = content, _timeout, _supervisor)
      when map_size(fields) == 0,
      do: {:ok, content, :redacted}

  def redact(redactor, %Content{} = content, timeout, supervisor) do
    task = Task.Supervisor.async_nolink(supervisor, fn -> call(redactor, content) end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, _reason} -> {:failed, :exited}
        nil -> {:failed, :timeout}
      end

    case result do
      {:returned, returned} -> validate(content, returned)
      {:failed, kind} -> {:error, kind}
    end
  end

  # Runs in the redactor's task. Only the kind of a failure leaves it.
  defp call(redactor, content) do
    {:returned, apply_redactor(redactor, content)}
  rescue
    _exception -> {:failed, :raised}
  catch
    :throw, _value -> {:failed, :thrown}
    :exit, _reason -> {:failed, :exited}
  end

  defp apply_redactor(fun, content) when is_function(fun, 1), do: fun.(content)
  defp apply_redactor(module, content) when is_atom(module), do: module.redact(content)

  defp validate(%Content{} = original, %Content{} = returned) do
    cond do
      returned.trace_id != original.trace_id -> {:error, :trace_id_changed}
      returned.skeleton != original.skeleton -> {:error, :skeleton_changed}
      not is_map(returned.fields) -> {:error, :invalid_return}
      not same_keys?(original.fields, returned.fields) -> {:error, :keys_changed}
      not Enum.all?(returned.fields, fn {_path, v} -> json?(v) end) -> {:error, :not_json}
      true -> {:ok, returned, :redacted}
    end
  end

  defp validate(_original, _returned), do: {:error, :invalid_return}

  defp same_keys?(a, b),
    do: map_size(a) == map_size(b) and Enum.all?(Map.keys(a), &Map.has_key?(b, &1))

  defp json?(:redacted), do: true
  defp json?(v) when is_binary(v), do: String.valid?(v)
  defp json?(v) when is_number(v) or is_boolean(v) or is_nil(v), do: true
  defp json?(v) when is_list(v), do: Enum.all?(v, &json?/1)

  defp json?(%{} = map) when not is_struct(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v) end)

  defp json?(_value), do: false

  # ── rebuild ────────────────────────────────────────────────────────────────

  @doc false
  # The trace carried by `content`: skeleton metadata plus the decoded
  # content fields. `{:error, :undecodable}` when a field does not decode.
  @spec rebuild(Trace.t(), Content.t(), %{String.t() => term()}) ::
          {:ok, Trace.t()} | {:error, :undecodable}
  def rebuild(%Trace{} = trace, %Content{skeleton: skeleton, fields: fields}, keys) do
    with {:ok, decoded} <- decode_fields(fields) do
      by_seq = Enum.group_by(decoded, fn {{seq, _field}, _v} -> seq end)

      events =
        Enum.map(skeleton, fn entry ->
          content =
            for {{_seq, field}, value} <- Map.get(by_seq, entry.seq, []),
                into: %{},
                do: {Map.fetch!(keys, field), value}

          %Event{
            name: entry.name,
            at: entry.at,
            seq: entry.seq,
            measurements: entry.measurements,
            metadata: Map.merge(entry.metadata, content)
          }
        end)

      {:ok, %Trace{trace | events: events}}
    end
  end

  @doc false
  # The trace with its content removed (`:drop_content` or a failure).
  @spec skeleton_trace(Trace.t(), Content.t()) :: Trace.t()
  def skeleton_trace(%Trace{} = trace, %Content{} = content) do
    {:ok, trace} = rebuild(trace, %Content{content | fields: %{}}, %{})
    trace
  end

  defp decode_fields(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn {path, value}, {:ok, acc} ->
      case Codec.decode_value(tag_redacted(value)) do
        {:ok, decoded} -> {:cont, {:ok, [{path, decoded} | acc]}}
        {:error, _} -> {:halt, {:error, :undecodable}}
      end
    end)
  end

  defp tag_redacted(:redacted), do: %{"$atom" => "redacted"}
  defp tag_redacted(list) when is_list(list), do: Enum.map(list, &tag_redacted/1)
  defp tag_redacted(%{} = map), do: Map.new(map, fn {k, v} -> {k, tag_redacted(v)} end)
  defp tag_redacted(value), do: value

  # ── score explanations ─────────────────────────────────────────────────────

  @doc false
  # Score and scorer-error `reason`/`details` are content (a judge may quote
  # the sample). Score metadata keeps only the instrument keys. Under
  # `:drop_content`, or when the redactor fails, explanations are removed.
  @spec redact_scores([Score.t()], [ScorerError.t()], String.t(), term(), timeout(), term()) ::
          {[Score.t()], [ScorerError.t()], status()}
  def redact_scores(scores, errors, trace_id, redactor, timeout, supervisor) do
    scores =
      Enum.map(scores, fn %Score{} = s ->
        %{s | metadata: Map.take(s.metadata, @score_metadata_keys)}
      end)

    fields =
      Map.new(
        Enum.flat_map(Enum.with_index(scores), fn {s, i} -> explanation({:score, i}, s) end) ++
          Enum.flat_map(Enum.with_index(errors), fn {e, i} ->
            explanation({:scorer_error, i}, e)
          end)
      )

    content = %Content{trace_id: trace_id, fields: fields}

    case redact(redactor, content, timeout, supervisor) do
      {:ok, %Content{fields: redacted}, status} when map_size(redacted) == map_size(fields) ->
        case decode_fields(redacted) do
          {:ok, decoded} -> apply_explanations(scores, errors, Map.new(decoded), status)
          {:error, kind} -> strip(scores, errors, {:failed, kind})
        end

      {:ok, _content, status} ->
        strip(scores, errors, status)

      {:error, kind} ->
        strip(scores, errors, {:failed, kind})
    end
  end

  defp explanation(index, %{reason: reason, details: details}) do
    [
      {{index, "reason"}, Codec.encode_value(reason)},
      {{index, "details"}, Codec.encode_value(details)}
    ]
  end

  defp apply_explanations(scores, errors, decoded, status) do
    scores =
      scores
      |> Enum.with_index()
      |> Enum.map(fn {s, i} -> explain(s, decoded, {:score, i}) end)

    errors =
      errors
      |> Enum.with_index()
      |> Enum.map(fn {e, i} -> explain(e, decoded, {:scorer_error, i}) end)

    {scores, errors, status}
  end

  defp explain(record, decoded, index) do
    reason = Map.get(decoded, {index, "reason"})
    details = Map.get(decoded, {index, "details"})

    %{
      record
      | reason: if(is_binary(reason), do: reason),
        details: if(is_map(details), do: details, else: %{})
    }
  end

  defp strip(scores, errors, status) do
    {Enum.map(scores, fn %Score{} = s -> %{s | reason: nil, details: %{}} end),
     Enum.map(errors, fn %ScorerError{} = e -> %{e | reason: nil, details: %{}} end), status}
  end
end
