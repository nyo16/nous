defmodule Nous.Message do
  @moduledoc """
  Represents a message in a conversation with an AI model.

  Messages support multi-modal content, tool calls, and various roles
  following OpenAI's standard message format while providing Elixir-native
  validation and type safety.

  ## Message Roles

  - `:system` - System instructions and context
  - `:user` - User input and queries
  - `:assistant` - AI model responses
  - `:tool` - Tool execution results

  ## Examples

      # Simple text messages
      iex> Message.system("You are a helpful assistant")
      %Message{role: :system, content: "You are a helpful assistant"}

      iex> Message.user("Hello!")
      %Message{role: :user, content: "Hello!"}

      # Multi-modal user message
      iex> Message.user([
      ...>   ContentPart.text("What's in this image?"),
      ...>   ContentPart.image_url("https://example.com/image.jpg")
      ...> ])
      %Message{role: :user, content: [%ContentPart{}, %ContentPart{}]}

      # Assistant message with tool calls
      iex> Message.assistant("Let me search for that", tool_calls: [
      ...>   %{id: "call_123", name: "search", arguments: %{"query" => "elixir"}}
      ...> ])
      %Message{role: :assistant, content: "Let me search for that", tool_calls: [...]}

  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Nous.Message.ContentPart

  @roles ~w(system user assistant tool)a

  @primary_key false
  embedded_schema do
    field(:role, Ecto.Enum, values: @roles)
    field(:content, :string)
    field(:tool_calls, {:array, :map}, default: [])
    field(:tool_call_id, :string)
    # For tool messages
    field(:name, :string)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @type t :: %__MODULE__{
          role: atom(),
          content: String.t() | nil,
          tool_calls: [map()],
          tool_call_id: String.t() | nil,
          name: String.t() | nil,
          metadata: map(),
          created_at: DateTime.t()
        }

  @doc """
  Create a new message.

  Returns `{:ok, message}` on success or `{:error, changeset}` on validation failure.

  ## Examples

      iex> Message.new(%{role: :user, content: "Hello"})
      {:ok, %Message{role: :user, content: "Hello"}}

      iex> Message.new(%{role: :invalid})
      {:error, %Ecto.Changeset{}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> case do
      %Ecto.Changeset{valid?: true} = changeset ->
        {:ok, Ecto.Changeset.apply_changes(changeset)}

      invalid_changeset ->
        {:error, invalid_changeset}
    end
  end

  @doc """
  Create a new message, raising on validation failure.

  ## Examples

      iex> Message.new!(%{role: :user, content: "Hello"})
      %Message{role: :user, content: "Hello"}

  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, message} -> message
      {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
    end
  end

  # Role-specific constructors

  @doc """
  Create a system message.

  System messages provide instructions and context for the AI model.

  ## Examples

      iex> Message.system("You are a helpful assistant")
      %Message{role: :system, content: "You are a helpful assistant"}

  """
  @spec system(String.t() | [ContentPart.t()], keyword()) :: t()
  def system(content, opts \\ []) do
    attrs =
      %{role: :system, content: content}
      |> Map.merge(Map.new(opts))

    new!(attrs)
  end

  @doc """
  Create a user message.

  User messages contain input, queries, and multi-modal content.

  ## Examples

      iex> Message.user("Hello!")
      %Message{role: :user, content: "Hello!"}

      iex> Message.user([ContentPart.text("Hi"), ContentPart.image_url("...")])
      %Message{role: :user, content: [%ContentPart{}, %ContentPart{}]}

  """
  @spec user(String.t() | [ContentPart.t()], keyword()) :: t()
  def user(content, opts \\ [])

  def user(content, opts) when is_binary(content) do
    attrs =
      %{role: :user, content: content}
      |> Map.merge(Map.new(opts))

    new!(attrs)
  end

  def user(content_parts, opts) when is_list(content_parts) do
    # For multi-modal content, convert to text and store parts in metadata
    text_content = ContentPart.to_text(content_parts)

    attrs = %{
      role: :user,
      content: text_content,
      metadata: Map.merge(Map.new(opts), %{content_parts: content_parts})
    }

    new!(attrs)
  end

  @doc """
  Create an assistant message.

  Assistant messages contain AI model responses, including tool calls.

  ## Examples

      iex> Message.assistant("Hello there!")
      %Message{role: :assistant, content: "Hello there!"}

      iex> Message.assistant("Let me search", tool_calls: [%{...}])
      %Message{role: :assistant, content: "Let me search", tool_calls: [%{...}]}

  """
  @spec assistant(String.t() | [ContentPart.t()], keyword()) :: t()
  def assistant(content, opts \\ []) do
    attrs =
      %{role: :assistant, content: content}
      |> Map.merge(Map.new(opts))

    new!(attrs)
  end

  @doc """
  Create a tool result message.

  Tool messages contain the results of tool/function executions.

  ## Examples

      iex> Message.tool("call_123", "Search results: ...", name: "search")
      %Message{role: :tool, content: "Search results: ...", tool_call_id: "call_123", name: "search"}

  """
  @spec tool(String.t(), String.t() | map(), keyword()) :: t()
  def tool(tool_call_id, result, opts \\ []) do
    content = if is_binary(result), do: result, else: Jason.encode!(result)

    attrs =
      %{role: :tool, content: content, tool_call_id: tool_call_id}
      |> Map.merge(Map.new(opts))

    new!(attrs)
  end

  # Utility functions

  @doc """
  Extract text content from a message.

  ## Examples

      iex> message = Message.user("Hello world")
      iex> Message.extract_text(message)
      "Hello world"

      iex> message = Message.user([ContentPart.text("Hi"), ContentPart.image_url("...")])
      iex> Message.extract_text(message)
      "Hi"

  """
  @spec extract_text(t()) :: String.t()
  def extract_text(%__MODULE__{content: content}) when is_binary(content), do: content

  def extract_text(%__MODULE__{content: content}) when is_list(content) do
    ContentPart.extract_text(content)
  end

  @doc """
  Convert message content to plain text representation.

  ## Examples

      iex> message = Message.user([
      ...>   ContentPart.text("Check this out: "),
      ...>   ContentPart.image_url("https://example.com/img.jpg")
      ...> ])
      iex> Message.to_text(message)
      "Check this out: [Image: https://example.com/img.jpg]"

  """
  @spec to_text(t()) :: String.t()
  def to_text(%__MODULE__{content: content}) when is_binary(content), do: content

  def to_text(%__MODULE__{content: content}) when is_list(content) do
    ContentPart.to_text(content)
  end

  @doc """
  Check if message has tool calls.

  ## Examples

      iex> message = Message.assistant("Hello")
      iex> Message.has_tool_calls?(message)
      false

      iex> message = Message.assistant("Search", tool_calls: [%{id: "call_1", ...}])
      iex> Message.has_tool_calls?(message)
      true

  """
  @spec has_tool_calls?(t()) :: boolean()
  def has_tool_calls?(%__MODULE__{tool_calls: tool_calls}) do
    is_list(tool_calls) and length(tool_calls) > 0
  end

  @doc """
  Check if message is tool-related (tool call or tool result).

  ## Examples

      iex> Message.is_tool_related?(Message.tool("call_1", "result"))
      true

      iex> Message.is_tool_related?(Message.assistant("text", tool_calls: [%{}]))
      true

      iex> Message.is_tool_related?(Message.user("hello"))
      false

  """
  @spec is_tool_related?(t()) :: boolean()
  def is_tool_related?(%__MODULE__{role: :tool}), do: true
  def is_tool_related?(%__MODULE__{} = message), do: has_tool_calls?(message)

  @doc """
  Check if message is from user.

  ## Examples

      iex> Message.from_user?(Message.user("hello"))
      true

      iex> Message.from_user?(Message.assistant("hi"))
      false

  """
  @spec from_user?(t()) :: boolean()
  def from_user?(%__MODULE__{role: :user}), do: true
  def from_user?(_), do: false

  @doc """
  Check if message is from assistant.

  ## Examples

      iex> Message.from_assistant?(Message.assistant("hello"))
      true

      iex> Message.from_assistant?(Message.user("hi"))
      false

  """
  @spec from_assistant?(t()) :: boolean()
  def from_assistant?(%__MODULE__{role: :assistant}), do: true
  def from_assistant?(_), do: false

  @doc """
  Check if message is system instruction.

  ## Examples

      iex> Message.is_system?(Message.system("You are helpful"))
      true

      iex> Message.is_system?(Message.user("hi"))
      false

  """
  @spec is_system?(t()) :: boolean()
  def is_system?(%__MODULE__{role: :system}), do: true
  def is_system?(_), do: false

  @doc """
  Get message content as ContentPart list.

  Always returns a list, converting string content to text parts.

  ## Examples

      iex> Message.get_content_parts(Message.user("Hello"))
      [%ContentPart{type: :text, content: "Hello"}]

  """
  @spec get_content_parts(t()) :: [ContentPart.t()]
  def get_content_parts(%__MODULE__{content: content}) when is_binary(content) do
    [ContentPart.text(content)]
  end

  def get_content_parts(%__MODULE__{content: content}) when is_list(content) do
    content
  end

  @doc """
  Add metadata to a message.

  ## Examples

      iex> message = Message.user("hello")
      iex> Message.put_metadata(message, :source, "web_ui")
      %Message{metadata: %{source: "web_ui"}}

  """
  @spec put_metadata(t(), atom() | String.t(), any()) :: t()
  def put_metadata(%__MODULE__{} = message, key, value) do
    %{message | metadata: Map.put(message.metadata, key, value)}
  end

  @doc """
  Get metadata from a message.

  ## Examples

      iex> message = Message.user("hello", metadata: %{source: "api"})
      iex> Message.get_metadata(message, :source)
      "api"

  """
  @spec get_metadata(t(), atom() | String.t(), any()) :: any()
  def get_metadata(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  # Conversion utilities for backward compatibility

  @doc """
  Convert from legacy tuple format.

  ## Examples

      iex> Message.from_legacy({:user_prompt, "Hello"})
      %Message{role: :user, content: "Hello"}

      iex> Message.from_legacy({:system_prompt, "Instructions"})
      %Message{role: :system, content: "Instructions"}

  """
  @spec from_legacy(tuple() | map()) :: t()
  def from_legacy({:system_prompt, content}) when is_binary(content) do
    system(content)
  end

  def from_legacy({:user_prompt, content}) when is_binary(content) do
    user(content)
  end

  def from_legacy({:user_prompt, content}) when is_list(content) do
    parts =
      Enum.map(content, fn
        {:text, text} -> ContentPart.text(text)
        {:image_url, url} -> ContentPart.image_url(url)
        text when is_binary(text) -> ContentPart.text(text)
        other -> ContentPart.text(inspect(other))
      end)

    user(parts)
  end

  def from_legacy({:tool_return, %{call_id: id, result: result}}) do
    tool(id, result)
  end

  def from_legacy(%{parts: parts, model_name: model_name} = response) do
    content_parts = convert_response_parts(parts)

    tool_calls = extract_tool_calls_from_parts(parts)

    attrs = %{
      role: :assistant,
      content: content_parts,
      metadata: %{
        model_name: model_name,
        usage: Map.get(response, :usage),
        timestamp: Map.get(response, :timestamp)
      }
    }

    attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

    new!(attrs)
  end

  # Private functions

  defp changeset(message, attrs) do
    message
    |> cast(attrs, [:role, :content, :tool_calls, :tool_call_id, :name, :metadata])
    |> validate_required([:role])
    |> put_change(:created_at, DateTime.utc_now())
    |> validate_content()
    |> validate_role_constraints()
  end

  defp validate_content(%Ecto.Changeset{} = changeset) do
    role = get_field(changeset, :role)
    content = get_field(changeset, :content)

    case {role, content} do
      {_, nil} ->
        # Allow nil content for assistant messages (streaming can populate later)
        if role == :assistant do
          changeset
        else
          add_error(changeset, :content, "content is required")
        end

      {_, ""} ->
        add_error(changeset, :content, "content cannot be empty")

      {_, content} when is_binary(content) ->
        changeset

      {_, content} when is_list(content) ->
        validate_content_parts(changeset, content)

      _ ->
        add_error(changeset, :content, "content must be a string or list of content parts")
    end
  end

  defp validate_content_parts(changeset, parts) do
    if Enum.all?(parts, &is_struct(&1, ContentPart)) do
      changeset
    else
      add_error(changeset, :content, "all content parts must be ContentPart structs")
    end
  end

  defp validate_role_constraints(%Ecto.Changeset{} = changeset) do
    role = get_field(changeset, :role)
    tool_call_id = get_field(changeset, :tool_call_id)
    tool_calls = get_field(changeset, :tool_calls)

    case role do
      :tool ->
        if is_nil(tool_call_id) do
          add_error(changeset, :tool_call_id, "tool_call_id is required for tool messages")
        else
          changeset
        end

      _ ->
        if tool_call_id do
          add_error(changeset, :tool_call_id, "tool_call_id is only allowed for tool messages")
        else
          changeset
        end
    end
    |> validate_tool_calls(tool_calls)
  end

  defp validate_tool_calls(changeset, tool_calls) when is_list(tool_calls) do
    if Enum.all?(tool_calls, &is_map/1) do
      changeset
    else
      add_error(changeset, :tool_calls, "tool_calls must be a list of maps")
    end
  end

  defp validate_tool_calls(changeset, _), do: changeset

  defp convert_response_parts(parts) when is_list(parts) do
    content_parts =
      Enum.map(parts, fn
        {:text, text} -> ContentPart.text(text)
        {:thinking, content} -> ContentPart.thinking(content)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case content_parts do
      [] -> ""
      [%ContentPart{type: :text} = single_text] -> single_text.content
      multiple -> ContentPart.to_text(multiple)
    end
  end

  defp extract_tool_calls_from_parts(parts) when is_list(parts) do
    parts
    |> Enum.filter(&match?({:tool_call, _}, &1))
    |> Enum.map(fn {:tool_call, call} -> call end)
  end
end
