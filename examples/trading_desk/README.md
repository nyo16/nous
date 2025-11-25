

# 🏦 Trading Desk - Multi-Agent AI System

A sophisticated example demonstrating **an army of AI agents** working together to analyze trading decisions.

## 🎯 Architecture

```
                    ┌─────────────────────┐
                    │   User Query        │
                    └──────────┬──────────┘
                               ▼
                    ┌─────────────────────┐
                    │  Coordinator        │
                    │  (Routes queries)   │
                    └──────────┬──────────┘
                               │
          ┌────────────┬───────┴────────┬──────────────┐
          ▼            ▼                ▼              ▼
    ┌──────────┐ ┌──────────┐  ┌───────────┐  ┌──────────────┐
    │ Market   │ │   Risk   │  │ Trading   │  │  Research    │
    │ Analyst  │ │ Manager  │  │ Executor  │  │  Analyst     │
    └────┬─────┘ └────┬─────┘  └─────┬─────┘  └──────┬───────┘
         │            │              │                │
         └────────────┴──────┬───────┴────────────────┘
                             ▼
                    Synthesized Response
```

## 👥 The Team

### 1. **Market Analyst** 📈
- **Expertise:** Technical analysis, price trends, indicators
- **Tools:** 4 tools
  - `get_market_data` - Current price, volume
  - `get_price_history` - Historical data
  - `get_technical_indicators` - RSI, MACD, moving averages
  - `get_market_sentiment` - Analyst ratings, social sentiment
- **Model:** Claude Sonnet 4.5

### 2. **Risk Manager** ⚠️
- **Expertise:** Risk assessment, position sizing, stop losses
- **Tools:** 5 tools
  - `calculate_position_size` - Proper position sizing
  - `calculate_var` - Value at Risk
  - `check_exposure` - Portfolio concentration
  - `validate_trade` - Compliance checking
  - `calculate_stop_take` - Stop loss & take profit levels
- **Model:** Claude Sonnet 4.5

### 3. **Trading Executor** 💼
- **Expertise:** Order execution, account management
- **Tools:** 5 tools
  - `get_account_balance` - Cash and buying power
  - `get_open_positions` - Current holdings
  - `place_order` - Execute trades
  - `get_pending_orders` - View pending orders
  - `cancel_order` - Cancel orders
- **Model:** LM Studio (fast execution)

### 4. **Research Analyst** 📚
- **Expertise:** Fundamental analysis, company research
- **Tools:** 4 tools
  - `get_company_info` - Fundamentals, P/E, EPS
  - `get_news` - Recent news articles
  - `get_earnings` - Earnings reports
  - `search_research` - Research database
- **Model:** Claude Sonnet 4.5

### 5. **Coordinator** 🎯
- **Expertise:** Query routing and response synthesis
- **Logic:** Keyword-based routing (upgradeable to embeddings)
- **No tools:** Pure orchestration

## 🚀 Quick Start

```bash
# Run the demo
cd examples/trading_desk
elixir demo.exs
```

## 💡 Usage Examples

### Simple Query (Auto-Routed)

```elixir
# Start trading desk
{:ok, _} = TradingDesk.start()

# Ask a question - coordinator routes automatically
{:ok, response} = TradingDesk.query("What's the price of AAPL?")

# Coordinator:
# 1. Analyzes query → detects "price" keyword
# 2. Routes to Market Analyst
# 3. Market Analyst uses get_market_data tool
# 4. Returns synthesized response

IO.puts(response.synthesized_response)
```

### Complex Multi-Agent Query

```elixir
{:ok, response} = TradingDesk.query(
  "Should I buy 100 shares of TSLA? Consider market conditions and risk."
)

# Coordinator routes to MULTIPLE agents:
# 1. Market Analyst → analyzes price, trend, technicals
# 2. Risk Manager → calculates position size, risk level
# 3. Both responses synthesized into final answer

IO.puts(response.synthesized_response)
# Shows insights from both Market Analyst AND Risk Manager!
```

### Direct Agent Access

```elixir
# Query specific agent directly
{:ok, result} = TradingDesk.ask_agent(
  :market_analyst,
  "Analyze NVDA technical indicators"
)

IO.puts(result.output)
```

### Structured Workflow

```elixir
# Pre-defined workflow hitting multiple agents
{:ok, analysis} = TradingDesk.analyze_trade(
  symbol: "AAPL",
  quantity: 100,
  entry_price: 178.50
)

# Automatically queries:
# - Market Analyst
# - Risk Manager
# - Research Analyst
# Returns structured data from all three

IO.inspect(analysis.analyses)
```

## 🎓 How It Works

### Message Routing

The coordinator uses **keyword matching** to route queries:

```elixir
# Query: "What's the price and risk of AAPL?"

# Step 1: Extract keywords
# - "price" → Market Analyst
# - "risk" → Risk Manager

# Step 2: Query both agents in parallel
market_result = AgentServer.query(:market_analyst, query)
risk_result = AgentServer.query(:risk_manager, query)

# Step 3: Synthesize responses
final_response = combine(market_result, risk_result)
```

### Agent Communication Flow

