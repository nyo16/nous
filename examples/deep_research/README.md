# Deep Research Multi-Agent System

A production-grade deep research system featuring 6 specialized AI agents, DAG-based orchestration, and comprehensive source tracking.

## Features

- **6 Specialized Agents** with distinct personas
- **DAG-Based Orchestration** using [libgraph](https://github.com/bitwalker/libgraph)
- **Parallel Execution** for independent research tasks
- **Iterative Refinement** with knowledge gap detection
- **Source Tracking** with citations
- **Comprehensive Reports** in markdown format

## Architecture

```
                    ┌─────────────────┐
                    │   Orchestrator  │
                    │   (Supervisor)  │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐   ┌──────────┐   ┌──────────┐
        │ Planner  │   │ Analyst  │   │ Critic   │
        └────┬─────┘   └────┬─────┘   └────┬─────┘
             │              │              │
             ▼              ▼              ▼
        ┌──────────┐   ┌──────────┐   ┌──────────┐
        │Researcher│   │Researcher│   │ Reviewer │
        └────┬─────┘   └────┬─────┘   └────┬─────┘
             │              │              │
             └──────────────┼──────────────┘
                            ▼
                    ┌──────────────┐
                    │    Writer    │
                    └──────────────┘
```

## Quick Start

```bash
# Set your API key
export ANTHROPIC_API_KEY="your-key"
# Or for OpenAI
export OPENAI_API_KEY="your-key"
# Or run LM Studio locally (no key needed)

# Optional: Enable real web search
export BRAVE_API_KEY="your-brave-key"

# Run the demo
cd examples/deep_research
elixir demo.exs

# Or with a custom question
elixir demo.exs "What are the implications of quantum computing?"
```

## Usage

### Basic Research

```elixir
{:ok, result} = DeepResearch.research("Your research question")

IO.puts(result.report)
IO.inspect(result.stats)
```

### With Progress Callback

```elixir
DeepResearch.research("Your question",
  callback: fn
    {:phase, phase} -> IO.puts("Phase: #{phase}")
    {:researching, node, sq} -> IO.puts("Researching: #{sq}")
    {:complete, stats} -> IO.puts("Done! #{stats.total_findings} findings")
    _ -> :ok
  end
)
```

### With Logging

```elixir
# Built-in progress logging
DeepResearch.research_with_logging("Your question")
```

### Quick Search (No Full Workflow)

```elixir
{:ok, result} = DeepResearch.quick_search("specific topic")
```

## Agent Personas

| Agent | Persona | Role |
|-------|---------|------|
| **Planner** | The Strategist | Decomposes questions into sub-questions |
| **Researcher** | The Scout | Iterative search, query refinement |
| **Analyst** | The Synthesizer | Pattern identification, synthesis |
| **Critic** | The Skeptic | Gap detection, quality assessment |
| **Reviewer** | The Validator | Verification, confidence scoring |
| **Writer** | The Narrator | Report generation with citations |

## Research Workflow

1. **Planning** - Planner decomposes the question into 3-5 sub-questions
2. **DAG Construction** - Research graph built with dependencies
3. **Parallel Research** - Researchers execute in parallel where possible
4. **Analysis** - Analyst synthesizes findings per sub-question
5. **Critique Loop** - Critic identifies gaps, may trigger more research
6. **Verification** - Reviewer verifies claims and assigns confidence
7. **Report Generation** - Writer creates final report with citations

## DAG Execution

Research tasks are organized as a directed acyclic graph (DAG):

```
[plan:root]
    │
    ├──[research:sq1]──[analyze:sq1]──┐
    │                                 │
    ├──[research:sq2]──[analyze:sq2]──┼──[critique:coverage]
    │                                 │         │
    └──[research:sq3]──[analyze:sq3]──┘         │
                                          [review:verify]
                                                │
                                          [write:report]
```

- Research nodes for different sub-questions run **in parallel**
- Dependencies ensure proper ordering
- Critic may dynamically add new research nodes

## File Structure

```
deep_research/
├── demo.exs                  # Interactive demo
├── deep_research.ex          # Main public API
├── orchestrator.ex           # DAG execution coordinator
├── research_graph.ex         # libgraph-based DAG
├── research_state.ex         # Shared state management
├── agents/
│   ├── planner_agent.ex      # Question decomposition
│   ├── researcher_agent.ex   # Web/academic search
│   ├── analyst_agent.ex      # Pattern synthesis
│   ├── critic_agent.ex       # Gap detection
│   ├── reviewer_agent.ex     # Verification
│   └── writer_agent.ex       # Report generation
└── tools/
    ├── search_tools.ex       # Web, news, Wikipedia, academic
    ├── content_tools.ex      # URL fetching
    ├── analysis_tools.ex     # Pattern analysis
    └── memory_tools.ex       # Findings & sources
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ANTHROPIC_API_KEY` | Claude API key | - |
| `OPENAI_API_KEY` | OpenAI API key | - |
| `BRAVE_API_KEY` | Brave Search API key | Mock results |
| `DEEP_RESEARCH_MODEL` | Override model selection | Auto-detect |

### Model Selection

The system auto-selects models in this order:
1. `DEEP_RESEARCH_MODEL` env var (if set)
2. Anthropic Claude (if `ANTHROPIC_API_KEY` set)
3. OpenAI GPT-4 (if `OPENAI_API_KEY` set)
4. LM Studio local (default fallback)

## Search Tools

| Tool | Source | API Key Required |
|------|--------|-----------------|
| `web_search` | Brave Search | Optional (mock fallback) |
| `news_search` | Brave Search | Optional (mock fallback) |
| `wikipedia_search` | Wikipedia API | No |
| `academic_search` | Mock data | No (integrate your own) |

## Extending

### Custom Search Tools

```elixir
def my_custom_search(ctx, args) do
  query = Map.get(args, "query")
  # Your search logic
  %{
    success: true,
    query: query,
    results: [...],
    source: "my_source"
  }
end
```

### Custom Agent

```elixir
defmodule MyAgent do
  def new(opts \\ []) do
    Nous.Agent.new(model,
      instructions: "Your persona...",
      tools: [&my_tool/2]
    )
  end
end
```

## Inspired By

- [OpenAI Deep Research](https://cookbook.openai.com/examples/deep_research_api/introduction_to_deep_research_api_agents)
- [LangChain Open Deep Research](https://github.com/langchain-ai/open_deep_research)
- [GPT-Researcher](https://github.com/assafelovic/gpt-researcher)
- [Khoj AI](https://github.com/khoj-ai/khoj)

## License

Apache 2.0 - See the main Nous repository LICENSE file.
