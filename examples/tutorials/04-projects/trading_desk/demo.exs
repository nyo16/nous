#!/usr/bin/env elixir

# Trading Desk Multi-Agent System Demo
#
# This demonstrates an "army of agents" working together:
# - Market Analyst
# - Risk Manager
# - Trading Executor
# - Research Analyst
# - Coordinator (orchestrates them all)

Code.require_file("tools/market_tools.ex", __DIR__)
Code.require_file("tools/risk_tools.ex", __DIR__)
Code.require_file("tools/trading_tools.ex", __DIR__)
Code.require_file("tools/research_tools.ex", __DIR__)
Code.require_file("agent_specs.ex", __DIR__)
Code.require_file("router.ex", __DIR__)
Code.require_file("agent_server.ex", __DIR__)
Code.require_file("coordinator.ex", __DIR__)
Code.require_file("supervisor.ex", __DIR__)
Code.require_file("trading_desk.ex", __DIR__)

IO.puts("\n" <> ("=" |> String.duplicate(80)))
IO.puts("🏦 TRADING DESK - Multi-Agent AI System Demo")
IO.puts("=" |> String.duplicate(80))
IO.puts("")
IO.puts("Starting an army of AI agents...")
IO.puts("")

# Start the trading desk
{:ok, _supervisor_pid} = TradingDesk.start()

# Give agents time to initialize
Process.sleep(1000)

IO.puts("✅ Trading Desk Online!")
IO.puts("")

# Show status
status = TradingDesk.status()
IO.puts("📊 Desk Status:")
IO.puts("   Total Agents: #{status.total_agents}")

Enum.each(status.agents, fn {id, info} ->
  IO.puts("   - #{info.name}: #{info.tools_count} tools, #{info.model}")
end)

IO.puts("")
IO.puts("=" |> String.duplicate(80))

# ============================================================================
# Scenario 1: Simple market query
# ============================================================================

IO.puts("\n📈 Scenario 1: Market Analysis Query")
IO.puts("-" |> String.duplicate(80))
IO.puts("Query: \"What's the current price and trend for AAPL?\"")
IO.puts("")

{:ok, result1} = TradingDesk.query("What's the current price and trend for AAPL?")

IO.puts(result1.synthesized_response)
IO.puts("")
IO.puts("📊 Routing: #{length(result1.agents_consulted)} agent(s) consulted")
IO.puts("   Tokens: #{result1.usage.total_tokens}")
IO.puts("   Tool calls: #{result1.usage.tool_calls}")

IO.puts("")
IO.puts("=" |> String.duplicate(80))

# ============================================================================
# Scenario 2: Risk assessment query
# ============================================================================

IO.puts("\n⚠️  Scenario 2: Risk Assessment Query")
IO.puts("-" |> String.duplicate(80))
IO.puts("Query: \"What's my portfolio exposure and risk level?\"")
IO.puts("")

{:ok, result2} = TradingDesk.query("What's my portfolio exposure and risk level?")

IO.puts(result2.synthesized_response)
IO.puts("")
IO.puts("📊 Routing: #{length(result2.agents_consulted)} agent(s) consulted")
IO.puts("   Tokens: #{result2.usage.total_tokens}")

IO.puts("")
IO.puts("=" |> String.duplicate(80))

# ============================================================================
# Scenario 3: Multi-agent query (should I buy?)
# ============================================================================

IO.puts("\n🤔 Scenario 3: Complex Trading Decision")
IO.puts("-" |> String.duplicate(80))
IO.puts("Query: \"Should I buy 100 shares of TSLA? Give me market analysis and risk assessment.\"")
IO.puts("")

{:ok, result3} = TradingDesk.query(
  "Should I buy 100 shares of TSLA? Give me market analysis and risk assessment."
)

IO.puts(result3.synthesized_response)
IO.puts("")
IO.puts("📊 Routing: #{length(result3.agents_consulted)} agent(s) consulted")

Enum.each(result3.agents_consulted, fn {id, name} ->
  IO.puts("   ✓ #{name} (#{id})")
end)

IO.puts("   Tokens: #{result3.usage.total_tokens}")
IO.puts("   Tool calls: #{result3.usage.tool_calls}")

IO.puts("")
IO.puts("=" |> String.duplicate(80))

# ============================================================================
# Scenario 4: Direct agent access
# ============================================================================

IO.puts("\n🎯 Scenario 4: Direct Agent Query")
IO.puts("-" |> String.duplicate(80))
IO.puts("Querying Risk Manager directly...")
IO.puts("")

{:ok, result4} = TradingDesk.ask_agent(
  :risk_manager,
  "Calculate position size for $100,000 capital with 2% risk and 5% stop loss"
)

IO.puts("Risk Manager says:")
IO.puts(result4.output)
IO.puts("")
IO.puts("📊 Tokens: #{result4.usage.total_tokens}, Tool calls: #{result4.usage.tool_calls}")

IO.puts("")
IO.puts("=" |> String.duplicate(80))

# ============================================================================
# Scenario 5: Structured workflow
# ============================================================================

IO.puts("\n📋 Scenario 5: Structured Trade Analysis Workflow")
IO.puts("-" |> String.duplicate(80))
IO.puts("Analyzing trade: NVDA, 50 shares")
IO.puts("")

{:ok, analysis} = TradingDesk.analyze_trade(
  symbol: "NVDA",
  quantity: 50,
  entry_price: 495.20
)

IO.puts("Trade Analysis for #{analysis.symbol}:")
IO.puts("")

Enum.each(analysis.analyses, fn {type, response, usage} ->
  IO.puts("#{type}:")
  IO.puts(String.slice(response, 0..200) <> "...")
  IO.puts("(#{usage.total_tokens} tokens)")
  IO.puts("")
end)

IO.puts("=" |> String.duplicate(80))

# ============================================================================
# Summary
# ============================================================================

IO.puts("\n✨ Demo Complete!")
IO.puts("")
IO.puts("What we demonstrated:")
IO.puts("  ✓ 4 specialist AI agents working in parallel")
IO.puts("  ✓ Automatic query routing based on keywords")
IO.puts("  ✓ Tool calling across different domains (16+ tools)")
IO.puts("  ✓ Response synthesis and aggregation")
IO.puts("  ✓ Direct agent access")
IO.puts("  ✓ Structured workflows")
IO.puts("")
IO.puts("Architecture:")
IO.puts("  - Supervisor manages all agents")
IO.puts("  - Registry for named processes")
IO.puts("  - Coordinator routes and aggregates")
IO.puts("  - Each agent is an independent GenServer")
IO.puts("  - Agents communicate via message passing")
IO.puts("")
IO.puts("Future enhancements:")
IO.puts("  - Replace keyword matching with embeddings + cosine similarity")
IO.puts("  - Add agent-to-agent direct communication")
IO.puts("  - Implement consensus mechanisms")
IO.puts("  - Add streaming responses to coordinator")
IO.puts("")
IO.puts("🏦 Trading Desk is a production-ready multi-agent pattern!")
IO.puts("")

# Cleanup
TradingDesk.stop()
Process.sleep(500)

IO.puts("✅ Trading desk shut down gracefully")
IO.puts("")
