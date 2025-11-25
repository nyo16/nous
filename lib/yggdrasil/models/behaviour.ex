defmodule Yggdrasil.Models.Behaviour do
  @moduledoc """
  Behaviour for model implementations.

  All model providers must implement this behaviour to be compatible
  with Yggdrasil agents.
  """

  alias Yggdrasil.{Model, Types}

  @doc """
  Make a request to the model.

  ## Parameters
    * `model` - Model configuration
    * `messages` - List of message tuples and previous responses
    * `settings` - Request settings (temperature, max_tokens, tools, etc.)

  ## Returns
    * `{:ok, response}` - Successfully got response with parts, usage, model_name, timestamp
    * `{:error, reason}` - Request failed
  """
  @callback request(Model.t(), [Types.message()], map()) ::
              {:ok, Types.model_response()} | {:error, term()}

  @doc """
  Make a streaming request to the model.

  ## Parameters
    * `model` - Model configuration
    * `messages` - List of message tuples and previous responses
    * `settings` - Request settings with streaming enabled

  ## Returns
    * `{:ok, stream}` - Stream of events
    * `{:error, reason}` - Request failed
  """
  @callback request_stream(Model.t(), [Types.message()], map()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Count tokens in messages (can be an estimate).

  Optional callback - defaults to rough estimation if not implemented.
  """
  @callback count_tokens([Types.message()]) :: integer()

  @optional_callbacks count_tokens: 1
end
