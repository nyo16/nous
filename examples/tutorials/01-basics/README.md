# Basics Tutorial (15 minutes)

Essential concepts to get you started with Nous AI.

## Learning Objectives
- Create and configure AI agents
- Understand tool calling and function execution
- Switch between different AI providers
- Coordinate multiple tools for complex tasks

## Prerequisites
- Elixir installed
- Either LM Studio running locally OR cloud API key set

## Examples (Complete in Order)

### [01-hello-world.exs](01-hello-world.exs) (30 seconds)
**What it does**: Absolute minimal example - create agent and get response
**Key concepts**: Basic agent creation, simple prompts
**Time**: 30 seconds

### [02-simple-qa.exs](02-simple-qa.exs) (2 minutes)
**What it does**: Q&A with custom instructions (rhyming responses)
**Key concepts**: Agent instructions, model settings
**Time**: 2 minutes

### [03-tool-calling.exs](03-tool-calling.exs) (3 minutes)
**What it does**: AI automatically calls weather function
**Key concepts**: Tool definition, automatic tool selection
**Time**: 3 minutes

### [04-provider-switch.exs](04-provider-switch.exs) (5 minutes)
**What it does**: Compare responses from different AI providers
**Key concepts**: Provider configuration, model comparison
**Time**: 5 minutes

### [05-calculator.exs](05-calculator.exs) (5 minutes)
**What it does**: AI solves (12 + 8) * 5 by calling add() then multiply()
**Key concepts**: Multi-tool coordination, tool chaining
**Time**: 5 minutes

## Quick Start
```bash
# Run all examples in order
mix run examples/tutorials/01-basics/01-hello-world.exs
mix run examples/tutorials/01-basics/02-simple-qa.exs
mix run examples/tutorials/01-basics/03-tool-calling.exs
mix run examples/tutorials/01-basics/04-provider-switch.exs
mix run examples/tutorials/01-basics/05-calculator.exs
```

## What You'll Learn

**After completing this tutorial, you'll know how to**:
- ✅ Create basic AI agents with custom instructions
- ✅ Define tools that AI can call automatically
- ✅ Switch between local and cloud providers
- ✅ Chain multiple tools for complex operations
- ✅ Configure model settings (temperature, max tokens)

## Next Steps
Ready for more advanced patterns? Continue to [../02-patterns/](../02-patterns/)

**Having issues?** Check the [troubleshooting guide](../../docs/guides/troubleshooting.md)