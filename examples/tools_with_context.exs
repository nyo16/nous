#!/usr/bin/env elixir

# Example: Using Context (ctx) in Tools
#
# This demonstrates how to pass dependencies (like user_id, user struct,
# database connections, etc.) to tools via the RunContext.

# Note: In a real app, these would be in separate files
# For the script, we use maps instead of structs to avoid compilation issues

# ============================================================================
# Define Tools that Use Context
# ============================================================================

defmodule UserTools do
  @doc """
  Get current user's account balance.

  This tool accesses the user from context (ctx.deps.user)
  """
  def get_balance(ctx, _args) do
    user = ctx.deps.user

    %{
      user_id: user[:id],
      user_name: user[:name],
      balance: user[:account_balance],
      currency: "USD"
    }
  end

  @doc """
  Get user preferences.

  Accesses user struct from context.
  """
  def get_preferences(ctx, _args) do
    user = ctx.deps.user

    %{
      user_id: user[:id],
      preferences: user[:preferences],
      theme: get_in(user, [:preferences, :theme]) || "light",
      language: get_in(user, [:preferences, :language]) || "en"
    }
  end

  @doc """
  Search user's items in database.

  Uses both user (for filtering) and database (for querying) from context.
  """
  def search_my_items(ctx, args) do
    user = ctx.deps.user
    # In real app: db = ctx.deps.database
    query = Map.get(args, "query", "")

    # Mock database search filtered by user
    IO.puts("  🔍 Searching for '#{query}' for user #{user[:id]}")

    %{
      user_id: user[:id],
      query: query,
      results: [
        %{id: 1, name: "Item 1", owner: user[:id]},
        %{id: 2, name: "Item 2", owner: user[:id]}
      ],
      count: 2
    }
  end

  @doc """
  Make API call using API key from context.

  Demonstrates accessing configuration from context.
  """
  def call_external_api(ctx, args) do
    api_key = ctx.deps.api_key
    endpoint = Map.get(args, "endpoint", "/users")

    IO.puts("  🌐 Calling API with key: #{String.slice(api_key, 0..10)}...")

    # Mock API call
    %{
      endpoint: endpoint,
      authenticated: api_key != nil,
      response: "API response data",
      user_context: ctx.deps.user[:name]
    }
  end

  @doc """
  Update user preferences.

  Shows how tools can modify data through context.
  """
  def update_preferences(ctx, args) do
    user = ctx.deps.user
    new_theme = Map.get(args, "theme", "light")

    IO.puts("  💾 Updating preferences for user #{user[:id]}")

    # In real app, you'd update the database
    # db = ctx.deps.database
    # Database.update_user_preferences(db, user.id, %{theme: new_theme})

    %{
      user_id: user[:id],
      updated: true,
      new_preferences: %{theme: new_theme},
      message: "Preferences updated for #{user[:name]}"
    }
  end
end

IO.puts("\n🔧 Nous AI - Tools with Context Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# ============================================================================
# Create Agent with Tools
# ============================================================================

agent = Nous.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a personal assistant with access to user information and tools.
  Always personalize responses using the user's name when relevant.
  Use the tools to access user-specific data.
  """,
  tools: [
    &UserTools.get_balance/2,
    &UserTools.get_preferences/2,
    &UserTools.search_my_items/2,
    &UserTools.call_external_api/2,
    &UserTools.update_preferences/2
  ]
)

# ============================================================================
# Setup Dependencies (This is what gets passed as ctx.deps)
# ============================================================================

# Using maps instead of structs for the script
user = %{
  id: 123,
  name: "Alice",
  email: "alice@example.com",
  preferences: %{
    theme: "dark",
    language: "en",
    notifications: true
  },
  account_balance: 1_250.50
}

deps = %{
  user: user,
  database: :mock_db,  # In real app: MyApp.Database
  api_key: "sk-secret-key-12345",
  config: %{env: :dev}
}

IO.puts("User: #{user[:name]} (ID: #{user[:id]})")
IO.puts("Balance: $#{user[:account_balance]}")
IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Example 1: Access User Balance
# ============================================================================

IO.puts("\n💰 Example 1: Check Balance")
IO.puts("-" |> String.duplicate(70))

{:ok, result1} = Nous.run(
  agent,
  "What's my account balance?",
  deps: deps  # ← Pass dependencies here!
)

IO.puts(result1.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Example 2: Search with User Context
# ============================================================================

IO.puts("\n🔍 Example 2: Search My Items")
IO.puts("-" |> String.duplicate(70))

{:ok, result2} = Nous.run(
  agent,
  "Search my items for 'project'",
  deps: deps  # Tools get user.id to filter results
)

IO.puts(result2.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Example 3: Multi-User Scenario
# ============================================================================

IO.puts("\n👥 Example 3: Different Users, Different Results")
IO.puts("-" |> String.duplicate(70))

# User 1: Alice
{:ok, result_alice} = Nous.run(
  agent,
  "What's my name and balance?",
  deps: deps
)

IO.puts("Alice's result:")
IO.puts(result_alice.output)
IO.puts("")

# User 2: Bob (different user)
bob = %{
  id: 456,
  name: "Bob",
  email: "bob@example.com",
  preferences: %{theme: "light"},
  account_balance: 3_500.00
}

deps_bob = %{
  user: bob,
  database: :mock_db,
  api_key: "sk-secret-key-12345",
  config: %{env: :dev}
}

{:ok, result_bob} = Nous.run(
  agent,
  "What's my name and balance?",
  deps: deps_bob  # Different user!
)

IO.puts("Bob's result:")
IO.puts(result_bob.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Example 4: Accessing Different Context Data
# ============================================================================

IO.puts("\n🎯 Example 4: Access Various Context Data")
IO.puts("-" |> String.duplicate(70))

{:ok, result4} = Nous.run(
  agent,
  "Check my preferences and make an API call to /users endpoint",
  deps: deps
)

IO.puts(result4.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Summary
# ============================================================================

IO.puts("\n✨ Key Takeaways:")
IO.puts("")
IO.puts("1. Context Structure:")
IO.puts("   ctx.deps.user        # Access user")
IO.puts("   ctx.deps.database    # Access database")
IO.puts("   ctx.deps.api_key     # Access API keys")
IO.puts("   ctx.deps.config      # Access config")
IO.puts("")
IO.puts("2. In Tools:")
IO.puts("   def my_tool(ctx, args) do")
IO.puts("     user = ctx.deps.user")
IO.puts("     db = ctx.deps.database")
IO.puts("     # Use them!")
IO.puts("   end")
IO.puts("")
IO.puts("3. When Running Agent:")
IO.puts("   Nous.run(agent, prompt,")
IO.puts("     deps: %MyDeps{user: user, ...}")
IO.puts("   )")
IO.puts("")
IO.puts("4. Multi-User:")
IO.puts("   - Different deps for each user")
IO.puts("   - Same agent, personalized results")
IO.puts("   - Perfect for web apps!")
IO.puts("")
IO.puts("💡 Use cases:")
IO.puts("  ✓ Multi-tenant applications")
IO.puts("  ✓ User-specific data access")
IO.puts("  ✓ Database connection injection")
IO.puts("  ✓ API key management")
IO.puts("  ✓ Per-user permissions")
IO.puts("")
