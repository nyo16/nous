defmodule Nous.Eval.Dogfood.Basic do
  @moduledoc """
  Plain question answering against `Nous.LLMTestHelper.test_model/0`.

  The cases live in `test/eval/dogfood_basic.yaml` and are scored with the
  file-named `contains`, `equals`, `regex` and `similarity` scorers. A case's
  `metadata.instructions` becomes the agent's instructions.
  """

  use Nous.Eval

  @impl Nous.Eval
  def dataset, do: Path.join(__DIR__, "dogfood_basic.yaml")

  @impl Nous.Eval
  def scorers, do: [{Nous.Eval.Scorers.MaxTokens, max: 4_000, required: false, weight: 0}]

  @impl Nous.Eval
  def agent(%{case: c}) do
    Nous.new(Nous.LLMTestHelper.test_model(),
      instructions: Map.get(c.metadata, "instructions", "You are a helpful assistant."),
      model_settings: %{temperature: 0}
    )
  end
end

defmodule Nous.Eval.Dogfood.ToolCalling do
  @moduledoc """
  Tool calling against `Nous.LLMTestHelper.test_model/0`.

  Every tool has a deterministic body. A case offers the agent only the
  tools named in its `metadata.tools`, and its scorers check which tools
  were called (`Nous.Eval.Scorers.Trajectory`), with which arguments
  (`Nous.Eval.Scorers.ToolArgs`) and how often
  (`Nous.Eval.Scorers.ToolCount`). Every case is also gated by
  `Nous.Eval.Scorers.NoToolErrors`.
  """

  use Nous.Eval

  alias Nous.Eval.Scorers.{Contains, NoToolErrors, Regex, ToolArgs, ToolCount, Trajectory}
  alias Nous.Tool
  alias Nous.Tool.ContextUpdate

  @impl Nous.Eval
  def dataset do
    [
      %{
        id: "weather-tokyo",
        input: "What's the weather in Tokyo?",
        metadata: %{tools: ["get_weather"]},
        scorers: [
          {Trajectory, expected: [%{name: "get_weather"}]},
          {ToolArgs, tool: "get_weather", args: %{"city" => "Tokyo"}},
          {Contains, values: ["72"]}
        ]
      },
      %{
        id: "math-calc",
        input: "Calculate 25 times 4.",
        metadata: %{tools: ["calculate"]},
        scorers: [
          {Trajectory, expected: [%{name: "calculate"}]},
          {ToolArgs, tool: "calculate", args: %{"a" => 25, "b" => 4, "operation" => "multiply"}},
          {Contains, values: ["100"]}
        ]
      },
      %{
        id: "weather-convert",
        input: "Get the weather in Paris and convert the temperature from Fahrenheit to Celsius.",
        metadata: %{tools: ["get_weather", "convert_temperature"]},
        scorers: [
          {Trajectory,
           mode: :in_order,
           expected: [
             %{name: "get_weather", args: %{"city" => "Paris"}},
             %{
               name: "convert_temperature",
               args: %{"value" => 65, "from" => "fahrenheit", "to" => "celsius"}
             }
           ]},
          {Contains, values: ["18"], required: false}
        ]
      },
      %{
        id: "weather-two-cities",
        input: "What's the weather in both Tokyo and Paris?",
        metadata: %{tools: ["get_weather"]},
        scorers: [
          {Trajectory,
           mode: :unordered,
           expected: [
             %{name: "get_weather", args: %{"city" => "Tokyo"}},
             %{name: "get_weather", args: %{"city" => "Paris"}}
           ]},
          {ToolCount, tool: "get_weather", min: 2}
        ]
      },
      %{
        id: "balance-from-deps",
        input: "What's my current balance?",
        metadata: %{tools: ["get_balance"]},
        scorers: [
          {Trajectory, mode: :strict, expected: [%{name: "get_balance"}]},
          {Regex, patterns: ["1,?500"]}
        ]
      },
      %{
        id: "cart-context-update",
        input: "Add 'milk' to my cart, then show me what's in the cart.",
        metadata: %{tools: ["add_to_cart", "list_cart"]},
        scorers: [
          {Trajectory,
           mode: :in_order,
           expected: [%{name: "add_to_cart", args: %{"item" => "milk"}}, %{name: "list_cart"}]},
          {Contains, values: ["milk"], case_sensitive: false}
        ]
      },
      %{
        id: "reverse-string",
        input: "Reverse the text 'nous eval' with the string_reverse tool.",
        metadata: %{tools: ["string_reverse"]},
        scorers: [
          {Trajectory, expected: [%{name: "string_reverse"}]},
          {ToolArgs, tool: "string_reverse", args: %{"text" => "nous eval"}, occurrence: :first},
          {Contains, values: ["lave suon"]}
        ]
      },
      %{
        id: "current-time",
        input: "What's the current date and time?",
        metadata: %{tools: ["get_current_time"]},
        scorers: [
          {Trajectory, mode: :strict, expected: [%{name: "get_current_time"}]},
          {Contains, values: ["2026"], required: false}
        ]
      },
      %{
        id: "no-tool-needed",
        input: "What is the capital of France? Answer in one word.",
        metadata: %{tools: ["get_weather"]},
        scorers: [
          {Trajectory, mode: :strict, expected: []},
          {Contains, values: ["Paris"]}
        ]
      }
    ]
  end

  @impl Nous.Eval
  def scorers, do: [NoToolErrors, {ToolCount, max: 8, required: false, weight: 0}]

  @impl Nous.Eval
  def deps(_state), do: %{user: %{id: 1, balance: 1500}}

  @impl Nous.Eval
  def agent(%{case: c}) do
    offered = Map.fetch!(c.metadata, :tools)

    Nous.new(Nous.LLMTestHelper.test_model(),
      instructions:
        "You are a helpful assistant. Use the provided tools when they help " <>
          "and report their results faithfully.",
      tools: Enum.filter(tools(), &(&1.name in offered)),
      model_settings: %{temperature: 0}
    )
  end

  @doc "Every tool a case may offer."
  def tools do
    [
      Tool.from_function(&__MODULE__.get_weather/2,
        name: "get_weather",
        description: "Get the current weather for a city",
        parameters: object(%{"city" => %{"type" => "string", "description" => "City name"}})
      ),
      Tool.from_function(&__MODULE__.calculate/2,
        name: "calculate",
        description: "Perform an arithmetic operation on two numbers",
        parameters:
          object(%{
            "a" => %{"type" => "number", "description" => "First number"},
            "b" => %{"type" => "number", "description" => "Second number"},
            "operation" => %{
              "type" => "string",
              "enum" => ["add", "subtract", "multiply", "divide"]
            }
          })
      ),
      Tool.from_function(&__MODULE__.convert_temperature/2,
        name: "convert_temperature",
        description: "Convert a temperature between units",
        parameters:
          object(%{
            "value" => %{"type" => "number", "description" => "Temperature value"},
            "from" => %{"type" => "string", "enum" => ["fahrenheit", "celsius"]},
            "to" => %{"type" => "string", "enum" => ["fahrenheit", "celsius"]}
          })
      ),
      Tool.from_function(&__MODULE__.get_balance/2,
        name: "get_balance",
        description: "Get the user's current account balance",
        parameters: object(%{})
      ),
      Tool.from_function(&__MODULE__.add_to_cart/2,
        name: "add_to_cart",
        description: "Add an item to the shopping cart",
        parameters: object(%{"item" => %{"type" => "string", "description" => "Item to add"}})
      ),
      Tool.from_function(&__MODULE__.list_cart/2,
        name: "list_cart",
        description: "List the items in the shopping cart",
        parameters: object(%{})
      ),
      Tool.from_function(&__MODULE__.get_current_time/2,
        name: "get_current_time",
        description: "Get the current date and time",
        parameters: object(%{})
      ),
      Tool.from_function(&__MODULE__.string_reverse/2,
        name: "string_reverse",
        description: "Reverse a string",
        parameters: object(%{"text" => %{"type" => "string", "description" => "Text to reverse"}})
      )
    ]
  end

  defp object(properties) do
    %{"type" => "object", "properties" => properties, "required" => Map.keys(properties)}
  end

  @forecasts %{
    "tokyo" => "72°F, sunny, 45% humidity",
    "paris" => "65°F, cloudy, 60% humidity"
  }

  @doc false
  def get_weather(_ctx, %{"city" => city}) do
    case Map.fetch(@forecasts, String.downcase(city)) do
      {:ok, forecast} -> {:ok, "Weather in #{city}: #{forecast}"}
      :error -> {:ok, "Weather data not available for #{city}"}
    end
  end

  @doc false
  def calculate(_ctx, %{"a" => a, "b" => b, "operation" => op}) do
    case op do
      "add" -> {:ok, "Result: #{a + b}"}
      "subtract" -> {:ok, "Result: #{a - b}"}
      "multiply" -> {:ok, "Result: #{a * b}"}
      "divide" when b != 0 -> {:ok, "Result: #{a / b}"}
      "divide" -> {:ok, "Error: division by zero"}
      other -> {:ok, "Unknown operation #{other}"}
    end
  end

  @doc false
  def convert_temperature(_ctx, %{"value" => value, "from" => from, "to" => to}) do
    case {from, to} do
      {"fahrenheit", "celsius"} -> {:ok, "#{value}°F = #{Float.round((value - 32) * 5 / 9, 1)}°C"}
      {"celsius", "fahrenheit"} -> {:ok, "#{value}°C = #{Float.round(value * 9 / 5 + 32, 1)}°F"}
      _ -> {:ok, "#{value}° (#{from} to #{to}: no conversion needed)"}
    end
  end

  @doc false
  def get_balance(ctx, _args), do: {:ok, "Current balance: $#{ctx.deps.user.balance}"}

  @doc false
  def add_to_cart(ctx, %{"item" => item}) do
    cart = Map.get(ctx.deps, :cart, []) ++ [item]
    {:ok, "Added #{item} to cart", ContextUpdate.new() |> ContextUpdate.set(:cart, cart)}
  end

  @doc false
  def list_cart(ctx, _args) do
    case Map.get(ctx.deps, :cart, []) do
      [] -> {:ok, "Cart is empty"}
      cart -> {:ok, "Cart contains: #{Enum.join(cart, ", ")}"}
    end
  end

  @doc false
  def get_current_time(_ctx, _args), do: {:ok, "Current time: 2026-01-15 09:30:00Z (Thursday)"}

  @doc false
  def string_reverse(_ctx, %{"text" => text}), do: {:ok, String.reverse(text)}
