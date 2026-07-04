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

  """

  alias Nous.{Fallback, Model, ModelDispatcher, Message, Tool, ToolExecutor, RunContext, Messages}
  alias Nous.StreamNormalizer.ToolCallAccumulator

  # Get the model dispatcher, allowing dependency injection for testing
  defp get_dispatcher do
    Application.get_env(:nous, :model_dispatcher, ModelDispatcher)
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
    ctx = RunContext.new(deps)
    fallback_models = Fallback.parse_fallback_models(Keyword.get(opts, :fallback, []))
    model_chain = Fallback.build_model_chain(model, fallback_models)

    Fallback.with_fallback(model_chain, fn target_model ->
      target_settings = rebuild_llm_settings(target_model, model, settings, tools)
      run_with_tools(target_model, messages, target_settings, tools, ctx, 0)
    end)
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
    ctx = RunContext.new(deps)
    fallback_models = Fallback.parse_fallback_models(Keyword.get(opts, :fallback, []))
    model_chain = Fallback.build_model_chain(model, fallback_models)

    if tools == [] do
      stream_text_simple(model_chain, model, settings, messages)
    else
      {:ok, stream_text_with_tools(model_chain, model, settings, messages, tools, ctx)}
    end
  end

  defp stream_text_simple(model_chain, original_model, settings, messages) do
    case Fallback.with_fallback(model_chain, fn target_model ->
           target_settings = rebuild_llm_settings(target_model, original_model, settings, [])
           get_dispatcher().request_stream(target_model, messages, target_settings)
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
  defp stream_text_with_tools(model_chain, original_model, settings, initial_messages, tools, ctx) do
    Stream.resource(
      fn -> {initial_messages, 0} end,
      fn
        :done ->
          {:halt, :done}

        {_messages, iteration} when iteration >= @max_tool_iterations ->
          Logger.warning("LLM stream hit max tool iterations (#{@max_tool_iterations}); halting")

          {:halt, :done}

        {messages, iteration} ->
          case Fallback.with_fallback(model_chain, fn target_model ->
                 target_settings =
                   rebuild_llm_settings(target_model, original_model, settings, tools)

                 get_dispatcher().request_stream(target_model, messages, target_settings)
               end) do
            {:ok, raw_stream} ->
              {chunks, tool_calls, content} = aggregate_stream_turn(raw_stream)

              if tool_calls == [] do
                {chunks, :done}
              else
                Logger.debug(
                  "LLM stream produced #{length(tool_calls)} tool call(s), executing..."
                )

                assistant_msg = build_streamed_assistant_message(content, tool_calls)
                tool_results = execute_tool_calls(tool_calls, tools, ctx)
                new_messages = messages ++ [assistant_msg] ++ tool_results
                {chunks, {new_messages, iteration + 1}}
              end

            {:error, reason} ->
              # Surface the failure as an event before halting. Previously
              # this silently :halt'd, so a consumer iterating the stream
              # saw it cleanly terminate with no signal that the LLM call
              # had actually failed.
              Logger.warning("LLM stream failed: #{inspect(reason)}; emitting :error event")
              {[{:error, reason}], :done}
          end
      end,
      fn _ -> :ok end
    )
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

  # Tool execution loop
  defp run_with_tools(model, messages, settings, tools, ctx, iteration)
       when iteration < @max_tool_iterations do
    case get_dispatcher().request(model, messages, settings) do
      {:ok, response} ->
        tool_calls = Messages.extract_tool_calls([response])

        if tool_calls == [] do
          # No tool calls - return the text
          {:ok, extract_text(response)}
        else
          # Execute tools and continue
          Logger.debug("LLM requested #{length(tool_calls)} tool call(s), executing...")

          tool_results = execute_tool_calls(tool_calls, tools, ctx)
          new_messages = messages ++ [response] ++ tool_results

          run_with_tools(model, new_messages, settings, tools, ctx, iteration + 1)
        end

      {:error, _} = error ->
        error
    end
  end

  defp run_with_tools(_model, _messages, _settings, _tools, _ctx, _iteration) do
    {:error, Nous.Errors.MaxIterationsExceeded.exception(max_iterations: @max_tool_iterations)}
  end

  defp execute_tool_calls(tool_calls, tools, ctx) do
    tools_by_name = Map.new(tools, fn tool -> {tool.name, tool} end)

    Enum.map(tool_calls, fn call ->
      name = Nous.ToolCall.field(call, :name)
      id = Nous.ToolCall.field(call, :id)
      arguments = Nous.ToolCall.field(call, :arguments)

      tool = Map.get(tools_by_name, name)

      result =
        if tool do
          case ToolExecutor.execute(tool, arguments, ctx) do
            {:ok, result} -> result
            {:error, error} -> "Error: #{inspect(error)}"
          end
        else
          "Error: Unknown tool '#{name}'"
        end

      Message.tool(id, result, name: name)
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
      tool_schemas = convert_tools_for_provider(provider, tools)
      Map.put(base_settings, :tools, tool_schemas)
    end
  end

  # Rebuild settings when falling back to a model with a different provider
  defp rebuild_llm_settings(target_model, original_model, settings, tools) do
    if target_model.provider == original_model.provider do
      settings
    else
      base_settings = Map.delete(settings, :tools)

      if tools == [] do
        base_settings
      else
        tool_schemas = convert_tools_for_provider(target_model.provider, tools)
        Map.put(base_settings, :tools, tool_schemas)
      end
    end
  end

  defp convert_tools_for_provider(:anthropic, tools) do
    Enum.map(tools, &Nous.ToolSchema.to_anthropic/1)
  end

  defp convert_tools_for_provider(provider, tools) when provider in [:vertex_ai, :gemini] do
    Enum.map(tools, &Nous.ToolSchema.to_gemini/1)
  end

  defp convert_tools_for_provider(_, tools) do
    Enum.map(tools, &Tool.to_openai_schema/1)
  end

  defp extract_text(%Nous.Message{content: content}) when is_binary(content) do
    content
  end

  defp extract_text(%Nous.Message{content: _}) do
    ""
  end
end
