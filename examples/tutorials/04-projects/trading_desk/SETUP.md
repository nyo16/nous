# Trading Desk - Setup & Usage Guide

## 🚀 Quick Start

```bash
# From project root
mix run examples/trading_desk/demo.exs
```

That's it! The demo will:
1. Start the trading desk supervisor
2. Initialize 4 specialist agents + coordinator
3. Run 5 trading scenarios
4. Show multi-agent coordination in action

## 📋 What Gets Created

### Supervisor Tree

```
TradingDesk.Supervisor
├── Registry (TradingDesk.Registry)
├── Coordinator (routes queries)
├── Market Analyst (technical analysis)
├── Risk Manager (risk assessment)
├── Trading Executor (order execution)
└── Research Analyst (fundamental analysis)
```

### Process Names (via Registry)

Each agent gets a unique name:
- `:coordinator` - The orchestrator
- `:market_analyst` - Market data specialist
- `:risk_manager` - Risk assessment specialist
- `:trading_executor` - Trading specialist
- `:research_analyst` - Research specialist

## 🎯 How the Coordinator Works

### Routing Logic (Keyword-Based)

The coordinator analyzes queries using simple keyword matching:

```elixir
query = "What's the price and risk of AAPL?"

# Step 1: Extract keywords
# - "price" → matches Market Analyst
# - "risk" → matches Risk Manager

# Step 2: Score each agent
scores = [
  {:market_analyst, 1},  # matched "price"
  {:risk_manager, 1}     # matched "risk"
]

# Step 3: Route to both agents in parallel

# Step 4: Synthesize responses
```

### Agent Selection Keywords

**Market Analyst** responds to:
- price, chart, trend, technical, indicator
- sentiment, volume, moving average

**Risk Manager** responds to:
- risk, stop loss, take profit, exposure
- var, position size, risk management

**Trading Executor** responds to:
- buy, sell, execute, order, balance
- position, portfolio, account

**Research Analyst** responds to:
- company, earnings, fundamental, news
- research, valuation, financial

## 💡 Usage Examples

### Example 1: Simple Query (Auto-Routed)

```elixir
# Start trading desk
{:ok, _} = TradingDesk.start()

# Ask a question - coordinator routes automatically
{:ok, result} = TradingDesk.query("What's the price of AAPL?")

# Behind the scenes:
# 1. Coordinator detects "price" keyword
# 2. Routes to Market Analyst
# 3. Market Analyst calls get_market_data("AAPL")
# 4. Returns analysis

IO.puts(result.synthesized_response)
```

### Example 2: Multi-Agent Query

```elixir
{:ok, result} = TradingDesk.query(
  "Should I buy TSLA? What's the risk?"
)

# Coordinator routes to BOTH:
# - Market Analyst (for price/trend analysis)
# - Risk Manager (for risk assessment)
# Runs in parallel, then synthesizes responses

IO.puts(result.synthesized_response)
# Shows combined insights from both specialists!
```

### Example 3: Direct Agent Access

```elixir
# Skip coordinator, go straight to an agent
{:ok, result} = TradingDesk.ask_agent(
  :risk_manager,
  "Calculate position size for $100k capital, 2% risk"
)

IO.puts(result.output)
```

### Example 4: Structured Workflow

```elixir
# Pre-defined workflow consulting multiple agents
{:ok, analysis} = TradingDesk.analyze_trade(
  symbol: "NVDA",
  quantity: 50,
  entry_price: 495.20
)

# Automatically queries:
# - Market Analyst → technical analysis
# - Risk Manager → risk assessment
# - Research Analyst → fundamental analysis
# All in parallel!

IO.inspect(analysis.analyses)
```

## 🔧 Agent Setup Details

### How Each Agent is Created

```elixir
# 1. Define agent specification
spec = %{
  id: :market_analyst,
  name: "Market Analyst",
  description: "Analyzes market data, trends, indicators...",
  model: "anthropic:claude-sonnet-4-5-20250929",
  instructions: "You are an expert market analyst...",
  tools: [&get_market_data/2, &get_price_history/2, ...]
}

# 2. Agent starts in GenServer
def init(agent_spec) do
  # Create Nous agent
  agent = Nous.Agent.new(agent_spec.model,
    instructions: agent_spec.instructions,
    tools: agent_spec.tools
  )

  # Store in state
  {:ok, %{agent: agent, history: [], ...}}
end

# 3. Register with unique name
name = {:via, Registry, {TradingDesk.Registry, agent_spec.id}}
GenServer.start_link(AgentServer, spec, name: name)
```

### How Coordinator Routes

