# Optimizing a tool description into a Nous.Profile, offline.
#
#   mix run examples/eval/06_optimize_profile.exs
#
# A scripted model stands in for both the agent and the reflector, so this
# runs without an API key: the "agent" only calls its lookup tool when the
# tool's description says to ALWAYS use it, and the "reflector" proposes
# exactly that. The optimizer finds the better description on train, picks
# it on val, accepts it on test, and the accepted profile changes what the
# agent's model receives. Swap the scripted model for real ones
# (`reflector: "openai:gpt-4o"`, a real agent model) to optimize for real.

defmodule Examples.Eval.Optimize.Tools do
  # Outside the `Nous` namespace: profiles do not address built-in tools.
  def lookup(_ctx, _args), do: "order 42: shipped yesterday"
end

defmodule Examples.Eval.Optimize.Model do
  alias Nous.{Message, Usage}

  def request(_model, messages, settings) do
    system = for %Message{role: :system} = m <- messages, into: "", do: Message.extract_text(m)

    cond do
      system =~ "You improve the text" ->
        {:ok, text(reflection())}

      system =~ "You write the text" ->
        {:ok, text(JSON.encode!(%{"candidates" => [%{"tool:lookup" => better()}]}))}

      true ->
        send(Process.get(:example_owner) || self(), {:agent_request, settings})
        {:ok, agent(messages, settings)}
    end
  end

  def request_stream(_model, _messages, _settings), do: {:error, :not_supported}
  def count_tokens(_messages), do: 0

  def better, do: "ALWAYS call this tool to look up an order before you answer."

  defp reflection do
    JSON.encode!(%{
      "updates" => [%{"component" => "tool:lookup", "text" => better()}],
      "rationale" => "The agent answered without looking the order up."
    })
  end

  defp agent(messages, settings) do
    last = messages |> Enum.reject(&(&1.role == :system)) |> List.last()

    description =
      Enum.find_value(Map.get(settings, :tools, []), "", fn tool ->
        function = tool["function"] || tool[:function] || tool
        function["description"] || function[:description]
      end)

    cond do
      last.role == :tool ->
        text("Found it: " <> Message.extract_text(last))

      description =~ "ALWAYS" ->
        call = %{id: "call_#{System.unique_integer([:positive])}", name: "lookup", arguments: %{"order" => "42"}}
        Message.assistant("", tool_calls: [call], metadata: meta())

      true ->
        text("I'm not sure where that order is.")
    end
  end

  defp text(content), do: Message.assistant(content, metadata: meta())
  defp meta, do: %{usage: %Usage{requests: 1, input_tokens: 40, output_tokens: 10, total_tokens: 50}}
end

defmodule Examples.Eval.Optimize.Task do
  use Nous.Eval

  @impl true
  def agent(_context) do
    Nous.new("openai:gpt-4o-mini",
      instructions: "You answer questions about orders.",
      tools: [
        Nous.Tool.from_function(&Examples.Eval.Optimize.Tools.lookup/2,
          name: "lookup",
          description: "Order lookup.",
          parameters: %{"type" => "object", "properties" => %{"order" => %{"type" => "string"}}}
        )
      ]
    )
  end

  # 12 cases: 4 each for train (reflection), val (selection) and test
  # (the one-time accept/reject decision).
  @impl true
  def dataset do
    for {split, n} <- [{"train", 4}, {"val", 4}, {"test", 4}], i <- 1..n do
      %{id: "#{split}-#{i}", input: "Where is my order number #{100 * i}?", split: split}
    end
  end

  @impl true
  def scorers, do: [{Nous.Eval.Scorers.Contains, values: ["Found it"]}]
end

alias Examples.Eval.Optimize
alias Nous.Eval.{Optimizer, ProfileReport}

Logger.configure(level: :warning)

Process.put(:example_owner, self())
Nous.ModelDispatcher.put_dispatcher(Optimize.Model)

{:ok, result} =
  Optimizer.run(Optimize.Task,
    reflector: "openai:gpt-4o",
    components: ["tool:lookup"],
    budget: [max_metric_calls: 200],
    k: 2,
    max_steps: 3,
    seed: 1
  )

IO.puts(ProfileReport.render(result.report, format: :console))
IO.puts("\nVerdict: #{result.verdict} after #{result.steps} steps (#{inspect(result.stop_reason)})")
IO.puts("Budget spent: #{inspect(result.budget.spent)}")

# Load the accepted profile and check what the model now receives.
agent = Nous.new("openai:gpt-4o-mini", instructions: "You answer questions about orders.",
  tools: Optimize.Task.agent(%{}).tools, profile: result.profile)

{:ok, answer} = Nous.run(agent, "Where is order 7?")

receive do
  {:agent_request, settings} ->
    sent = inspect(settings[:tools])
    IO.puts("\nRequest carries the new description: #{String.contains?(sent, Optimize.Model.better())}")
end

IO.puts("Agent with the profile answers: #{inspect(answer.output)}")

# A budget that cannot even cover the seed's val + test evaluations is refused
# before any model call.
{:error, reason} = Optimizer.run(Optimize.Task, reflector: "openai:gpt-4o", budget: [max_metric_calls: 3])
IO.puts("\nTiny budget: #{inspect(reason)}")
