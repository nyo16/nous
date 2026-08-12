defmodule Nous.Types do
  @moduledoc """
  Core type definitions for Nous AI.

  This module defines all the types used throughout the library.
  No functions, just type specifications for documentation and Dialyzer.

  Every type here is public, so your own `@spec`s can refer to them by name
  instead of restating a shape that Nous may widen later.

  ## Examples

  `t:output_type/0` is what you pass as `:output_type` when building an agent.
  All eight variants are values you write literally:

      # raw text (the default)
      Nous.Agent.new("openai:gpt-4o-mini", output_type: :string)

      # schemaless Ecto types
      Nous.Agent.new("openai:gpt-4o-mini", output_type: %{city: :string, population: :integer})

      # an Ecto schema module
      Nous.Agent.new("openai:gpt-4o-mini", output_type: MyApp.WeatherReport)

      # constrained decoding (vLLM/SGLang)
      Nous.Agent.new("vllm:qwen3", output_type: {:choice, ["positive", "negative"]})

  `t:content/0` describes the parts of the legacy tuple message format. You
  build one with `{:user_prompt, [content()]}` and convert it with
  `Nous.Message.from_legacy/1`:

      Nous.Message.from_legacy(
        {:user_prompt,
         [
           {:text, "What is in this picture?"},
           {:image_url, "https://example.com/cat.png"}
         ]}
      )

  New code should build the message directly instead — same result, no
  conversion step:

      alias Nous.Message
      alias Nous.Message.ContentPart

      Message.user([
        ContentPart.text("What is in this picture?"),
        ContentPart.image_url("https://example.com/cat.png")
      ])

  `t:stream_event/0` is the tuple set emitted by `Nous.AgentRunner.run_stream/3`.
  Matching on it exhaustively is the point of the type:

      Enum.reduce(stream, "", fn
        {:text_delta, text}, acc ->
          IO.write(text)
          acc <> text

        {:error, reason}, _acc ->
          raise "stream failed: \#{inspect(reason)}"

        event, acc
        when elem(event, 0) in [:thinking_delta, :tool_call_delta, :usage, :finish, :complete] ->
          acc
      end)

  When you write your own helpers, reference the types rather than copying them:

      @spec summarise([Nous.Types.message()]) :: String.t()
      def summarise(messages), do: Enum.map_join(messages, "\\n", &render/1)
  """

  @typedoc "Model identifier - provider:model string"
  @type model :: String.t()

  @typedoc """
  Output type specification.

  Controls how agent output is parsed and validated:
  - `:string` — raw text (default)
  - `module()` — Ecto schema module → JSON schema + changeset validation
  - `%{atom() => atom()}` — schemaless Ecto types (e.g. `%{name: :string, age: :integer}`)
  - `%{String.t() => map()}` — raw JSON schema map (string keys, passed through as-is)
  - `{:regex, String.t()}` — regex-constrained output (vLLM/SGLang)
  - `{:grammar, String.t()}` — EBNF grammar-constrained output (vLLM)
  - `{:choice, [String.t()]}` — choice-constrained output (vLLM/SGLang)
  - `{:one_of, [module()]}` — multi-schema selection: LLM chooses which schema to use
  """
  @type output_type ::
          :string
          | module()
          | %{atom() => atom()}
          | map()
          | {:regex, String.t()}
          | {:grammar, String.t()}
          | {:choice, [String.t()]}
          | {:one_of, [module()]}

  @typedoc """
  Message content - can be text or multi-modal.

  ## Examples

      "Just text"
      {:text, "Formatted text"}
      {:image_url, "https://example.com/image.png"}
  """
  @type content ::
          String.t()
          | {:text, String.t()}
          | {:image_url, String.t()}
          | {:audio_url, String.t()}
          | {:document_url, String.t()}

  @typedoc "System prompt message part"
  @type system_prompt_part :: {:system_prompt, String.t()}

  @typedoc "User prompt message part"
  @type user_prompt_part :: {:user_prompt, String.t() | [content()]}

  @typedoc "Tool return message part"
  @type tool_return_part :: {:tool_return, tool_return()}

  @typedoc "Text response part from model"
  @type text_part :: {:text, String.t()}

  @typedoc "Tool call part from model"
  @type tool_call_part :: {:tool_call, tool_call()}

  @typedoc "Thinking/reasoning part from model"
  @type thinking_part :: {:thinking, String.t()}

  @typedoc "Message parts that can appear in requests to the model"
  @type request_part :: system_prompt_part() | user_prompt_part() | tool_return_part()

  @typedoc "Message parts that can appear in responses from the model"
  @type response_part :: text_part() | tool_call_part() | thinking_part()

  @typedoc """
  Tool call information from the model.

  The model requests to call a tool with these parameters.
  """
  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @typedoc """
  Tool return information sent back to the model.

  The result of executing a tool call.
  """
  @type tool_return :: %{
          call_id: String.t(),
          result: any()
        }

  @typedoc """
  Model request message.

  A message we send to the model.
  """
  @type model_request :: %{
          parts: [request_part()],
          timestamp: DateTime.t()
        }

  @typedoc """
  Model response message.

  A message we receive from the model, including usage information.
  """
  @type model_response :: %{
          parts: [response_part()],
          usage: Nous.Usage.t(),
          model_name: String.t(),
          timestamp: DateTime.t()
        }

  @typedoc "Any message type"
  @type message :: model_request() | model_response()

  @typedoc """
  Stream event types emitted by `run_stream/3` and the `stream: true` path of `run/3`.

  On successful streams, events typically arrive in this order:
  - `{:text_delta, text}` — incremental text content
  - `{:thinking_delta, text}` — incremental reasoning/thinking content
  - `{:tool_call_delta, calls}` — tool call information (list for OpenAI, map/string for others)
  - `{:usage, usage}` — token usage, emitted as a final chunk for OpenAI-compat
    providers when `stream_options.include_usage` is enabled, or alongside
    Anthropic `message_delta` / Gemini `usageMetadata` chunks
  - `{:finish, reason}` — stream finished, reason is a string like `"stop"` or `"length"`
  - `{:complete, result}` — final aggregated result with `%{output: text, finish_reason: reason}`

  `{:error, reason}` indicates a stream error (HTTP error, timeout, etc.) and may be
  emitted at any point in the stream. When an error occurs, `{:finish, _}` and
  `{:complete, _}` may not be emitted.
  """
  @type stream_event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call_delta, any()}
          | {:usage, map()}
          | {:finish, String.t()}
          | {:complete, map()}
          | {:error, term()}
end
