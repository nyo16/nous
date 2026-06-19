# Marshalling hot-path baseline (Finding #1 / Phase 2).
#
# Measures the per-iteration cost of converting the conversation + tool set to
# provider format. In the agent loop these run on EVERY iteration over the FULL
# history, so a single-iteration cost of C at N messages implies ~C*iterations
# work across a run (the O(k*n) -> O(k*n^2) blow-up Phase 2 targets).
#
#   Run: MIX_ENV=prod mix run bench/marshalling_bench.exs

alias Nous.Agent.Context
alias Nous.{Message, Tool}
alias Nous.Messages.{Anthropic, OpenAI}
alias Nous.Agents.BasicAgent

# --- synthetic conversation (exactly n non-system messages) ----------------
build_ctx = fn n ->
  msgs =
    for i <- 1..n do
      case rem(i, 3) do
        0 ->
          call = %{
            "id" => "call_#{i}",
            "name" => "search",
            "arguments" => %{"q" => "term #{i}", "k" => i}
          }

          Message.assistant("Step #{i}: calling a tool. " <> String.duplicate("lorem ", 20),
            tool_calls: [call]
          )

        1 ->
          Message.user("User question #{i}? " <> String.duplicate("context ", 15))

        2 ->
          Message.tool("call_#{i - 1}", "result for #{i}: " <> String.duplicate("x", 80),
            name: "search"
          )
      end
    end

  Context.new(messages: [Message.system("You are a helpful assistant.") | msgs])
end

contexts = Map.new([5, 20, 50, 100], fn n -> {n, build_ctx.(n)} end)

# --- synthetic tool set (20 tools, realistic JSON-schema params) -----------
param_schema = %{
  "type" => "object",
  "properties" =>
    Map.new(1..6, fn k ->
      {"param_#{k}",
       %{
         "type" => "string",
         "description" => "Parameter #{k} description text for the tool.",
         "maxLength" => 100
       }}
    end),
  "required" => ["param_1", "param_2"]
}

tools =
  for i <- 1..20 do
    %Tool{
      name: "tool_#{i}",
      description: "Tool number #{i} that performs a useful operation.",
      parameters: param_schema,
      function: fn _args -> :ok end
    }
  end

# convert_tools_for_provider/2 is private in agent_runner; these two Enum.map
# calls ARE its body (anthropic / openai-compatible branches).
tool_anthropic = fn -> Enum.map(tools, &Nous.ToolSchema.to_anthropic/1) end
tool_openai = fn -> Enum.map(tools, &Tool.to_openai_schema/1) end

marshal_anthropic = fn ctx ->
  BasicAgent.build_messages(nil, ctx) |> Anthropic.to_format()
end

marshal_openai = fn ctx ->
  BasicAgent.build_messages(nil, ctx) |> OpenAI.to_format()
end

jobs =
  %{
    "tools->anthropic x20" => tool_anthropic,
    "tools->openai x20" => tool_openai
  }
  |> Map.merge(
    Map.new([5, 20, 50, 100], fn n ->
      {"msgs->anthropic n=#{n}", fn -> marshal_anthropic.(contexts[n]) end}
    end)
  )
  |> Map.merge(
    Map.new([5, 20, 50, 100], fn n ->
      {"msgs->openai n=#{n}", fn -> marshal_openai.(contexts[n]) end}
    end)
  )
  |> Map.put("per-iter anthropic (n=50 + 20 tools)", fn ->
    _ = marshal_anthropic.(contexts[50])
    _ = tool_anthropic.()
  end)

Benchee.run(jobs,
  warmup: 1,
  time: 3,
  memory_time: 1,
  print: [fast_warning: false]
)
