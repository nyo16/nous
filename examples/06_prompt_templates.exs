#!/usr/bin/env elixir

# Nous AI - Prompt Templates (v0.8.0)
# EEx-based templates with variable substitution

IO.puts("=== Nous AI - Prompt Templates Demo ===\n")

alias Nous.PromptTemplate
alias Nous.Message

# ============================================================================
# Basic Template Usage
# ============================================================================

IO.puts("--- Basic Template ---")

template = PromptTemplate.from_template(
  "You are a <%= @role %> assistant that speaks <%= @language %>.",
  role: :system
)

message = PromptTemplate.to_message(template, %{role: "helpful", language: "Spanish"})
IO.puts("Generated message: #{message.content}")
IO.puts("")

# ============================================================================
# Building Message Lists
# ============================================================================

IO.puts("--- Message List from Templates ---")

messages = PromptTemplate.to_messages([
  PromptTemplate.from_template("You are <%= @persona %>", role: :system),
  PromptTemplate.from_template("Tell me about <%= @topic %>", role: :user)
], %{persona: "a historian", topic: "ancient Rome"})

Enum.each(messages, fn msg ->
  IO.puts("[#{msg.role}] #{msg.content}")
end)
IO.puts("")

# ============================================================================
# Using Templates with Agent
# ============================================================================

IO.puts("--- Templates with Agent ---")

agent = Nous.new("lmstudio:qwen3")

# Using the messages: option (v0.8.0)
system_template = PromptTemplate.system("You are a <%= @expert_type %> expert. Be concise.")
user_template = PromptTemplate.user("Explain <%= @concept %> simply.")

messages = PromptTemplate.to_messages(
  [system_template, user_template],
  %{expert_type: "programming", concept: "recursion"}
)

{:ok, result} = Nous.run(agent, messages: messages)
IO.puts("Response: #{result.output}")
IO.puts("")

# ============================================================================
# Template Composition
# ============================================================================

IO.puts("--- Composing Templates ---")

intro = PromptTemplate.system("You are a helpful assistant.")
rules = PromptTemplate.system("Follow these rules: <%= @rules %>")

combined = PromptTemplate.compose([intro, rules], "\n\n")
message = PromptTemplate.to_message(combined, %{rules: "Be brief. Use examples."})
IO.puts("Composed message:")
IO.puts(message.content)
IO.puts("")

# ============================================================================
# Default Values
# ============================================================================

IO.puts("--- Default Values ---")

template_with_defaults = PromptTemplate.from_template(
  "Search for <%= @query %> with limit <%= @limit %>",
  inputs: %{limit: 10}  # Default value
)

# Only need to provide query, limit uses default
formatted = PromptTemplate.format(template_with_defaults, %{query: "elixir"})
IO.puts("With default limit: #{formatted}")

formatted2 = PromptTemplate.format(template_with_defaults, %{query: "elixir", limit: 5})
IO.puts("Override limit: #{formatted2}")
IO.puts("")

# ============================================================================
# Conditional Content
# ============================================================================

IO.puts("--- Conditional Content (EEx) ---")

conditional_template = PromptTemplate.from_template("""
You are a helpful assistant.
<%= if @include_tools do %>
You have access to these tools: <%= @tools %>
<% end %>
""")

# With tools
with_tools = PromptTemplate.format(conditional_template, %{
  include_tools: true,
  tools: "search, calculator"
})
IO.puts("With tools:")
IO.puts(String.trim(with_tools))
IO.puts("")

# Without tools
without_tools = PromptTemplate.format(conditional_template, %{include_tools: false})
IO.puts("Without tools:")
IO.puts(String.trim(without_tools))
IO.puts("")

# ============================================================================
# Extract Variables
# ============================================================================

IO.puts("--- Extract Variables ---")

template = PromptTemplate.from_template(
  "Hello <%= @name %>, you are <%= @age %> years old from <%= @city %>"
)

variables = PromptTemplate.variables(template)
IO.puts("Variables in template: #{inspect(variables)}")

# Validate bindings
case PromptTemplate.validate_bindings(template, %{name: "Alice"}) do
  {:ok, _} -> IO.puts("All variables provided")
  {:error, missing} -> IO.puts("Missing variables: #{inspect(missing)}")
end
IO.puts("")

# ============================================================================
# Build Messages Helper
# ============================================================================

IO.puts("--- Quick Message Building ---")

messages = PromptTemplate.build_messages([
  {:system, "You are a <%= @role %> assistant"},
  {:user, "Hello, my name is <%= @name %>"},
  {:assistant, "Nice to meet you, <%= @name %>!"},
  {:user, "What can you help me with?"}
], %{role: "helpful", name: "Alice"})

Enum.each(messages, fn msg ->
  IO.puts("[#{msg.role}] #{String.slice(msg.content, 0..50)}...")
end)

IO.puts("\nNext: mix run examples/07_module_tools.exs")
