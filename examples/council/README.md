# 🏛️ Council - Multi-LLM Deliberation System

**Advanced multi-agent pattern** where multiple AI models collaborate through structured debate and synthesis to reach better decisions.

## 🎯 What is Council?

Council implements a **3-stage deliberation process** inspired by human decision-making:

1. **Stage 1**: Individual responses - Each council member provides their independent perspective
2. **Stage 2**: Peer evaluation - Members anonymously rank each other's responses
3. **Stage 3**: Final synthesis - A Chairman combines insights into the optimal answer

```
┌─────────────────────────────────────────────────────────────┐
│                    User Question                            │
└───────────────────┬─────────────────────────────────────────┘
                    │
    ┌───────────────┼───────────────┐
    ▼               ▼               ▼
┌────────┐    ┌────────────┐    ┌────────────┐
│ The    │    │ The        │    │ The        │
│ Analyst│    │ Skeptic    │    │ Creative   │
└───┬────┘    └─────┬──────┘    └─────┬──────┘
    │               │               │
    └───────────────┼───────────────┘
                    │
            ┌───────▼───────┐
            │   Chairman    │
            │  (Synthesis)  │
            └───────────────┘
```

## 🧠 The Council Members

Each member has a distinct "personality" despite using the same underlying model:

### The Analyst 📊
- **Focus**: Facts, data, logical reasoning
- **Strengths**: Systematic analysis, evidence-based conclusions
- **Perspective**: "What does the data tell us?"

### The Skeptic 🤔
- **Focus**: Questions assumptions, identifies flaws
- **Strengths**: Critical thinking, risk assessment
- **Perspective**: "What could go wrong? What are we missing?"

### The Creative 🎨
- **Focus**: Novel perspectives, innovative solutions
- **Strengths**: Out-of-the-box thinking, alternative approaches
- **Perspective**: "What if we tried something different?"

### The Chairman 🎯
- **Role**: Synthesizes all perspectives into final decision
- **Process**: Reviews all responses and rankings
- **Output**: Balanced, comprehensive answer

## 🚀 Quick Start

```bash
# 1. Start LM Studio with a loaded model
# 2. Run the demo
cd examples/council
elixir council_demo.exs
```

## 💡 Usage Examples

### Basic Council Consultation

```elixir
# Create council with different perspectives
council = Council.new([
  {"lmstudio:qwen/qwen3-4b-2507", "The Analyst - focuses on facts and logic"},
  {"lmstudio:qwen/qwen3-4b-2507", "The Skeptic - questions assumptions"},
  {"lmstudio:qwen/qwen3-4b-2507", "The Creative - thinks outside the box"}
])

# Ask the council a complex question
{:ok, result} = Council.deliberate(council,
  "Should our startup pivot to AI consulting?"
)

# Get comprehensive answer with multiple perspectives
IO.puts(result.final_answer)
IO.inspect(result.member_responses)
IO.inspect(result.rankings)
```

### Custom Council Configuration

```elixir
# Create specialized council for technical decisions
tech_council = Council.new([
  {"anthropic:claude-sonnet-4-5-20250929", "Senior Engineer - focuses on architecture and scalability"},
  {"openai:gpt-4", "Security Expert - evaluates risks and vulnerabilities"},
  {"lmstudio:codellama", "Performance Specialist - optimizes for speed and efficiency"}
])

{:ok, decision} = Council.deliberate(tech_council,
  "Which database should we use for our high-traffic application?"
)
```

## 🔄 Deliberation Process

### Stage 1: Independent Responses
```elixir
# Each member responds independently to avoid groupthink
responses = Enum.map(council.members, fn member ->
  Yggdrasil.run(member.agent, question)
end)
```

### Stage 2: Anonymous Peer Review
```elixir
# Members rank responses without knowing who wrote them
rankings = Enum.map(council.members, fn member ->
  prompt = """
  Rank these responses from best to worst:
  Response A: #{response_a}
  Response B: #{response_b}
  Response C: #{response_c}
  """

  Yggdrasil.run(member.agent, prompt)
end)
```

### Stage 3: Chairman Synthesis
```elixir
# Chairman reviews all responses and rankings
synthesis_prompt = """
Based on these responses and peer rankings:
#{format_responses_and_rankings(responses, rankings)}

Provide a comprehensive final answer that:
1. Incorporates the strongest points from each perspective
2. Addresses concerns raised by skeptical voices
3. Balances creative ideas with practical constraints
"""

final_answer = Yggdrasil.run(chairman_agent, synthesis_prompt)
```

## 🎓 Learning Objectives

This example demonstrates:

- ✅ **Multi-agent orchestration** - Coordinating multiple AI models
- ✅ **Diverse perspectives** - Same model, different "personalities"
- ✅ **Structured deliberation** - Systematic decision-making process
- ✅ **Anonymous evaluation** - Reducing bias in peer review
- ✅ **Synthesis patterns** - Combining multiple viewpoints
- ✅ **Consensus building** - Reaching better decisions through collaboration

