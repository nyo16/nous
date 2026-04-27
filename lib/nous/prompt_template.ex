defmodule Nous.PromptTemplate do
  # validate_bindings/2 uses MapSet.difference/2 on MapSets built from
  # heterogeneous keys (`bindings` may key on atoms or strings, and
  # `extract_variables/1` returns `[atom() | String.t()]` per C-2). That
  # heterogeneity confuses dialyzer's opaque tracking even though the
  # operation is well-typed.
  @dialyzer :no_opaque

  @moduledoc """
  Safe prompt templates for building messages.

  Templates use a tightly-constrained `<%= @var %>` substitution syntax;
  the template body is **not** passed through `EEx.eval_string/2`, so
  template content from LLM output, tool results, or other untrusted
  sources cannot trigger arbitrary Elixir evaluation. Templates that
  contain `<%` markers other than the simple variable form are rejected
  by `from_template/2`.

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

  This module deliberately does not support `<%= if ... do %>` blocks or
  arbitrary Elixir expressions. Build conditional structure by composing
  multiple smaller templates with `compose/2` or `to_messages/2`.

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
    case validate_template_safety(text) do
      :ok ->
        %__MODULE__{
          text: text,
          role: Keyword.get(opts, :role, :user),
          inputs: Keyword.get(opts, :inputs, %{})
        }

      {:error, reason} ->
        raise ArgumentError,
              "PromptTemplate: " <>
                reason <>
                ". This module only supports `<%= @var %>` substitution; arbitrary " <>
                "EEx expressions are rejected because template bodies that flow " <>
                "from LLM output / tool results / untrusted strings could otherwise " <>
                "execute arbitrary Elixir."
    end
  end

  # Reject any `<%` marker that isn't a simple `<%= @ident %>` substitution.
  # Compose multiple templates if you need conditional structure.
  defp validate_template_safety(text) do
    # Strip every valid `<%= @var %>` (with optional whitespace) and check
    # that no other `<%` remains. This rejects `<% if ... do %>`, `<% end %>`,
    # `<%= System.cmd(...) %>`, and any other expression form.
    stripped = String.replace(text, ~r/<%=\s*@\w+\s*%>/, "")

    if String.contains?(stripped, "<%") do
      {:error, "template contains unsupported <% ... %> expression"}
    else
      :ok
    end
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

  Variables that match an existing atom are returned as atoms (matching what
  callers pass in `bindings`). Unknown variables are returned as strings to
  avoid uncontrolled atom-table growth from attacker-controlled template bodies.

  """
  @spec extract_variables(String.t()) :: [atom() | String.t()]
  def extract_variables(text) when is_binary(text) do
    Regex.scan(~r/@(\w+)/, text)
    |> Enum.map(fn [_, var] -> safe_to_existing_atom(var) end)
    |> Enum.uniq()
  end

  defp safe_to_existing_atom(binary) do
    String.to_existing_atom(binary)
  rescue
    ArgumentError -> binary
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
    role =
      case templates do
        [first | _] -> first.role
        [] -> :user
      end

    # Merge all inputs
    merged_inputs =
      Enum.reduce(templates, %{}, fn template, acc ->
        Map.merge(acc, template.inputs)
      end)

    # Join all texts
    combined_text =
      templates
      |> Enum.map(& &1.text)
      |> Enum.join(separator)

    %__MODULE__{
      text: combined_text,
      role: role,
      inputs: merged_inputs
    }
  end

  # Private functions

  # Substitute `<%= @var %>` with the value from `bindings`. Missing keys
  # are left as the original placeholder so callers see clearly which var
  # wasn't bound. Values are converted via `to_string/1`. The bindings map
  # may key on either atom or string; both are tried (atoms preferred).
  defp do_format(text, bindings) when is_map(bindings) do
    Regex.replace(~r/<%=\s*@(\w+)\s*%>/, text, fn full_match, var_name ->
      case lookup_binding(bindings, var_name) do
        {:ok, value} -> to_string(value)
        :error -> full_match
      end
    end)
  end

  defp lookup_binding(bindings, var_name) do
    atom_key =
      try do
        String.to_existing_atom(var_name)
      rescue
        ArgumentError -> nil
      end

    cond do
      not is_nil(atom_key) and Map.has_key?(bindings, atom_key) ->
        Map.fetch(bindings, atom_key)

      Map.has_key?(bindings, var_name) ->
        Map.fetch(bindings, var_name)

      true ->
        :error
    end
  end
end
