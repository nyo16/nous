# 📚 Nous AI Guides

Comprehensive guides for building production-ready AI agents with Nous. Grouped
the same way as the [HexDocs sidebar](https://hexdocs.pm/nous).

## Core

- **[Getting Started](../getting-started.md)** — install, first agent, tools, streaming, persistence.
- **[Context & Dependencies](context.md)** — passing `deps` to tools/prompts and the run context.
- **[Tool Development](tool_development.md)** — building robust, validated, secure tools.
- **[Structured Output](structured_output.md)** — typed/validated results via Ecto schemas, schemaless types, or raw JSON schema.
- **[Skills](skills.md)** — reusable instruction/capability packages (module- and file-based) and the built-in catalog.
- **[Hooks](hooks.md)** — lifecycle interceptors to block, modify, or audit agent actions.
- **[Memory](memory.md)** — persistent, searchable agent memory (keyword + vector, decay, scoping).
- **[Knowledge Base](knowledge_base.md)** — structured, linkable knowledge store and tools.
- **[Evaluation](evaluation.md)** — test suites, evaluators, metrics, and the optimizer.
- **[Permissions & Guardrails](permissions.md)** — tool permission policies, approval gates, and session guardrails.
- **[Observability & Telemetry](observability.md)** — telemetry events, default handler, and Prometheus via PromEx.

## Orchestration & Multi-Agent

- **[Multi-Agent Teams](teams.md)** — supervised agent groups, roles, shared state, comms, and rate limiting.
- **[Decision Graph](decisions.md)** — track goals, decisions, and outcomes as a graph.
- **[Deep Research](research.md)** — autonomous multi-step research with citations (`Nous.Research.run/2`).
- **[Workflow Engine](workflows.md)** — DAG/graph-based orchestration of agents, tools, and control flow.

## Providers & Backends

- **[Providers Overview](providers.md)** — all 13 providers + `custom:`, and how to switch with one string.
- **[Custom Providers](custom_providers.md)** — the `custom:` OpenAI-compatible prefix.
- **[HTTP Backends](http_backends.md)** — Finch/Req vs Hackney, streaming backpressure.
- **[Vertex AI Setup](vertex_ai_setup.md)** — Google Cloud Vertex AI configuration.
- **[Fallback Chains](fallback.md)** — automatic provider/model failover.

## Integrations & Operations

- **[Phoenix LiveView Integration](liveview-integration.md)** — real-time streaming, multi-user coordination, production patterns.
- **[Production Best Practices](best_practices.md)** — architecture, security, scaling, monitoring.
- **[Troubleshooting](troubleshooting.md)** — common development and deployment issues.
- **[Migration Guide](migration_guide.md)** — version upgrades and breaking changes.

---

## Suggested reading order

**New to Nous:**
1. [Getting Started](../getting-started.md) → 2. [Tool Development](tool_development.md) →
3. [Structured Output](structured_output.md) → 4. [Skills](skills.md) → 5. [Best Practices](best_practices.md)

**Building something specific:**
- Real-time chat → [LiveView Integration](liveview-integration.md)
- Multiple agents → [Teams](teams.md) / [Workflows](workflows.md)
- Research assistant → [Deep Research](research.md)
- Production hardening → [Permissions & Guardrails](permissions.md) + [Observability](observability.md)

**Having issues?** → [Troubleshooting](troubleshooting.md).

---

**Need hands-on code?** See the [examples directory](../../examples/README.md) and the
full [API reference on HexDocs](https://hexdocs.pm/nous).