end

defmodule Nous.Eval.DogfoodOfflineTest do
  # Checks the dogfood tasks without calling a model: a broken dataset or
  # scorer option would otherwise only surface in the opt-in :llm run.
  use ExUnit.Case, async: true

  alias Nous.Eval.Dogfood.{Basic, ToolCalling}
  alias Nous.Eval.Scorers.{ToolArgs, ToolCount, Trajectory}
  alias Nous.Eval.{Scoring, Task}

  for task <- [Basic, ToolCalling] do
    test "#{inspect(task)}: every case's scorers initialize and decide its verdict" do
      assert {:ok, %Task{dataset: dataset, scorers: task_scorers}} = Task.load(unquote(task))
      assert dataset.cases != []

      for c <- dataset.cases do
        specs = task_scorers ++ c.scorers

        assert {:ok, _prepared} = Scoring.init(specs), "case #{c.id}"

        assert Enum.any?(specs, &(&1.required or &1.weight > 0)),
               "case #{c.id} has no scorer that affects its verdict"
      end
    end

    test "#{inspect(task)}: builds an agent for every case" do
      {:ok, loaded} = Task.load(unquote(task))
      {:ok, state} = Task.setup(loaded)
      {:ok, deps} = Task.deps(loaded, state)

      for c <- loaded.dataset.cases do
        context = %{case: c, sample: 0, seed: nil, deps: deps, state: state}
        assert {:ok, %Nous.Agent{}} = Task.agent(loaded, context), "case #{c.id}"
      end
    end
  end

  test "ToolCalling offers every case the tools its scorers expect" do
    {:ok, task} = Task.load(ToolCalling)

    for c <- task.dataset.cases do
      context = %{case: c, sample: 0, seed: nil, deps: ToolCalling.deps(nil), state: nil}
      {:ok, agent} = Task.agent(task, context)
      offered = MapSet.new(agent.tools, & &1.name)

      for name <- expected_tools(c.scorers) do
        assert name in offered, "case #{c.id} expects #{name}, offered #{inspect(offered)}"
      end
    end
  end

  defp expected_tools(specs) do
    Enum.flat_map(specs, fn
      %{module: Trajectory, opts: opts} -> Enum.map(opts[:expected], & &1.name)
      %{module: module, opts: opts} when module in [ToolArgs, ToolCount] -> List.wrap(opts[:tool])
      _ -> []
    end)
  end
