# Complete Projects

Real-world applications demonstrating production architectures and multi-agent patterns.

## Overview

These are complete, working applications that showcase advanced Nous AI patterns in realistic scenarios. Each project represents a different architectural approach and use case.

## Projects

### [council/](council/) - Multi-LLM Deliberation System
**Architecture**: Multi-agent consensus with 3-stage voting
**Use case**: Getting the best answer by consulting multiple AI models
**Key patterns**:
- Agent coordination
- Consensus mechanisms
- Model comparison
- Quality evaluation

**What it demonstrates**:
- Multiple LLMs collaborating on a single problem
- Democratic decision making between AI agents
- Handling disagreement and finding consensus
- Quality scoring and selection algorithms

---

### [trading_desk/](trading_desk/) - Enterprise Multi-Agent System
**Architecture**: 4 specialized agents with supervisor coordination
**Use case**: Financial trading decision support system
**Key patterns**:
- Domain-specific agents (Market, Risk, Trading, Research)
- Supervisor coordination
- 18 specialized tools
- Enterprise integration patterns

**What it demonstrates**:
- Agent specialization and division of labor
- Complex tool ecosystems
- Risk management and validation
- Enterprise-grade architecture

---

### [coderex/](coderex/) - AI Code Editor
**Architecture**: Single agent with specialized code tools
**Use case**: AI-powered code generation and editing
**Key patterns**:
- SEARCH/REPLACE diff format
- File system operations
- Code understanding and generation
- Interactive development workflow

**What it demonstrates**:
- Code-aware AI agents
- File manipulation and editing
- Structured output formats
- Developer tool integration

## Learning Value

### Architectural Patterns
- **Council**: Horizontal scaling with consensus
- **Trading Desk**: Vertical specialization with coordination
- **Coderex**: Deep domain expertise with rich tooling

### Production Concerns
- Error handling and recovery
- Performance optimization
- User experience design
- Integration patterns

### Real-world Complexity
- Multi-step workflows
- Complex business logic
- Data validation and verification
- Human-AI interaction patterns

## Getting Started

Each project includes:
- **README.md** - Complete setup and usage guide
- **Working code** - Production-ready implementations
- **Documentation** - Architecture explanations
- **Examples** - Usage demonstrations

Choose based on your interests:
- **Coordination patterns** → Council
- **Enterprise applications** → Trading Desk
- **Developer tools** → Coderex

## Prerequisites

- Complete understanding of [../03-production/](../03-production/) patterns
- Production Elixir/OTP experience
- Domain knowledge helpful but not required

## What You'll Learn

**After studying these projects, you'll understand**:
- ✅ Real-world multi-agent architectures
- ✅ Production deployment considerations
- ✅ Complex business logic implementation
- ✅ Human-AI interaction patterns
- ✅ Enterprise integration strategies

## Next Steps

**Want to build your own?**
- Use [../../templates/](../../templates/) as starting points
- Read [production best practices](../../docs/guides/best-practices.md)
- Study the [tool development guide](../../docs/guides/tool-development.md)