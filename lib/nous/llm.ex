defmodule Nous.LLM do
  @moduledoc """
  Simple LLM API for direct model calls without agents.

  This module provides a lightweight interface for making LLM calls
  without the full agent machinery. Use this when you need simple
  text generation, optionally with tools.

  ## Examples

      # Simple generation
      {:ok, text} = Nous.generate_text("openai:gpt-4", "What is 2+2?")
      IO.puts(text) # "4"

      # With options
      text = Nous.generate_text!("anthropic:claude-haiku-4-5", "Hello",
        system: "You are a pirate",
        temperature: 0.7,
        max_tokens: 500
      )

      # With tools
      {:ok, text} = Nous.generate_text("openai:gpt-4", "What's the weather in Paris?",
        tools: [&MyTools.get_weather/2]
      )

      # Streaming
      {:ok, stream} = Nous.stream_text("openai:gpt-4", "Write a story")
      stream |> Stream.each(&IO.write/1) |> Stream.run()

  ## Relationship to `Nous.run/3`

  This is the deliberately thin path: a prompt, a model, optionally tools, and
  nothing else. Individual tool *calls* run through exactly the code the agent
  runner uses, so tool-name cleaning, retry and timeout handling, structured
  error formatting and the `requires_approval` gate behave identically on both
  paths. Everything the runner layers *around* those calls is omitted here by
  design — reach for `Nous.run/3` if you need any of it:

    * **Hooks** — no `:pre_tool_use`/`:post_tool_use`; there is no registry.
    * **Plugins and behaviour callbacks** — no `before_request`, no
      `after_response`, no `after_tool`.
    * **Permission policies** — `Nous.Permissions` tool filtering and
      policy-driven approval do not apply. A tool's own `requires_approval`
      flag still does, enforced by `Nous.ToolExecutor`.
    * **Telemetry** — no `[:nous, :agent, :iteration, _]` events.
    * **Parallel tool calls** — calls in one turn always run sequentially.
    * **Context updates** — every call in a run sees the same
      `Nous.RunContext`. A tool may still return a `Nous.Tool.ContextUpdate`,
      but its operations are discarded rather than merged into `:deps`, so they
      are invisible to later calls and iterations.
    * **A configurable iteration budget** — the cap is a fixed 10 model turns.
      `generate_text/3` returns `{:error, %Nous.Errors.MaxIterationsExceeded{}}`
      on reaching it; `stream_text/3` yields that error as a final event.

  """

  alias Nous.{Fallback, Model, ModelDispatcher, Message, Tool, RunContext, Messages}
  alias Nous.AgentRunner.{RequestDispatch, ToolExecution}
  alias Nous.StreamNormalizer.ToolCallAccumulator

  # Resolve the dispatcher for this call. `override` is the caller's
  # `:model_dispatcher` option (usually nil); see `Nous.ModelDispatcher.resolve/1`
  # for the full precedence chain.
  defp get_dispatcher(override) do
    ModelDispatcher.resolve(override)
  end

  require Logger

  @max_tool_iterations 10

  @type option ::
          {:system, String.t()}
          | {:temperature, float()}
          | {:max_tokens, pos_integer()}
          | {:top_p, float()}
          | {:base_url, String.t()}
          | {:api_key, String.t()}
          | {:receive_timeout, non_neg_integer()}
          | {:tools, [function() | Tool.t()]}
          | {:deps, map()}
          | {:fallback, [String.t() | Model.t()]}
          | {:approval_handler, Nous.RunContext.approval_handler()}
          | {:model_dispatcher, module()}

  @doc """
  Generate text from a model.

  Returns `{:ok, text}` on success, `{:error, reason}` on failure.

  If tools are provided and the model calls them, they will be executed
  automatically and the conversation will continue until the model returns
  a text response.

  ## Parameters

    * `model` - Model string ("provider:model-name") or `%Model{}` struct
    * `prompt` - The user prompt
    * `opts` - Options (see below)

  ## Options

    * `:system` - System prompt
    * `:temperature` - Sampling temperature (0.0 to 2.0)
    * `:max_tokens` - Maximum tokens to generate
    * `:top_p` - Nucleus sampling parameter
    * `:base_url` - Override API base URL
    * `:api_key` - Override API key
    * `:receive_timeout` - HTTP receive timeout in milliseconds (default varies by provider)
    * `:tools` - List of tool functions or Tool structs
    * `:deps` - Dependencies to pass to tool functions
    * `:fallback` - Ordered list of fallback model strings or `Model` structs to try
      when the primary model fails with a provider/model error
    * `:approval_handler` - Called before any tool with `requires_approval: true`
      runs (`Nous.Tools.Bash`, `FileWrite`, `FileEdit`). Without it those tools
      are rejected rather than executed — this entry point has no other gate.
    * `:model_dispatcher` - Override the module that performs the provider
      request, for this call only. Takes precedence over
      `config :nous, :model_dispatcher`. Mostly useful in tests; see
      `Nous.ModelDispatcher.resolve/1`.

  ## Examples

      {:ok, text} = Nous.LLM.generate_text("openai:gpt-4", "What is 2+2?")

      {:ok, text} = Nous.LLM.generate_text("anthropic:claude-haiku-4-5", "Hello",
        system: "You are helpful",
        temperature: 0.7
      )

      # With tools
      {:ok, text} = Nous.LLM.generate_text("openai:gpt-4", "What's the weather?",
        tools: [&MyTools.get_weather/2],
        deps: %{api_key: "..."}
      )

  """
  @spec generate_text(String.t() | Model.t(), String.t(), [option()]) ::
          {:ok, String.t()} | {:error, term()}
  def generate_text(model, prompt, opts \\ [])

  def generate_text(model_string, prompt, opts) when is_binary(model_string) do
    model =
      Model.parse(
        model_string,
        Keyword.take(opts, [:base_url, :api_key, :llamacpp_model, :receive_timeout])
      )

    generate_text(model, prompt, opts)
  end

  def generate_text(%Model{} = model, prompt, opts) do
    messages = build_messages(prompt, opts)
    tools = parse_tools(Keyword.get(opts, :tools, []))
    settings = build_settings(opts, tools, model.provider)
    deps = Keyword.get(opts, :deps, %{})
    ctx = RunContext.new(deps, approval_handler: Keyword.get(opts, :approval_handler))
    fallback_models = Fallback.parse_fallback_models(Keyword.get(opts, :fallback, []))
    model_chain = Fallback.build_model_chain(model, fallback_models)

    dispatcher = Keyword.get(opts, :model_dispatcher)

    Fallback.with_fallback(model_chain, fn target_model ->
      target_settings =
        RequestDispatch.rebuild_tool_settings(
          target_model.provider,
          model.provider,
          settings,
          tools
        )

      run_with_tools(target_model, messages, target_settings, tools, ctx, 0, dispatcher)
    end)
  after
    # This entry point warmed the provider-payload cache in the caller's own
    # process (`Nous.Messages.Cache`); release it rather than retain the whole
    # converted history. `after`, so a raising tool or provider does not leak
    # it. generate_text!/3 rides on this clause.
    Messages.Cache.clear()
  end

  @doc """
  Generate text from a model, raising on error.

  Same as `generate_text/3` but raises `Nous.Errors.ModelError` on failure.

  ## Examples

      text = Nous.LLM.generate_text!("openai:gpt-4", "What is 2+2?")
      IO.puts(text) # "4"

  """
  @spec generate_text!(String.t() | Model.t(), String.t(), [option()]) :: String.t()
  def generate_text!(model, prompt, opts \\ []) do
    case generate_text(model, prompt, opts) do
      {:ok, text} ->
        text

      {:error, reason} ->
        raise Nous.Errors.ModelError, message: "Generation failed: #{inspect(reason)}"
    end
  end

  @doc """
  Stream text from a model.

  Returns `{:ok, stream}` where `stream` yields text chunks as strings.

  ## Parameters

    * `model` - Model string ("provider:model-name") or `%Model{}` struct
    * `prompt` - The user prompt
    * `opts` - Options (same as `generate_text/3`)

  ## Examples

      {:ok, stream} = Nous.LLM.stream_text("openai:gpt-4", "Write a haiku")
      stream |> Stream.each(&IO.write/1) |> Stream.run()

  """
  @spec stream_text(String.t() | Model.t(), String.t(), [option()]) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_text(model, prompt, opts \\ [])

  def stream_text(model_string, prompt, opts) when is_binary(model_string) do
    model =
      Model.parse(
        model_string,
        Keyword.take(opts, [:base_url, :api_key, :llamacpp_model, :receive_timeout])
      )

    stream_text(model, prompt, opts)
  end

  def stream_text(%Model{} = model, prompt, opts) do
    messages = build_messages(prompt, opts)
    tools = parse_tools(Keyword.get(opts, :tools, []))
    settings = build_settings(opts, tools, model.provider)
    deps = Keyword.get(opts, :deps, %{})
    ctx = RunContext.new(deps, approval_handler: Keyword.get(opts, :approval_handler))
    fallback_models = Fallback.parse_fallback_models(Keyword.get(opts, :fallback, []))
    model_chain = Fallback.build_model_chain(model, fallback_models)

    dispatcher = Keyword.get(opts, :model_dispatcher)

    if tools == [] do
      stream_text_simple(model_chain, model, settings, messages, dispatcher)
    else
      stream =
        stream_text_with_tools(model_chain, model, settings, messages, tools, ctx, dispatcher)

      {:ok, stream}
    end
  after
    # Covers the tool-free branch, whose request -- and therefore the payload
    # conversion -- is issued before the stream is handed back. The tool branch
    # converts once per turn while the CONSUMER enumerates, so it clears from
    # the Stream.resource after-fun in stream_text_with_tools/7 instead.
    Messages.Cache.clear()
  end

  defp stream_text_simple(model_chain, original_model, settings, messages, dispatcher) do
    case Fallback.with_fallback(model_chain, fn target_model ->
           target_settings =
             RequestDispatch.rebuild_tool_settings(
               target_model.provider,
               original_model.provider,
               settings,
               []
             )

           get_dispatcher(dispatcher).request_stream(target_model, messages, target_settings)
         end) do
      {:ok, stream} ->
        {:ok, text_only_stream(stream)}

      {:error, _} = error ->
        error
    end
  end

  defp text_only_stream(stream) do
    stream
    |> Stream.filter(fn
      {:text_delta, _} -> true
      _ -> false
    end)
    |> Stream.map(fn {:text_delta, text} -> text end)
  end

  # Multi-turn streaming with tool execution. Each turn is consumed eagerly to
  # extract aggregated tool calls and content; text deltas are still yielded
  # to the caller as they were produced. After a turn finishes, if any tool
  # calls were made, they're executed and a follow-up stream is started.
  defp stream_text_with_tools(
         model_chain,
         original_model,
         settings,
         initial_messages,
         tools,
         ctx,
         dispatcher
       ) do
    Stream.resource(
      fn -> {initial_messages, 0} end,
      fn
        :done ->
          {:halt, :done}

        {_messages, iteration} when iteration >= @max_tool_iterations ->
          # Surface the cap as an event, mirroring the request-failure branch
          # below. A silent :halt is indistinguishable from a turn that simply
          # finished, so a consumer had no way to see its conversation was
          # truncated. generate_text/3 returns this same error on this cap.
          Logger.warning(
            "LLM stream hit max tool iterations (#{@max_tool_iterations}); emitting :error event"
          )

          error =
            Nous.Errors.MaxIterationsExceeded.exception(max_iterations: @max_tool_iterations)

          {[{:error, error}], :done}

        {messages, iteration} ->
          case request_stream_with_fallback(
                 model_chain,
                 original_model,
                 messages,
                 settings,
                 tools,
                 dispatcher
               ) do
            {:ok, raw_stream} ->
              continue_stream_turn(raw_stream, messages, iteration, tools, ctx)

            {:error, reason} ->
              # Surface the failure as an event before halting. Previously
              # this silently :halt'd, so a consumer iterating the stream
              # saw it cleanly terminate with no signal that the LLM call
              # had actually failed.
              Logger.warning("LLM stream failed: #{inspect(reason)}; emitting :error event")
              {[{:error, reason}], :done}
          end
      end,
      fn _ -> Messages.Cache.clear() end
    )
  end

  # One streaming request across the fallback chain. Tool settings are rebuilt
  # per attempt because the chain may land on a provider whose tool wire format
  # differs from the one the caller's settings were written for.
  defp request_stream_with_fallback(
         model_chain,
         original_model,
         messages,
         settings,
         tools,
         dispatcher
       ) do
    Fallback.with_fallback(model_chain, fn target_model ->
      target_settings =
        RequestDispatch.rebuild_tool_settings(
          target_model.provider,
          original_model.provider,
          settings,
          tools
        )

      get_dispatcher(dispatcher).request_stream(target_model, messages, target_settings)
    end)
  end

  # Outcome of one consumed turn: halt when the model asked for no tools,
  # otherwise append the assistant message plus tool results and loop again.
  defp continue_stream_turn(raw_stream, messages, iteration, tools, ctx) do
    {chunks, tool_calls, content} = aggregate_stream_turn(raw_stream)

    if tool_calls == [] do
      {chunks, :done}
    else
      Logger.debug("LLM stream produced #{length(tool_calls)} tool call(s), executing...")

      assistant_msg = build_streamed_assistant_message(content, tool_calls)
      tool_results = execute_tool_calls(tool_calls, tools, ctx)
      new_messages = messages ++ [assistant_msg] ++ tool_results
      {chunks, {new_messages, iteration + 1}}
    end
  end

  defp aggregate_stream_turn(stream) do
    initial = %{chunks: [], tool_acc: ToolCallAccumulator.new(), content: ""}

    result =
      Enum.reduce(stream, initial, fn
        {:text_delta, text}, acc ->
          %{acc | chunks: [text | acc.chunks], content: acc.content <> text}

        {:tool_call_delta, fragment}, acc ->
          # Tool-call deltas are PARTIAL provider-specific fragments (OpenAI
          # emits a list with split arguments JSON; Anthropic emits tagged
          # start/partial/stop fragments). Feed them through the accumulator —
          # treating each as a complete call crashed OpenAI (Access on a list)
          # and produced nil-arg calls on Anthropic.
          %{acc | tool_acc: ToolCallAccumulator.feed(acc.tool_acc, fragment)}

        _other, acc ->
          acc
      end)

    tool_calls =
      result.tool_acc
      |> ToolCallAccumulator.finalize()
      |> Enum.map(&ensure_tool_call_id/1)

    {Enum.reverse(result.chunks), tool_calls, result.content}
  end

  defp ensure_tool_call_id(call) do
    cond do
      call["id"] -> call
      call[:id] -> call
      true -> Map.put(call, "id", "stream_" <> random_id())
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp build_streamed_assistant_message(content, tool_calls) do
    attrs = %{role: :assistant, tool_calls: tool_calls}

    attrs =
      case content do
        "" -> attrs
        nil -> attrs
        text -> Map.put(attrs, :content, text)
      end

    Message.new!(attrs)
  end

  # Private helpers

  # Request loop. Deliberately not the runner's `IterationLoop`: there is no
  # %Agent{}, no %Agent.Context{} and no hook registry here (see the moduledoc
  # for the full list of omissions). Only the per-call execution below is
  # shared, which is where the two implementations actually drifted.
  defp run_with_tools(model, messages, settings, tools, ctx, iteration, dispatcher)
       when iteration < @max_tool_iterations do
    case get_dispatcher(dispatcher).request(model, messages, settings) do
      {:ok, response} ->
        tool_calls = Messages.extract_tool_calls([response])

        if tool_calls == [] do
          # No tool calls - return the text
          {:ok, Message.extract_text(response)}
        else
          # Execute tools and continue
          Logger.debug("LLM requested #{length(tool_calls)} tool call(s), executing...")

          tool_results = execute_tool_calls(tool_calls, tools, ctx)
          new_messages = messages ++ [response] ++ tool_results

          run_with_tools(model, new_messages, settings, tools, ctx, iteration + 1, dispatcher)
        end

      {:error, _} = error ->
        error
    end
  end

  defp run_with_tools(_model, _messages, _settings, _tools, _ctx, _iteration, _dispatcher) do
    {:error, Nous.Errors.MaxIterationsExceeded.exception(max_iterations: @max_tool_iterations)}
  end

  # One tool executor for the whole library. `execute_single_tool/3` owns
  # tool-name cleaning, ContextUpdate returns, the legacy `__update_context__`
  # key and structured error formatting — this module reimplemented a subset of
  # that and got the ContextUpdate arity wrong, raising CaseClauseError on any
  # tool that used it.
  #
  # The returned context-update map is dropped: there is no %Agent.Context{} to
  # merge it into, and this entry point's contract is stateless across calls.
  defp execute_tool_calls(tool_calls, tools, ctx) do
    Enum.map(tool_calls, fn call ->
      {result_msg, _context_updates} = ToolExecution.execute_single_tool(tools, call, ctx)
      result_msg
    end)
  end

  defp parse_tools(tools) do
    Enum.map(tools, fn
      %Tool{} = tool -> tool
      fun when is_function(fun) -> Tool.from_function(fun)
    end)
  end

  defp build_messages(prompt, opts) do
    system = Keyword.get(opts, :system)

    if system do
      [Message.system(system), Message.user(prompt)]
    else
      [Message.user(prompt)]
    end
  end

  defp build_settings(opts, tools, provider) do
    base_settings =
      opts
      |> Keyword.take([:temperature, :max_tokens, :top_p, :enable_thinking, :extra_body])
      |> Map.new()

    if tools == [] do
      base_settings
    else
      tool_schemas = RequestDispatch.convert_tools_for_provider(provider, tools)
      Map.put(base_settings, :tools, tool_schemas)
    end
  end
end
