# 🔄 Migration Guide

Guide for upgrading Nous AI between versions and migrating configurations.

## Quick Migration Checklist

**Upgrading Nous?** Follow these steps:
1. [Check compatibility](#version-compatibility) - Ensure your setup is supported
2. [Backup data](#backup-checklist) - Save important configurations and data
3. [Update dependencies](#updating-dependencies) - Upgrade packages
4. [Test changes](#testing-migrations) - Verify everything works
5. [Deploy safely](#deployment-strategy) - Roll out updates progressively

## Version Compatibility

### Current Version Support

| Version | Status | Support Level | Migration Path |
|---------|--------|---------------|----------------|
| 0.3.x → 0.4.x | ✅ Supported | Full backward compatibility | [Direct upgrade](#03x-to-04x) |
| 0.2.x → 0.4.x | ⚠️ Minor changes | Some API changes | [Staged migration](#02x-to-04x) |
| 0.1.x → 0.4.x | ❌ Major changes | Breaking changes | [Full rewrite](#01x-to-04x) |

### Breaking Changes Summary

#### Version 0.4.x (Current)
- **New features**: Enhanced streaming, multi-provider support
- **Breaking changes**: None (fully backward compatible)
- **Deprecated**: Nothing deprecated

#### Version 0.3.x
- **New features**: Tool calling improvements, better error handling
- **Breaking changes**: Tool signature changes (context parameter added)
- **Deprecated**: Old tool format (removed in 0.4.x)

#### Version 0.2.x
- **New features**: Basic streaming, conversation history
- **Breaking changes**: Agent initialization API changed
- **Deprecated**: Legacy agent creation methods

## Backup Checklist

Before any migration:

```bash
# 1. Backup configuration files
cp config/config.exs config/config.exs.backup
cp config/prod.exs config/prod.exs.backup
cp config/runtime.exs config/runtime.exs.backup

# 2. Export environment variables
env | grep -E "(API_KEY|DATABASE|REDIS)" > env_backup.txt

# 3. Backup conversation data (if stored)
pg_dump myapp_production > conversations_backup.sql

# 4. Create git tag for current version
git tag -a v0.3.2 -m "Pre-migration backup"
git push origin v0.3.2

# 5. Backup deployment configuration
kubectl get configmap myapp-config -o yaml > k8s-config-backup.yaml
```

## Updating Dependencies

### Step 1: Update mix.exs

```elixir
# Before (0.3.x)
defp deps do
  [
    {:nous, "~> 0.3.0"},
    {:openai_ex, "~> 0.8.0"}
  ]
end

# After (0.4.x)
defp deps do
  [
    {:nous, "~> 0.4.0"},
    {:openai_ex, "~> 0.9.17"}  # Updated dependency
  ]
end
```

### Step 2: Update Dependencies

```bash
# Get updated dependencies
mix deps.update --all

# Check for conflicts
mix deps.tree

# Compile and check for warnings
mix compile --warnings-as-errors
```

## Migration Paths

### 0.3.x to 0.4.x (Recommended)

This is the simplest migration with full backward compatibility.

#### Changes Required: None

```elixir
# ✅ This code works in both 0.3.x and 0.4.x
agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
  instructions: "You are a helpful assistant"
)

{:ok, result} = Nous.run(agent, "Hello")
```

#### Optional Improvements

```elixir
# 🆕 Take advantage of new 0.4.x features

# 1. Enhanced streaming
{:ok, stream} = Nous.run_stream(agent, prompt)
stream
|> Stream.each(fn
  {:text_delta, text} -> IO.write(text)
  {:finish, result} -> IO.puts("\nDone!")
end)
|> Stream.run()

# 2. Better error handling
case Nous.run(agent, prompt) do
  {:ok, result} -> process_success(result)
  {:error, :rate_limited} -> handle_rate_limit()
  {:error, :model_unavailable} -> try_fallback_model()
  {:error, reason} -> log_error(reason)
end

# 3. Multi-provider fallback
providers = [
  "anthropic:claude-sonnet-4-5-20250929",
  "openai:gpt-4",
  "lmstudio:qwen3-vl-4b-thinking-mlx"
]

MyApp.FallbackAgent.run_with_providers(prompt, providers)
```

### 0.2.x to 0.4.x (Moderate Changes)

Requires updating tool signatures and agent creation.

#### Tool Migration

```elixir
# ❌ Old 0.2.x tool format
def old_weather_tool(args) do
  location = args["location"]
  "Weather in #{location}: Sunny"
end

# ✅ New 0.4.x tool format (required)
def new_weather_tool(context, args) do
  location = args["location"]

  # Can now access context for user info, permissions, etc.
  user_id = context.deps[:user_id]

  "Weather in #{location}: Sunny"
end

# Update agent creation
# Before:
agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx", [
  tools: [&old_weather_tool/1]  # Single parameter
])

# After:
agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
  tools: [&new_weather_tool/2]  # Two parameters: context, args
)
```

#### Configuration Migration

```elixir
# ❌ Old configuration format
config :nous,
  default_provider: "lmstudio",
  api_keys: %{
    openai: System.get_env("OPENAI_API_KEY")
  }

# ✅ New configuration format
config :nous,
  providers: %{
    anthropic: [
      api_key: System.get_env("ANTHROPIC_API_KEY"),
      base_url: "https://api.anthropic.com"
    ],
    openai: [
      api_key: System.get_env("OPENAI_API_KEY"),
      base_url: "https://api.openai.com"
    ],
    lmstudio: [
      base_url: "http://localhost:1234"
    ]
  }
```

#### Conversation History Migration

```elixir
# ❌ Old message format
messages = [
  %{role: :user, content: "Hello"},
  %{role: :assistant, content: "Hi there!"}
]

# ✅ New message format (string keys)
messages = [
  %{role: "user", content: "Hello"},
  %{role: "assistant", content: "Hi there!"}
]

# Update usage
{:ok, result} = Nous.run(agent, prompt, message_history: messages)
```

### 0.1.x to 0.4.x (Major Migration)

Requires complete rewrite due to fundamental API changes.

#### Agent Creation

```elixir
# ❌ Very old 0.1.x format
agent = NousAI.create_agent(%{
  model_name: "gpt-3.5-turbo",
  system_prompt: "You are helpful",
  tools: [MyTools.weather/1]
})

response = NousAI.chat(agent, "Hello")

# ✅ Modern 0.4.x format
agent = Nous.new("openai:gpt-3.5-turbo",
  instructions: "You are helpful",
  tools: [&MyTools.weather/2]
)

{:ok, result} = Nous.run(agent, "Hello")
```

#### Error Handling Migration

```elixir
# ❌ Old error handling
try do
  response = NousAI.chat(agent, message)
  handle_response(response)
catch
  error -> handle_error(error)
end

# ✅ New error handling
case Nous.run(agent, message) do
  {:ok, result} -> handle_success(result)
  {:error, reason} -> handle_error(reason)
end
```

## Testing Migrations

### Automated Testing Strategy

```elixir
defmodule MigrationTest do
  use ExUnit.Case

  describe "migration compatibility" do
    test "basic agent functionality works" do
      agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx")

      {:ok, result} = Nous.run(agent, "Test message")

      assert is_binary(result.output)
      assert result.usage.total_tokens > 0
    end

    test "tool calling still works" do
      defmodule TestTools do
        def test_tool(_ctx, %{"input" => input}) do
          "Processed: #{input}"
        end
      end

      agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        tools: [&TestTools.test_tool/2]
      )

      {:ok, result} = Nous.run(agent, "Use the test tool with input 'hello'")

      assert result.usage.tool_calls > 0
    end

    test "conversation history is preserved" do
      agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx")

      {:ok, result1} = Nous.run(agent, "My name is Alice")
      {:ok, result2} = Nous.run(agent, "What's my name?",
                                     message_history: result1.new_messages)

      assert String.contains?(result2.output, "Alice")
    end
  end
end
```

### Manual Testing Checklist

```elixir
# Create comprehensive test script
defmodule MigrationValidator do
  def run_full_test_suite do
    tests = [
      {"Basic agent creation", &test_basic_agent/0},
      {"Tool calling", &test_tools/0},
      {"Streaming", &test_streaming/0},
      {"Error handling", &test_errors/0},
      {"Provider switching", &test_providers/0},
      {"Conversation history", &test_history/0}
    ]

    IO.puts("🧪 Running Migration Tests")
    IO.puts("=========================")

    results = Enum.map(tests, fn {name, test_fn} ->
      IO.puts("\n#{name}:")

      try do
        test_fn.()
        IO.puts("  ✅ Passed")
        {name, :passed}
      rescue
        error ->
          IO.puts("  ❌ Failed: #{Exception.message(error)}")
          {name, :failed}
      end
    end)

    print_test_summary(results)
  end

  defp test_basic_agent do
    agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx")
    {:ok, _result} = Nous.run(agent, "Hello")
  end

  defp test_tools do
    defmodule MigrationTestTool do
      def test(_ctx, args), do: "Tool result: #{inspect(args)}"
    end

    agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
      tools: [&MigrationTestTool.test/2]
    )

    {:ok, result} = Nous.run(agent, "Use the test tool")
    assert result.usage.tool_calls > 0
  end

  # ... more test functions
end
```

## Deployment Strategy

### Blue-Green Deployment

```bash
#!/bin/bash
# Blue-green deployment script

# 1. Deploy new version to staging
kubectl apply -f k8s/staging/

# 2. Run migration tests
kubectl exec -it staging-pod -- mix test --only migration

# 3. If tests pass, deploy to production green environment
kubectl apply -f k8s/production-green/

# 4. Switch traffic gradually
kubectl patch service myapp-service -p '{"spec":{"selector":{"version":"green"}}}'

# 5. Monitor for issues
kubectl logs -f deployment/myapp-green

# 6. If stable, remove blue environment
# kubectl delete deployment myapp-blue
```

### Rolling Update

```bash
#!/bin/bash
# Rolling update script

# 1. Update container image
kubectl set image deployment/myapp-agents myapp=myapp:v0.4.0

# 2. Monitor rollout
kubectl rollout status deployment/myapp-agents

# 3. If issues occur, rollback
# kubectl rollout undo deployment/myapp-agents
```

### Canary Deployment

```yaml
# k8s/canary-deployment.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: myapp-agents
spec:
  replicas: 10
  strategy:
    canary:
      steps:
      - setWeight: 10    # 10% traffic to new version
      - pause: {duration: 2m}
      - setWeight: 25    # 25% traffic
      - pause: {duration: 5m}
      - setWeight: 50    # 50% traffic
      - pause: {duration: 10m}
      - setWeight: 100   # Full rollout
```

## Data Migration

### Conversation History

```elixir
defmodule ConversationMigrator do
  @doc """
  Migrate conversation history from old format to new format
  """
  def migrate_conversations do
    # Fetch all conversations from database
    conversations = Repo.all(Conversation)

    Enum.each(conversations, fn conversation ->
      # Convert old message format to new
      migrated_messages = Enum.map(conversation.messages, fn message ->
        %{
          role: to_string(message.role),  # Convert atom to string
          content: message.content,
          timestamp: message.inserted_at
        }
      end)

      # Update conversation with migrated messages
      conversation
      |> Conversation.changeset(%{messages: migrated_messages})
      |> Repo.update!()
    end)

    IO.puts("Migrated #{length(conversations)} conversations")
  end
end
```

### Configuration Migration

```elixir
defmodule ConfigMigrator do
  def migrate_agent_configs do
    # Read old configuration
    old_config = File.read!("config/agents.json")
    |> Jason.decode!()

    # Convert to new format
    new_config = Enum.map(old_config, fn agent_config ->
      %{
        "name" => agent_config["name"],
        "model" => migrate_model_string(agent_config["model"]),
        "instructions" => agent_config["system_prompt"],
        "tools" => migrate_tool_list(agent_config["functions"]),
        "settings" => %{
          "temperature" => agent_config["temperature"] || 0.7,
          "max_tokens" => agent_config["max_tokens"] || -1
        }
      }
    end)

    # Save new configuration
    File.write!("config/agents_v2.json", Jason.encode!(new_config, pretty: true))
  end

  defp migrate_model_string(old_model) do
    case old_model do
      "gpt-3.5-turbo" -> "openai:gpt-3.5-turbo"
      "gpt-4" -> "openai:gpt-4"
      "claude-instant" -> "anthropic:claude-instant-1.2"
      "claude" -> "anthropic:claude-sonnet-4-5-20250929"
      model -> model  # Keep as-is if already in new format
    end
  end
end
```

## Common Migration Issues

### Issue 1: Tool Signature Mismatch

```elixir
# ❌ Error: Tool doesn't accept context parameter
def broken_tool(args) do
  # Old single-parameter format
end

# ✅ Fix: Add context parameter
def fixed_tool(_context, args) do
  # New two-parameter format
end
```

### Issue 2: Message Format Changes

```elixir
# ❌ Error: Atom keys not supported
messages = [%{role: :user, content: "Hello"}]

# ✅ Fix: Use string keys
messages = [%{role: "user", content: "Hello"}]
```

### Issue 3: Configuration Not Loading

```elixir
# ❌ Error: Old configuration format
config :nous, api_key: "..."

# ✅ Fix: New nested configuration
config :nous, :providers,
  anthropic: [api_key: System.get_env("ANTHROPIC_API_KEY")]
```

## Rollback Procedures

### Code Rollback

```bash
#!/bin/bash
# Emergency rollback script

echo "Starting emergency rollback..."

# 1. Rollback container deployment
kubectl rollout undo deployment/myapp-agents

# 2. Wait for rollback to complete
kubectl rollout status deployment/myapp-agents

# 3. Verify old version is running
kubectl get pods -l app=myapp-agents

# 4. Check application health
kubectl exec -it deployment/myapp-agents -- curl http://localhost:4000/health

echo "Rollback complete"
```

### Database Rollback

```sql
-- Rollback conversation message format
UPDATE conversations
SET messages = (
  SELECT json_agg(
    json_build_object(
      'role', (msg->>'role')::text,
      'content', msg->>'content',
      'timestamp', msg->>'timestamp'
    )
  )
  FROM json_array_elements(messages) AS msg
)
WHERE version = '0.4.0';
```

## Version-Specific Guides

### Migrating from 0.3.5 to 0.4.0

```elixir
# No breaking changes - direct upgrade
mix deps.update nous

# Optional: Take advantage of new features
# - Enhanced error handling
# - Better streaming support
# - Multi-provider fallbacks
```

### Migrating from 0.2.8 to 0.4.0

```elixir
# Required changes:

# 1. Update tool signatures
def my_tool(context, args) do  # Added context parameter
  # Implementation
end

# 2. Update agent creation
agent = Nous.new("model:name",  # New model format
  tools: [&my_tool/2]  # Updated arity
)

# 3. Update message history format
messages = [
  %{role: "user", content: "Hello"}  # String keys instead of atoms
]
```

## Post-Migration Validation

```elixir
defmodule PostMigrationValidator do
  def validate_production_deployment do
    checks = [
      {"Agent creation", &test_agent_creation/0},
      {"Tool execution", &test_tool_execution/0},
      {"Error handling", &test_error_handling/0},
      {"Performance", &test_performance/0}
    ]

    IO.puts("🔍 Post-Migration Validation")
    IO.puts("===========================")

    results = Enum.map(checks, fn {name, check} ->
      IO.write("#{name}: ")

      case check.() do
        :ok ->
          IO.puts("✅")
          {name, :pass}
        {:error, reason} ->
          IO.puts("❌ #{reason}")
          {name, :fail}
      end
    end)

    failures = Enum.filter(results, fn {_, status} -> status == :fail end)

    if failures == [] do
      IO.puts("\n🎉 All validation checks passed!")
    else
      IO.puts("\n⚠️  #{length(failures)} checks failed - investigate before proceeding")
    end
  end
end
```

## Need Help?

If you encounter issues during migration:

1. **Check the changelog** for version-specific breaking changes
2. **Review the troubleshooting guide** for common issues
3. **Test in staging** before production deployment
4. **Have rollback plan ready** before starting migration
5. **Create an issue** on GitHub if you find migration bugs

---

**Take your time with migrations.** It's better to be safe and thorough than fast and broken!