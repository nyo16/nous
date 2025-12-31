defmodule Nous.PromptTemplate do
  @moduledoc """
  EEx-based prompt templates for building messages.

  Supports variable substitution, role assignment, and composition
  of messages for agent interactions.

  ## Simple Usage

      template = PromptTemplate.from_template(
        "You are a <%= @role %> assistant that speaks <%= @language %>.",
        role: :system
      )

      message = PromptTemplate.to_message(template, %{role: "helpful", language: "Spanish"})
      # => %Message{role: :system, content: "You are a helpful assistant that speaks Spanish."}

  ## Building Message Lists

      messages = PromptTemplate.to_messages([
        PromptTemplate.from_template("You are <%= @persona %>", role: :system),
        PromptTemplate.from_template("Tell me about <%= @topic %>", role: :user)
      ], %{persona: "a historian", topic: "ancient Rome"})

      # Use with Agent.run
      Agent.run(agent, messages: messages)

  ## Default Values

      template = PromptTemplate.from_template(
        "Search for <%= @query %> with limit <%= @limit %>",
        inputs: %{limit: 10}
      )

      # Only need to provide query, limit has a default
      formatted = PromptTemplate.format(template, %{query: "elixir"})
      # => "Search for elixir with limit 10"

  ## Conditional Content

  Since templates use EEx, you can use conditionals:

      template = PromptTemplate.from_template(\"""
      You are a helpful assistant.
      <%= if @include_tools do %>
      You have access to these tools: <%= @tools %>
      <% end %>
      \""")

  ## String Templates

  For simple string templates without Message conversion:

      text = PromptTemplate.format_string(
        "Hello, <%= @name %>!",
        %{name: "World"}
      )
      # => "Hello, World!"

  """

  alias Nous.Message

  @type t :: %__MODULE__{
          text: String.t(),
          role: :system | :user | :assistant,
          inputs: map()
        }

  @enforce_keys [:text]
  defstruct [:text, role: :user, inputs: %{}]

  @doc """
  Create a template from a string with `<%= @var %>` placeholders.

  ## Options

  - `:role` - Message role (`:system`, `:user`, `:assistant`). Default: `:user`
  - `:inputs` - Default variable values. Default: `%{}`

  ## Example

      template = PromptTemplate.from_template(
        "You are a <%= @role %> assistant.",
        role: :system,
        inputs: %{role: "helpful"}
      )

  """
  @spec from_template(String.t(), keyword()) :: t()
  def from_template(text, opts \\ []) when is_binary(text) do
    %__MODULE__{
      text: text,
      role: Keyword.get(opts, :role, :user),
      inputs: Keyword.get(opts, :inputs, %{})
    }
  end

  @doc """
  Create a system message template.

  Shorthand for `from_template(text, role: :system)`.

  ## Example

      template = PromptTemplate.system("You are a <%= @persona %>")

  """
  @spec system(String.t(), keyword()) :: t()
  def system(text, opts \\ []) when is_binary(text) do
    from_template(text, Keyword.put(opts, :role, :system))
  end

  @doc """
  Create a user message template.

  Shorthand for `from_template(text, role: :user)`.

  ## Example

      template = PromptTemplate.user("Tell me about <%= @topic %>")

  """
  @spec user(String.t(), keyword()) :: t()
  def user(text, opts \\ []) when is_binary(text) do
    from_template(text, Keyword.put(opts, :role, :user))
  end

  @doc """
  Create an assistant message template.

  Shorthand for `from_template(text, role: :assistant)`.

  ## Example

      template = PromptTemplate.assistant("I understand you want <%= @action %>")

  """
  @spec assistant(String.t(), keyword()) :: t()
  def assistant(text, opts \\ []) when is_binary(text) do
    from_template(text, Keyword.put(opts, :role, :assistant))
  end

  @doc """
  Format template with variable substitution.

  Merges provided bindings with default inputs (bindings take precedence).

  ## Example

      template = from_template("Hello, <%= @name %>!", inputs: %{name: "World"})

      format(template, %{})        # => "Hello, World!"
      format(template, %{name: "Elixir"})  # => "Hello, Elixir!"

  """
  @spec format(t(), map()) :: String.t()
  def format(%__MODULE__{text: text, inputs: default_inputs}, bindings \\ %{}) do
    merged = Map.merge(default_inputs, bindings)
    do_format(text, merged)
  end

  @doc """
  Format a string template directly without creating a PromptTemplate struct.

  ## Example

      PromptTemplate.format_string("Hello, <%= @name %>!", %{name: "World"})
      # => "Hello, World!"

  """
  @spec format_string(String.t(), map()) :: String.t()
  def format_string(text, bindings) when is_binary(text) and is_map(bindings) do
    do_format(text, bindings)
  end

  @doc """
  Convert template to Message with variable substitution.

  ## Example

      template = from_template("You are a <%= @role %> assistant", role: :system)
      message = to_message(template, %{role: "helpful"})
      # => %Message{role: :system, content: "You are a helpful assistant"}

  """
  @spec to_message(t(), map()) :: Message.t()
  def to_message(%__MODULE__{role: role} = template, bindings \\ %{}) do
    content = format(template, bindings)

    case role do
      :system -> Message.system(content)
      :user -> Message.user(content)
      :assistant -> Message.assistant(content)
    end
  end

  @doc """
  Convert list of templates and/or messages to messages.

  Items can be:
  - `%PromptTemplate{}` - Will be formatted with bindings
  - `%Message{}` - Passed through unchanged

  ## Example

      messages = to_messages([
        PromptTemplate.system("You are <%= @persona %>"),
        Message.user("Hello"),
        PromptTemplate.user("Tell me about <%= @topic %>")
      ], %{persona: "helpful", topic: "Elixir"})

  """
  @spec to_messages([t() | Message.t()], map()) :: [Message.t()]
  def to_messages(items, bindings \\ %{}) when is_list(items) do
    Enum.map(items, fn
      %__MODULE__{} = template -> to_message(template, bindings)
      %Message{} = message -> message
    end)
  end

  @doc """
  Create messages from a list of role/content tuples with shared bindings.

  Convenient for building message lists inline.

  ## Example

      messages = PromptTemplate.build_messages([
        {:system, "You are a <%= @role %> assistant"},
        {:user, "Hello, my name is <%= @name %>"}
      ], %{role: "helpful", name: "Alice"})

  """
  @spec build_messages([{atom(), String.t()}], map()) :: [Message.t()]
  def build_messages(items, bindings \\ %{}) when is_list(items) do
    Enum.map(items, fn {role, text} ->
      template = from_template(text, role: role)
      to_message(template, bindings)
    end)
  end

  @doc """
  Extract all variable names from a template.

  Useful for validation or documentation.

  ## Example

      template = from_template("Hello <%= @name %>, you are <%= @age %> years old")
      variables(template)
      # => [:name, :age]

  """
  @spec variables(t()) :: [atom()]
  def variables(%__MODULE__{text: text}) do
    extract_variables(text)
  end

  @doc """
  Extract variable names from a template string.

  ## Example

      PromptTemplate.extract_variables("Hello <%= @name %>!")
      # => [:name]

  """
  @spec extract_variables(String.t()) :: [atom()]
  def extract_variables(text) when is_binary(text) do
    Regex.scan(~r/@(\w+)/, text)
    |> Enum.map(fn [_, var] -> String.to_atom(var) end)
    |> Enum.uniq()
  end

  @doc """
  Check if all required variables are present in bindings.

  Returns `{:ok, bindings}` if all variables are present,
  or `{:error, missing_vars}` if some are missing.

  ## Example

      template = from_template("Hello <%= @name %>, age <%= @age %>")

      validate_bindings(template, %{name: "Alice", age: 30})
      # => {:ok, %{name: "Alice", age: 30}}

      validate_bindings(template, %{name: "Alice"})
      # => {:error, [:age]}

  """
  @spec validate_bindings(t(), map()) :: {:ok, map()} | {:error, [atom()]}
  def validate_bindings(%__MODULE__{} = template, bindings) do
    required = variables(template)
    available = Map.merge(template.inputs, bindings)
    provided = MapSet.new(Map.keys(available))
    required_set = MapSet.new(required)

    missing = MapSet.difference(required_set, provided) |> MapSet.to_list()

    if Enum.empty?(missing) do
      {:ok, available}
    else
      {:error, missing}
    end
  end

  @doc """
  Compose multiple templates into a single template.

  Joins templates with the specified separator.

  ## Example

      intro = system("You are a helpful assistant.")
      rules = system("Follow these rules: <%= @rules %>")

      combined = compose([intro, rules], "\\n\\n")
      # Creates a single :system template with both texts joined

  """
  @spec compose([t()], String.t()) :: t()
  def compose(templates, separator \\ "\n") when is_list(templates) do
    # Use the role of the first template
    role = case templates do
      [first | _] -> first.role
      [] -> :user
    end

    # Merge all inputs
    merged_inputs = Enum.reduce(templates, %{}, fn template, acc ->
      Map.merge(acc, template.inputs)
    end)

    # Join all texts
    combined_text = templates
    |> Enum.map(& &1.text)
    |> Enum.join(separator)

    %__MODULE__{
      text: combined_text,
      role: role,
      inputs: merged_inputs
    }
  end

  # Private functions

  defp do_format(text, bindings) do
    assigns = Map.to_list(bindings)
    EEx.eval_string(text, assigns: assigns)
  end
end
