defmodule Nous.Message.Codec do
  @moduledoc false

  # The one place that turns persisted message fields back into a
  # `%Nous.Message{}`. `Nous.Agent.Context.deserialize/1` and
  # `Nous.Eval.Codec` both read messages back from storage, so the role table
  # lives here rather than being copied into each of them. Roles come from a
  # literal table, never `String.to_atom/1`: persisted data is untrusted.

  alias Nous.Message
  alias Nous.Message.ContentPart

  @roles %{
    "system" => :system,
    "user" => :user,
    "assistant" => :assistant,
    "tool" => :tool
  }

  @doc """
  Decodes a persisted role (atom or string) through the closed role table.
  """
  @spec decode_role(term()) :: {:ok, atom()} | :error
  def decode_role(role) when role in [:system, :user, :assistant, :tool], do: {:ok, role}

  def decode_role(role) when is_binary(role), do: Map.fetch(@roles, role)
  def decode_role(_role), do: :error

  @doc """
  Every field of `message` under its string name, values untouched.

  Callers that persist to JSON encode `tool_calls`, `metadata` and `content`
  (which may hold `Nous.Message.ContentPart` structs) themselves.
  """
  @spec to_fields(Message.t()) :: %{String.t() => term()}
  def to_fields(%Message{} = message) do
    %{
      "role" => Atom.to_string(message.role),
      "content" => message.content,
      "reasoning_content" => message.reasoning_content,
      "tool_calls" => message.tool_calls,
      "tool_call_id" => message.tool_call_id,
      "name" => message.name,
      "metadata" => message.metadata,
      "created_at" => message.created_at
    }
  end

  @doc """
  Rebuilds a message from `to_fields/1`'s shape (values already decoded).

  The fields are type-checked rather than run through `Message.new/1`: a
  stored message is a record of what was sent, and `new/1`'s constructor
  rules (it stamps a fresh `created_at`, rejects shapes `Message.assistant/2`
  and friends legitimately build) would rewrite it.
  """
  @spec from_fields(map()) :: {:ok, Message.t()} | {:error, term()}
  def from_fields(%{} = fields) do
    with {:ok, role} <- or_error(decode_role(fields["role"]), :role, fields["role"]),
         {:ok, content} <- content(fields["content"]),
         {:ok, reasoning} <- optional_string(:reasoning_content, fields["reasoning_content"]),
         {:ok, tool_calls} <- tool_calls(fields["tool_calls"]),
         {:ok, tool_call_id} <- optional_string(:tool_call_id, fields["tool_call_id"]),
         {:ok, name} <- optional_string(:name, fields["name"]),
         {:ok, metadata} <- metadata(fields["metadata"]),
         {:ok, created_at} <- created_at(fields["created_at"]) do
      {:ok,
       %Message{
         role: role,
         content: content,
         reasoning_content: reasoning,
         tool_calls: tool_calls,
         tool_call_id: tool_call_id,
         name: name,
         metadata: metadata,
         created_at: created_at
       }}
    end
  end

  defp or_error({:ok, _} = ok, _field, _value), do: ok
  defp or_error(:error, field, value), do: {:error, {:invalid_message_field, field, value}}

  defp content(content) when is_binary(content) or is_nil(content), do: {:ok, content}

  defp content(parts) when is_list(parts) do
    if Enum.all?(parts, &is_struct(&1, ContentPart)),
      do: {:ok, parts},
      else: {:error, {:invalid_message_field, :content, parts}}
  end

  defp content(other), do: {:error, {:invalid_message_field, :content, other}}

  defp optional_string(_field, value) when is_binary(value) or is_nil(value), do: {:ok, value}
  defp optional_string(field, value), do: {:error, {:invalid_message_field, field, value}}

  defp tool_calls(nil), do: {:ok, []}

  defp tool_calls(calls) when is_list(calls) do
    if Enum.all?(calls, &is_map/1),
      do: {:ok, calls},
      else: {:error, {:invalid_message_field, :tool_calls, calls}}
  end

  defp tool_calls(other), do: {:error, {:invalid_message_field, :tool_calls, other}}

  defp metadata(nil), do: {:ok, %{}}
  defp metadata(%{} = metadata), do: {:ok, metadata}
  defp metadata(other), do: {:error, {:invalid_message_field, :metadata, other}}

  defp created_at(%DateTime{} = at), do: {:ok, at}
  defp created_at(nil), do: {:ok, nil}
  defp created_at(other), do: {:error, {:invalid_message_field, :created_at, other}}
end
