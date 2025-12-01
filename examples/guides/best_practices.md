# 🏗️ Production Best Practices

Comprehensive guide for deploying Yggdrasil AI agents in production environments.

## Quick Reference

**Planning production deployment?** Review these critical areas:
- [Security](#security) - Authentication, authorization, data protection
- [Performance](#performance) - Scaling, caching, monitoring
- [Reliability](#reliability) - Error handling, fallbacks, testing
- [Operations](#operations) - Monitoring, logging, deployment

## Architecture Patterns

### Stateless Agents (Recommended)

```elixir
# ✅ Good: Stateless, easy to scale
def handle_request(request) do
  agent = Yggdrasil.new(model, instructions: get_instructions())

  Yggdrasil.run(agent, request.prompt,
    message_history: request.history,
    deps: %{
      user_id: request.user_id,
      database: MyApp.Repo,
      permissions: request.user.permissions
    }
  )
end
```

### GenServer Agents (For Persistent State)

```elixir
# ✅ Good: When you need persistent conversation state
defmodule MyApp.AgentServer do
  use GenServer

  # See distributed_agent_example.ex for complete implementation
  def handle_call({:chat, message}, _from, state) do
    case Yggdrasil.run(state.agent, message,
           message_history: state.conversation_history) do
      {:ok, result} ->
        new_state = update_conversation_state(state, result)
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
```

### Distributed Agents

```elixir
# ✅ Production pattern: Registry-based distribution
{:ok, agent_pid} = MyApp.AgentSupervisor.start_child(
  MyApp.DistributedAgent,
  name: {:via, Registry, {MyApp.AgentRegistry, "user:#{user_id}"}},
  model: "anthropic:claude-sonnet-4-5-20250929",
  owner_pid: self()
)
```

## Security

### Authentication & Authorization

```elixir
defmodule MyApp.Security do
  def authenticate_request(conn) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, user} <- verify_jwt_token(token),
         :ok <- check_user_active(user) do
      {:ok, user}
    else
      error -> {:error, :unauthorized}
    end
  end

  def authorize_agent_access(user, agent_id) do
    cond do
      user.role == :admin -> :ok
      agent_belongs_to_user?(agent_id, user.id) -> :ok
      user_has_shared_access?(user.id, agent_id) -> :ok
      true -> {:error, :forbidden}
    end
  end
end

# Usage in Phoenix controller
def chat(conn, %{"message" => message, "agent_id" => agent_id}) do
  with {:ok, user} <- MyApp.Security.authenticate_request(conn),
       :ok <- MyApp.Security.authorize_agent_access(user, agent_id) do
    # Proceed with agent interaction
    handle_chat_request(user, agent_id, message)
  else
    {:error, :unauthorized} ->
      conn |> put_status(401) |> json(%{error: "Authentication required"})
    {:error, :forbidden} ->
      conn |> put_status(403) |> json(%{error: "Access denied"})
  end
end
```

### Data Protection

```elixir
defmodule MyApp.DataProtection do
  @doc """
  Sanitize sensitive data before sending to AI providers
  """
  def sanitize_for_ai(content) do
    content
    |> redact_emails()
    |> redact_phone_numbers()
    |> redact_credit_cards()
    |> redact_api_keys()
  end

  defp redact_emails(content) do
    Regex.replace(~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/,
                  content, "[EMAIL_REDACTED]")
  end

  defp redact_api_keys(content) do
    # Redact common API key patterns
    content
    |> String.replace(~r/sk-[a-zA-Z0-9]{32,}/, "[API_KEY_REDACTED]")
    |> String.replace(~r/Bearer [a-zA-Z0-9_-]+/, "Bearer [TOKEN_REDACTED]")
  end

  @doc """
  Encrypt conversation history before storage
  """
  def encrypt_conversation(conversation_data) do
    key = get_encryption_key()
    :crypto.crypto_one_time(:aes_256_gcm, key, generate_iv(),
                           Jason.encode!(conversation_data), true)
  end
end
```

### Environment Security

```elixir
# config/runtime.exs
import Config

# Never commit API keys to version control
config :myapp, :ai_providers,
  anthropic_api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
  openai_api_key: System.fetch_env!("OPENAI_API_KEY"),
  gemini_api_key: System.get_env("GEMINI_API_KEY")

# Validate critical environment variables
if config_env() == :prod do
  unless System.get_env("DATABASE_URL") do
    raise "DATABASE_URL environment variable is not set"
  end
end
```

## Performance

### Connection Pooling

```elixir
# config/config.exs
config :myapp, :http_client,
  pools: %{
    anthropic: [
      size: 20,
      max_overflow: 10,
      timeout: 30_000
    ],
    openai: [
      size: 15,
      max_overflow: 5,
      timeout: 30_000
    ]
  }

# HTTP client wrapper
defmodule MyApp.HTTPClient do
  def post(provider, url, body, headers) do
    pool_name = String.to_atom("#{provider}_pool")

    HTTPoison.post(url, body, headers, [
      hackney: [pool: pool_name],
      timeout: 30_000,
      recv_timeout: 30_000
    ])
  end
end
```

### Response Caching

```elixir
defmodule MyApp.AgentCache do
  @cache_ttl 300_000  # 5 minutes

  def cached_response(cache_key, fun) do
    case Cachex.get(:agent_cache, cache_key) do
      {:ok, cached_result} ->
        cached_result

      {:ok, nil} ->
        result = fun.()
        Cachex.put(:agent_cache, cache_key, result, ttl: @cache_ttl)
        result
    end
  end

  def generate_cache_key(prompt, model, context_hash) do
    :crypto.hash(:sha256, "#{prompt}:#{model}:#{context_hash}")
    |> Base.encode64(padding: false)
  end
end
```

### Background Processing

```elixir
defmodule MyApp.AgentWorker do
  use Oban.Worker, queue: :ai_agents, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "prompt" => prompt}}) do
    agent = create_agent_for_user(user_id)

    case Yggdrasil.run(agent, prompt) do
      {:ok, result} ->
        MyApp.Notifications.send_result(user_id, result)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Schedule background processing
  def schedule_agent_task(user_id, prompt) do
    %{user_id: user_id, prompt: prompt}
    |> MyApp.AgentWorker.new()
    |> Oban.insert()
  end
end
```

### Resource Limits

```elixir
defmodule MyApp.ResourceLimiter do
  def enforce_limits(user, request) do
    with :ok <- check_token_limit(user, request),
         :ok <- check_rate_limit(user),
         :ok <- check_concurrent_requests(user) do
      :ok
    else
      error -> error
    end
  end

  defp check_token_limit(user, request) do
    daily_limit = get_user_token_limit(user)
    daily_usage = get_daily_token_usage(user.id)
    estimated_tokens = estimate_request_tokens(request)

    if daily_usage + estimated_tokens <= daily_limit do
      :ok
    else
      {:error, :token_limit_exceeded}
    end
  end

  defp check_concurrent_requests(user) do
    current_requests = count_user_requests(user.id)
    max_concurrent = get_user_concurrent_limit(user)

    if current_requests < max_concurrent do
      :ok
    else
      {:error, :too_many_concurrent_requests}
    end
  end
end
```

## Reliability

### Circuit Breaker Pattern

```elixir
defmodule MyApp.CircuitBreaker do
  use GenServer

  def call(provider, fun) do
    case GenServer.call(__MODULE__, {:check_circuit, provider}) do
      :closed ->
        execute_with_monitoring(provider, fun)

      :open ->
        {:error, :circuit_breaker_open}

      :half_open ->
        # Try one request to test if service recovered
        case execute_with_monitoring(provider, fun) do
          {:ok, result} ->
            GenServer.cast(__MODULE__, {:success, provider})
            {:ok, result}

          {:error, _} = error ->
            GenServer.cast(__MODULE__, {:failure, provider})
            error
        end
    end
  end

  defp execute_with_monitoring(provider, fun) do
    case fun.() do
      {:ok, result} ->
        GenServer.cast(__MODULE__, {:success, provider})
        {:ok, result}

      {:error, _} = error ->
        GenServer.cast(__MODULE__, {:failure, provider})
        error
    end
  end
end
```

### Fallback Strategies

```elixir
defmodule MyApp.FallbackAgent do
  @providers [
    %{name: :primary, model: "anthropic:claude-sonnet-4-5-20250929", priority: 1},
    %{name: :secondary, model: "openai:gpt-4", priority: 2},
    %{name: :local, model: "lmstudio:qwen/qwen3-30b", priority: 3}
  ]

  def run_with_fallback(prompt, context) do
    @providers
    |> Enum.sort_by(& &1.priority)
    |> attempt_providers(prompt, context)
  end

  defp attempt_providers([provider | remaining], prompt, context) do
    agent = Yggdrasil.new(provider.model)

    case Yggdrasil.run(agent, prompt, context) do
      {:ok, result} ->
        Logger.info("Request succeeded with #{provider.name}")
        {:ok, result}

      {:error, reason} ->
        Logger.warning("Provider #{provider.name} failed: #{inspect(reason)}")

        case remaining do
          [] -> {:error, :all_providers_failed}
          _ -> attempt_providers(remaining, prompt, context)
        end
    end
  end
end
```

### Health Monitoring

```elixir
defmodule MyApp.HealthCheck do
  def system_health do
    checks = [
      database: check_database(),
      ai_providers: check_ai_providers(),
      cache: check_cache(),
      external_apis: check_external_apis()
    ]

    overall_status = if Enum.all?(checks, fn {_, status} -> status == :healthy end) do
      :healthy
    else
      :degraded
    end

    %{
      status: overall_status,
      checks: checks,
      timestamp: DateTime.utc_now(),
      version: MyApp.version()
    }
  end

  defp check_ai_providers do
    providers = [:anthropic, :openai, :local]

    provider_statuses = Enum.map(providers, fn provider ->
      case test_provider(provider) do
        :ok -> {provider, :healthy}
        {:error, _} -> {provider, :unhealthy}
      end
    end)

    if Enum.any?(provider_statuses, fn {_, status} -> status == :healthy end) do
      :healthy
    else
      :unhealthy
    end
  end
end
```

## Operations

### Structured Logging

```elixir
defmodule MyApp.AgentLogger do
  require Logger

  def log_agent_request(user_id, prompt, metadata \\ %{}) do
    Logger.info("Agent request initiated",
      user_id: user_id,
      prompt_length: String.length(prompt),
      metadata: metadata,
      timestamp: DateTime.utc_now()
    )
  end

  def log_agent_response(user_id, result, duration_ms) do
    Logger.info("Agent response completed",
      user_id: user_id,
      tokens_used: result.usage.total_tokens,
      tool_calls: result.usage.tool_calls,
      duration_ms: duration_ms,
      success: true
    )
  end

  def log_agent_error(user_id, error, duration_ms) do
    Logger.error("Agent request failed",
      user_id: user_id,
      error: inspect(error),
      duration_ms: duration_ms,
      success: false
    )
  end
end
```

### Telemetry Integration

```elixir
defmodule MyApp.Telemetry do
  def setup do
    :telemetry.attach_many(
      "myapp-telemetry",
      [
        [:yggdrasil, :agent, :run, :start],
        [:yggdrasil, :agent, :run, :stop],
        [:yggdrasil, :tool, :execute, :start],
        [:yggdrasil, :tool, :execute, :stop]
      ],
      &handle_event/4,
      []
    )
  end

  def handle_event([:yggdrasil, :agent, :run, :stop], measurements, metadata, _config) do
    # Send metrics to monitoring system
    :telemetry_metrics.counter([{:yggdrasil, :requests}, {:status, metadata.status}])
    :telemetry_metrics.distribution([{:yggdrasil, :duration}], measurements.duration)
    :telemetry_metrics.distribution([{:yggdrasil, :tokens}], metadata.tokens_used)
  end

  def handle_event([:yggdrasil, :tool, :execute, :stop], measurements, metadata, _config) do
    :telemetry_metrics.counter([{:yggdrasil, :tool_calls}, {:tool, metadata.tool_name}])
    :telemetry_metrics.distribution([{:yggdrasil, :tool_duration}], measurements.duration)
  end
end
```

### Deployment Configuration

```elixir
# rel/env.sh.eex
#!/bin/bash

# Production environment variables
export PHX_SERVER=true
export PORT=4000

# Database configuration
export DATABASE_URL="postgresql://user:pass@db:5432/myapp_prod"
export POOL_SIZE=20

# AI Provider Keys
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
export OPENAI_API_KEY="${OPENAI_API_KEY:?OPENAI_API_KEY is required}"

# Redis for caching
export REDIS_URL="redis://redis:6379/0"

# Monitoring
export HONEYBADGER_API_KEY="${HONEYBADGER_API_KEY}"
export NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY}"

# Security
export SECRET_KEY_BASE="${SECRET_KEY_BASE:?SECRET_KEY_BASE is required}"
export ENCRYPTION_SALT="${ENCRYPTION_SALT:?ENCRYPTION_SALT is required}"
```

### Docker Configuration

```dockerfile
# Dockerfile
FROM elixir:1.17-alpine AS builder

# Install build dependencies
RUN apk add --no-cache git build-base

WORKDIR /app

# Install Elixir dependencies
COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod

# Compile application
COPY . .
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release

# Runtime image
FROM alpine:3.18

RUN apk add --no-cache openssl ncurses-libs

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/myapp ./

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD /app/bin/myapp rpc "MyApp.HealthCheck.system_health().status == :healthy"

EXPOSE 4000

CMD ["/app/bin/myapp", "start"]
```

### Kubernetes Configuration

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp-agents
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp-agents
  template:
    metadata:
      labels:
        app: myapp-agents
    spec:
      containers:
      - name: myapp
        image: myapp:latest
        ports:
        - containerPort: 4000
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: myapp-secrets
              key: database-url
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: ai-provider-keys
              key: anthropic-key
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /ready
            port: 4000
          initialDelaySeconds: 10
          periodSeconds: 5
```

## Monitoring & Alerting

### Key Metrics to Track

```elixir
defmodule MyApp.Metrics do
  @metrics [
    # Performance metrics
    counter("agent.requests.total", tags: [:status, :provider]),
    distribution("agent.duration", unit: :millisecond, tags: [:provider]),
    distribution("agent.tokens", tags: [:provider, :type]),

    # Error metrics
    counter("agent.errors.total", tags: [:error_type, :provider]),
    counter("tool.failures.total", tags: [:tool_name]),

    # Business metrics
    counter("users.active", tags: [:tier]),
    distribution("cost.per_request", unit: :dollar, tags: [:provider])
  ]

  def setup_dashboard do
    # Configure Grafana/Prometheus dashboards
    # Set up alerts for:
    # - Error rate > 5%
    # - Response time > 10s
    # - Token costs > budget
    # - Provider downtime
  end
end
```

### Error Tracking

```elixir
defmodule MyApp.ErrorTracker do
  def report_agent_error(error, context) do
    Honeybadger.notify(error,
      context: %{
        user_id: context[:user_id],
        model: context[:model],
        prompt_length: context[:prompt_length],
        conversation_length: length(context[:history] || [])
      },
      fingerprint: generate_error_fingerprint(error)
    )
  end

  defp generate_error_fingerprint(%{reason: reason, provider: provider}) do
    "#{provider}_#{inspect(reason)}"
  end
end
```

## Testing Strategies

### Integration Testing

```elixir
defmodule MyApp.AgentIntegrationTest do
  use ExUnit.Case, async: false
  use Mimic

  setup do
    # Mock external services
    Mimic.stub_with(HTTPoison, MockHTTPClient)
    :ok
  end

  test "handles complete user workflow" do
    user = create_test_user()

    # Test agent creation
    {:ok, agent_pid} = MyApp.AgentManager.create_agent(user.id)

    # Test conversation
    {:ok, response} = MyApp.AgentManager.chat(agent_pid, "Hello!")
    assert String.contains?(response.output, "hello")

    # Test tool usage
    {:ok, response} = MyApp.AgentManager.chat(agent_pid, "What's the weather?")
    assert response.usage.tool_calls > 0

    # Test error handling
    Mimic.expect(HTTPoison, :get, fn _ -> {:error, :timeout} end)
    {:ok, response} = MyApp.AgentManager.chat(agent_pid, "Search for news")
    assert String.contains?(response.output, "temporarily unavailable")
  end
end
```

### Load Testing

```elixir
defmodule MyApp.LoadTest do
  def run_load_test(concurrent_users \\ 10, duration_seconds \\ 60) do
    test_scenarios = [
      %{weight: 50, scenario: :simple_chat},
      %{weight: 30, scenario: :tool_usage},
      %{weight: 20, scenario: :long_conversation}
    ]

    tasks = for i <- 1..concurrent_users do
      Task.async(fn ->
        run_user_simulation(i, test_scenarios, duration_seconds)
      end)
    end

    results = Task.await_many(tasks, duration_seconds * 1000 + 5000)
    analyze_load_test_results(results)
  end

  defp run_user_simulation(user_id, scenarios, duration) do
    end_time = System.monotonic_time(:second) + duration
    simulate_user_activity(user_id, scenarios, end_time, [])
  end
end
```

## Deployment Checklist

### Pre-Production

- [ ] Security audit completed
- [ ] Load testing passed
- [ ] Error handling tested
- [ ] Monitoring configured
- [ ] Backup strategy in place
- [ ] Rollback plan prepared

### Go-Live

- [ ] Environment variables configured
- [ ] Database migrations applied
- [ ] Cache warmed up
- [ ] Health checks passing
- [ ] Monitoring alerts active

### Post-Deployment

- [ ] Monitor error rates
- [ ] Check performance metrics
- [ ] Verify AI provider quotas
- [ ] Review cost tracking
- [ ] User feedback collection

## Common Anti-Patterns

### ❌ Don't Do This

```elixir
# Storing API keys in code
def create_agent do
  Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
    api_key: "sk-ant-hardcoded-key"  # NEVER DO THIS
  )
end

# Blocking the main process
def handle_chat(message) do
  # This will block for 30+ seconds
  Yggdrasil.run(agent, message)
end

# No error handling
def unreliable_tool(_ctx, args) do
  HTTPoison.get!(args["url"]).body  # Will crash on any error
end

# Exposing internal errors
def leaky_tool(_ctx, _args) do
  raise "Database connection failed: user=admin, password=secret123"
end
```

### ✅ Do This Instead

```elixir
# Environment-based configuration
def create_agent do
  api_key = System.get_env("ANTHROPIC_API_KEY")
  Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929", api_key: api_key)
end

# Async processing
def handle_chat(message) do
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    result = Yggdrasil.run(agent, message)
    send_result_to_user(result)
  end)
end

# Robust error handling
def reliable_tool(_ctx, %{"url" => url}) do
  case HTTPoison.get(url) do
    {:ok, %{status_code: 200, body: body}} -> body
    {:ok, %{status_code: status}} -> {:error, "HTTP #{status}"}
    {:error, reason} -> {:error, "Request failed"}
  end
end

# Safe error messages
def safe_tool(_ctx, _args) do
  try do
    perform_operation()
  rescue
    _error ->
      Logger.error("Tool operation failed")
      {:error, "Operation temporarily unavailable"}
  end
end
```

## Next Steps

1. **Review examples**: Study production patterns in [trading_desk/](../trading_desk/)
2. **Set up monitoring**: Implement telemetry and health checks
3. **Test thoroughly**: Load test, security test, chaos engineering
4. **Start small**: Deploy to staging environment first
5. **Monitor closely**: Watch metrics for first week after deployment

---

**Production success requires planning, testing, and continuous monitoring.** Start with these patterns and adapt them to your specific requirements.