end

defmodule Nous.Eval.DogfoodTest do
  # Runs the dogfood tasks against the real model from
  # Nous.LLMTestHelper.test_model/0 (TEST_MODEL). Pass rates depend on the
  # model and are not asserted; the run itself must be clean: every sample
  # ran, every scorer produced a result.
  #
  #     mix test test/eval/dogfood_test.exs --include llm
  use ExUnit.Case, async: false

  @moduletag :llm
  @moduletag timeout: 900_000

  alias Nous.Eval.Dogfood.{Basic, ToolCalling}

  setup_all do
    case Nous.LLMTestHelper.check_model_available() do
      :ok -> :ok
      {:error, reason} -> flunk("#{Nous.LLMTestHelper.test_model()} is unavailable: #{reason}")
    end
  end

  test "Basic runs clean" do
    assert_clean_run(Basic, k: 2, seed: 20_261_101)
  end

  test "ToolCalling runs clean" do
    assert_clean_run(ToolCalling, k: 1, seed: 20_261_101)
  end

  defp assert_clean_run(task, opts) do
    {:ok, %Nous.Eval.Task{dataset: dataset}} = Nous.Eval.Task.load(task)

    assert {:ok, run} = Nous.Eval.run(task, [parallelism: 2, timeout: 180_000] ++ opts)

    IO.puts(Nous.Eval.Reporter.render(run, format: :console))

    assert run.status == :completed
    assert length(run.samples) == length(dataset.cases) * opts[:k]

    for sample <- run.samples do
      label = "#{sample.case_id}##{sample.index}"

      assert sample.outcome == :ok, "#{label} did not finish: #{sample.error}"
      assert sample.scorer_errors == [], "#{label}: #{inspect(sample.scorer_errors)}"
      assert sample.verdict in [:pass, :fail], "#{label} verdict #{inspect(sample.verdict)}"
    end
  end
end
