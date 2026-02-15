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

  alias Nous.{Model, ModelDispatcher, Message, Tool, ToolExecutor, RunContext, Messages}

  require Logger

  @max_tool_iterations 10

  @type option ::
          {:system, String.t()}
          | {:temperature, float()}
          | {:max_tokens, pos_integer()}
          | {:top_p, float()}
          | {:base_url, String.t()}
          | {:api_key, String.t()}
          | {:tools, [function() | Tool.t()]}
          | {:deps, map()}

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
    * `:tools` - List of tool functions or Tool structs
    * `:deps` - Dependencies to pass to tool functions

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
    model = Model.parse(model_string, Keyword.take(opts, [:base_url, :api_key]))
    generate_text(model, prompt, opts)
  end

  def generate_text(%Model{} = model, prompt, opts) do
    messages = build_messages(prompt, opts)
    tools = parse_tools(Keyword.get(opts, :tools, []))
    settings = build_settings(opts, tools, model.provider)
    deps = Keyword.get(opts, :deps, %{})
    ctx = RunContext.new(deps)

    run_with_tools(model, messages, settings, tools, ctx, 0)
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
    model = Model.parse(model_string, Keyword.take(opts, [:base_url, :api_key]))
    stream_text(model, prompt, opts)
  end

  def stream_text(%Model{} = model, prompt, opts) do
    messages = build_messages(prompt, opts)
    # Note: streaming with tools is not supported yet
    settings = build_settings(opts, [], model.provider)

    case ModelDispatcher.request_stream(model, messages, settings) do
      {:ok, stream} ->
        # Transform stream to only yield text deltas as strings
        text_stream =
          stream
          |> Stream.filter(fn
            {:text_delta, _} -> true
            _ -> false
          end)
          |> Stream.map(fn {:text_delta, text} -> text end)

        {:ok, text_stream}

      {:error, _} = error ->
        error
    end
  end

  # Private helpers

  # Tool execution loop
  defp run_with_tools(model, messages, settings, tools, ctx, iteration)
       when iteration < @max_tool_iterations do
    case ModelDispatcher.request(model, messages, settings) do
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
      # Handle both atom and string keys
      name = call[:name] || call["name"]
      id = call[:id] || call["id"]
      arguments = call[:arguments] || call["arguments"]

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

      Message.tool(id, result)
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
      |> Keyword.take([:temperature, :max_tokens, :top_p])
      |> Map.new()

    if tools == [] do
      base_settings
    else
      tool_schemas = convert_tools_for_provider(provider, tools)
      Map.put(base_settings, :tools, tool_schemas)
    end
  end

  defp convert_tools_for_provider(:anthropic, tools) do
    Enum.map(tools, &Nous.ToolSchema.to_anthropic/1)
  end

  defp convert_tools_for_provider(_, tools) do
    Enum.map(tools, &Tool.to_openai_schema/1)
  end

  # Handle Message struct (from OpenAI-compatible providers)
  defp extract_text(%Nous.Message{content: content}) when is_binary(content) do
    content
  end

  # Handle response with parts (from native Anthropic/Gemini)
  defp extract_text(%{parts: parts}) when is_list(parts) do
    parts
    |> Enum.filter(fn
      {:text, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:text, text} -> text end)
    |> Enum.join("")
  end

  # Fallback for any map with content field
  defp extract_text(%{content: content}) when is_binary(content) do
    content
  end
end