```elixir
def process_query(query) do
  # 1. Determine which agents to consult
  agents = Router.route_query(query)
  # Returns: [{:market_analyst, "Market Analyst", 2}, ...]

  # 2. Query each agent in parallel
  tasks = Enum.map(agents, fn {id, name, _score} ->
    Task.async(fn ->
      AgentServer.query(id, query)
    end)
  end)

  # 3. Wait for all responses
  responses = Task.await_many(tasks, 90_000)

  # 4. Synthesize into final answer
  synthesize_responses(query, responses)
end
```

## 📊 What You'll See in Demo

### Scenario 1: Market Query
```
Query: "What's the price and trend for AAPL?"
→ Routed to: Market Analyst
→ Tools called: 3 (market_data, price_history, technical_indicators)
→ Response: Comprehensive market analysis
```

### Scenario 2: Risk Query
```
Query: "What's my portfolio risk?"
→ Routed to: Risk Manager + Trading Executor
→ Both agents run in parallel
→ Response: Combined risk assessment and portfolio status
```

### Scenario 3: Complex Query
```
Query: "Should I buy TSLA?"
→ Routed to: Multiple agents (market + risk + maybe research)
→ All run in parallel
→ Response: Synthesized recommendation from all specialists
```

## 🎓 Architecture Highlights

### 1. **OTP Supervision**
```elixir
Supervisor
├── Registry (for agent names)
├── Coordinator (GenServer)
├── Market Analyst (GenServer)
├── Risk Manager (GenServer)
├── Trading Executor (GenServer)
└── Research Analyst (GenServer)
```

If one agent crashes, others keep running! ✅

### 2. **Parallel Execution**
```elixir
# Agents run simultaneously
Task.async(fn -> query(:market_analyst, q) end)
Task.async(fn -> query(:risk_manager, q) end)
Task.await_many(tasks)  # Wait for all
```

### 3. **Conversation History**
Each agent maintains its own conversation history:
```elixir
# Agent remembers previous interactions
{:ok, r1} = ask_agent(:market_analyst, "Analyze AAPL")
{:ok, r2} = ask_agent(:market_analyst, "What changed?")
# Agent remembers the AAPL context!
```

### 4. **Process Isolation**
Each agent is independent:
- Separate process
- Own conversation history
- Own tool set
- Can't interfere with others

## 🔮 Future Enhancements

### Replace Keyword Matching with Embeddings

```elixir
# Current: keyword matching
route_query("What's the risk?")
# Matches "risk" keyword → Risk Manager

# Future: semantic similarity
route_query_embeddings("What's the risk?")
# 1. Get embedding for query
# 2. Compare with agent description embeddings
# 3. Use cosine similarity
# 4. Select top N agents
# More accurate routing!
```

### Agent-to-Agent Communication

```elixir
# Risk Manager asks Market Analyst for price
defmodule RiskTools do
  def assess_risk(ctx, %{"symbol" => symbol}) do
    # Ask Market Analyst for current price
    {:ok, price_data} = TradingDesk.ask_agent(
      :market_analyst,
      "Get #{symbol} price"
    )

    # Use in risk calculation
    calculate_risk(price_data)
  end
end
```

## ✅ Success Criteria

You know it's working when you see:

```bash
✅ Trading Desk Online!
   - Market Analyst: 4 tools, claude-sonnet-4-5-20250929
   - Risk Manager: 5 tools, claude-sonnet-4-5-20250929
   - Trading Executor: 5 tools, qwen/qwen3-30b-a3b-2507
   - Research Analyst: 4 tools, claude-sonnet-4-5-20250929
```

And agents successfully answer queries with tool calls!

## 🐛 Troubleshooting

### No ANTHROPIC_API_KEY
Some agents use Claude - set your key:
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### Trading Executor Fails
Uses LM Studio by default - make sure it's running:
```bash
# Or change in agent_specs.ex to use Claude
model: "anthropic:claude-sonnet-4-5-20250929"
```

## 📖 Code Organization

```
trading_desk/
├── trading_desk.ex       # Public API
├── supervisor.ex         # Supervision tree
├── coordinator.ex        # Orchestration
├── agent_server.ex       # Agent GenServer wrapper
├── agent_specs.ex        # Agent definitions
├── router.ex             # Routing logic
├── tools/                # All mock tools
│   ├── market_tools.ex
│   ├── risk_tools.ex
│   ├── trading_tools.ex
│   └── research_tools.ex
├── demo.exs              # Runnable demo
├── README.md             # Overview
└── SETUP.md              # This file
```

---

**The trading desk demonstrates production-ready multi-agent architecture!** 🏦
