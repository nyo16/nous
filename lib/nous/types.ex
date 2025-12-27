defmodule Nous.Types do
  @moduledoc """
  Core type definitions for Nous AI.

  This module defines all the types used throughout the library.
  No functions, just type specifications for documentation and Dialyzer.
  """

  @typedoc "Model identifier - provider:model string"
  @type model :: String.t()

  @typedoc "Output type specification - :string or an Ecto schema module"
  @type output_type :: :string | module()

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

  @typedoc "Stream event types"
  @type stream_event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call_delta, any()}
          | {:finish, String.t()}
          | {:complete, any()}
          | {:error, term()}
end