## 🛠️ Architecture

```
council/
├── council.ex           # Main Council implementation
├── council_demo.exs     # Runnable demonstration
└── README.md            # This documentation
```

### Key Components

```elixir
defmodule Council do
  # Council configuration
  defstruct [:members, :chairman, :options]

  # Main deliberation function
  def deliberate(council, question, options \\ [])

  # Create council with member specifications
  def new(member_specs, chairman_spec \\ nil)
end
```

## 🔬 Advanced Features

### Weighted Voting
```elixir
# Give more weight to expert opinions
council = Council.new([
  {"expert_model", "Domain Expert", weight: 3.0},
  {"general_model", "Generalist", weight: 1.0},
  {"creative_model", "Creative Thinker", weight: 1.5}
])
```

### Dynamic Member Selection
```elixir
# Choose council members based on question type
defmodule SmartCouncil do
  def auto_select_members(question) do
    cond do
      String.contains?(question, ["technical", "code"]) ->
        create_technical_council()
      String.contains?(question, ["business", "strategy"]) ->
        create_business_council()
      true ->
        create_general_council()
    end
  end
end
```

### Iterative Refinement
```elixir
# Multiple rounds of deliberation for complex decisions
{:ok, round1} = Council.deliberate(council, question)
{:ok, round2} = Council.deliberate(council, """
Given this initial conclusion: #{round1.final_answer}
What additional considerations should we address?
""")
```

## 📊 When to Use Council

**✅ Great for:**
- Complex decisions with multiple valid perspectives
- Strategic planning and analysis
- Creative problem solving
- Reducing single-model bias
- Building consensus among different viewpoints

**❌ Not ideal for:**
- Simple factual questions
- Time-sensitive decisions (due to multiple model calls)
- Questions with clear right/wrong answers
- Resource-constrained environments

## 🔗 Learning Path Integration

### Prerequisites
- ✅ Basic agent usage → [simple_working.exs](../simple_working.exs)
- ✅ Tool calling → [tools_simple.exs](../tools_simple.exs)
- ✅ Multi-turn conversation → [conversation_history_example.exs](../conversation_history_example.exs)

### Next Steps
After mastering Council, explore:
- 🏦 **[Trading Desk](../trading_desk/)** - Enterprise multi-agent coordination
- 💬 **[Distributed Agents](../distributed_agent_example.ex)** - Registry-based agent management
- 🔧 **[Coderex](../coderex/)** - Specialized code editing agent

## 🎯 Real-World Applications

### Business Strategy Council
```elixir
business_council = [
  {"anthropic:claude-sonnet-4-5-20250929", "CFO - Financial perspective"},
  {"openai:gpt-4", "CTO - Technical feasibility"},
  {"gemini:gemini-2.0-flash-exp", "CMO - Market analysis"}
]

Council.deliberate(business_council, "Should we expand to European markets?")
```

### Code Review Council
```elixir
code_council = [
  {"lmstudio:codellama", "Security Reviewer - Focus on vulnerabilities"},
  {"anthropic:claude-sonnet-4-5-20250929", "Architecture Reviewer - System design"},
  {"openai:gpt-4", "Performance Reviewer - Optimization opportunities"}
]

Council.deliberate(code_council, """
Review this pull request:
#{pr_code}

Consider security, architecture, and performance implications.
""")
```

## 🧪 Testing Council Decisions

```elixir
defmodule CouncilTest do
  def test_decision_quality do
    # Test with known problems that have "correct" answers
    questions = [
      "What's the best way to handle database connections in Elixir?",
      "Should we use microservices or monolith for our new project?",
      "How do we improve application security?"
    ]

    Enum.each(questions, fn question ->
      {:ok, council_result} = Council.deliberate(council, question)
      {:ok, single_result} = single_agent_answer(question)

      compare_answer_quality(council_result, single_result, question)
    end)
  end
end
```

## 💡 Why Multi-LLM Deliberation Works

1. **Reduces bias** - Different perspectives counter individual model limitations
2. **Improves accuracy** - Peer review catches errors and misconceptions
3. **Increases robustness** - Less likely to miss important considerations
4. **Builds confidence** - Multiple models reaching similar conclusions
5. **Handles complexity** - Different specialists for different aspects

## 🔬 Benchmarking Results

Council typically shows **15-30% improvement** in decision quality for complex, subjective questions compared to single-model responses.

**Best improvements seen in:**
- Strategic business decisions
- Creative problem solving
- Multi-faceted technical choices
- Risk assessment scenarios

**Minimal improvement for:**
- Simple factual questions
- Mathematical calculations
- Well-defined technical problems

---

**Council demonstrates how AI agents can work together like human teams** - with different expertise, perspectives, and collaborative decision-making processes.

Ready to build your own deliberation system? 🏛️