```
User
  │
  ├─ TradingDesk.query("Should I buy AAPL?")
  │
  ▼
Coordinator
  │
  ├─ Router.route_query() → [:market_analyst, :risk_manager]
  │
  ├──┬──▶ Market Analyst
  │  │     └─ get_market_data("AAPL")
  │  │     └─ get_technical_indicators("AAPL")
  │  │     └─ Returns: "AAPL at $178.50, bullish trend..."
  │  │
  │  └──▶ Risk Manager
  │        └─ calculate_position_size(...)
  │        └─ calculate_var(...)
  │        └─ Returns: "2% position, $170 stop loss..."
  │
  ▼
Coordinator synthesizes:
"Based on market analysis showing bullish trend at $178.50
and risk assessment recommending 2% position with $170 stop,
the trade looks favorable..."
```

## 📊 Demo Scenarios

The demo script runs 5 scenarios:

1. **Market Analysis** - "What's the price and trend for AAPL?"
2. **Risk Assessment** - "What's my portfolio exposure?"
3. **Complex Decision** - "Should I buy TSLA?" (multi-agent)
4. **Direct Query** - Ask Risk Manager directly
5. **Structured Workflow** - Analyze NVDA trade with all agents

## 🔧 Tools Available

**Total: 18 tools across 4 domains**

| Domain | Tools | Agent |
|--------|-------|-------|
| Market | 4 | Market Analyst |
| Risk | 5 | Risk Manager |
| Trading | 5 | Trading Executor |
| Research | 4 | Research Analyst |

## 🎯 Key Features Demonstrated

✅ **Multi-Agent Coordination** - Agents work in parallel
✅ **Intelligent Routing** - Queries routed to right specialists
✅ **Tool Calling** - Each agent has domain-specific tools
✅ **Response Synthesis** - Coordinator combines insights
✅ **Process Supervision** - Proper OTP supervision tree
✅ **Named Processes** - Registry-based agent discovery
✅ **Parallel Execution** - Multiple agents queried simultaneously
✅ **Graceful Shutdown** - Proper cleanup on termination

## 🔮 Future Enhancements

### Embeddings-Based Routing

Replace keyword matching with semantic similarity:

```elixir
# Instead of keyword matching:
route_query(query) # Uses string matching

# Use embeddings:
route_query_with_embeddings(query)
  # 1. Get query embedding
  # 2. Compare with agent description embeddings
  # 3. Use cosine similarity
  # 4. Select top N agents
```

### Agent-to-Agent Communication

```elixir
# Risk Manager asks Market Analyst for data
defmodule TradingDesk.MessageBus do
  def send_message(from: :risk_manager, to: :market_analyst, query: "Get AAPL price")
  # Agents can consult each other!
end
```

### Consensus Mechanisms

```elixir
# Get consensus from multiple agents
{:ok, consensus} = TradingDesk.get_consensus(
  query: "Is AAPL a buy?",
  agents: [:market_analyst, :research_analyst],
  min_agreement: 0.7
)
```

## 📁 File Structure

```
trading_desk/
├── trading_desk.ex          # Main public API
├── supervisor.ex            # OTP supervisor
├── coordinator.ex           # Orchestration agent
├── agent_server.ex          # GenServer for specialists
├── agent_specs.ex           # Agent definitions
├── router.ex                # Query routing logic
├── tools/
│   ├── market_tools.ex      # Market data tools
│   ├── risk_tools.ex        # Risk calculation tools
│   ├── trading_tools.ex     # Trading execution tools
│   └── research_tools.ex    # Research tools
├── demo.exs                 # Runnable demo
└── README.md                # This file
```

## 🧪 Testing

```elixir
# Test individual agent
{:ok, _} = TradingDesk.start()

result = TradingDesk.ask_agent(:market_analyst, "Analyze AAPL")
assert result.output =~ "AAPL"

# Test routing
{:ok, response} = TradingDesk.query("What's the risk?")
assert Enum.any?(response.agents_consulted, fn {id, _} -> id == :risk_manager end)

# Test multi-agent
{:ok, analysis} = TradingDesk.analyze_trade(symbol: "AAPL", quantity: 100)
assert Map.has_key?(analysis.analyses, :market_analysis)
assert Map.has_key?(analysis.analyses, :risk_analysis)
```

## 💡 Real-World Applications

This pattern works for ANY multi-agent system:

- **Customer Support:** Routing agent → Billing, Technical, Sales agents
- **Code Review:** Coordinator → Security, Performance, Style agents
- **Content Creation:** Editor → Writer, Researcher, Fact-checker agents
- **Data Analysis:** Router → Statistics, Visualization, Insights agents
- **Healthcare:** Triage → Diagnosis, Treatment, Pharmacy agents

## 🏆 Why This Matters

**This demonstrates production-ready multi-agent architecture:**

1. ✅ **Proper OTP design** - Supervisor tree, GenServers
2. ✅ **Process isolation** - Each agent is independent
3. ✅ **Fault tolerance** - One agent crash doesn't affect others
4. ✅ **Scalability** - Easy to add more agents
5. ✅ **Testability** - Each agent can be tested independently
6. ✅ **Maintainability** - Clear separation of concerns
7. ✅ **Distribution** - Works across Elixir cluster

**This is how you build real AI applications with Elixir!** 🚀

---

**Built with Yggdrasil AI** - Type-safe AI agents for Elixir
