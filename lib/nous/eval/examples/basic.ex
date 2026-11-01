defmodule Nous.Eval.Examples.Basic do
  @moduledoc """
  A complete eval task that runs offline, for trying the eval workflow
  without an API key:

      mix nous.eval --task Nous.Eval.Examples.Basic --k 3 --set-baseline example
      mix nous.eval --task Nous.Eval.Examples.Basic --k 3 --baseline example

  The agent answers weather questions with a `get_weather` tool and
  arithmetic directly. Five cases cover a string prompt, a message-list
  input, a tool call with expected arguments and a no-tool answer; every
  case is scored by `Nous.Eval.Scorers.NoToolErrors` plus its own
  `Nous.Eval.Scorers.Trajectory` and `Nous.Eval.Scorers.Contains`.

  ## The scripted model

  Unless `NOUS_EVAL_EXAMPLE_MODEL` is set, `c:Nous.Eval.setup/1` installs a
  scripted model (the internal `ScriptedModel` module) as the process-scoped
  model dispatcher (`Nous.ModelDispatcher.put_dispatcher/1`) of the process
  running the eval, and `c:Nous.Eval.teardown/1` removes it; the eval's
  sample processes find it through `$callers`. When a dispatcher is already
  installed (a test's stub) it is left alone. The scripted model is
  deterministic and, like a real model, decides from the tool
  **descriptions** it is offered: it calls the weather tool only when a
  tool's description mentions the weather. Edit the description in
  `weather_tool/0` and re-run with `--baseline` to watch a regression
  appear in the comparison.

  Set `NOUS_EVAL_EXAMPLE_MODEL=openai:gpt-4o-mini` (any `provider:model`)
  to run the same task against a real model.
  """

  use Nous.Eval

  alias Nous.Eval.Scorers.{Contains, NoToolErrors, Trajectory}
  alias Nous.Message

  @scripted_model "openai:gpt-4o-mini"

  @impl Nous.Eval
  def dataset do
    [
      weather("weather-paris", "What is the weather in Paris?", "Paris", "sunny"),
      weather("weather-oslo", "Is it raining in Oslo right now?", "Oslo", "rain"),
      weather(
        "weather-tokyo",
        [
          Message.system("You are a terse assistant."),
          Message.user("What's the weather like in Tokyo?")
        ],
        "Tokyo",
        "cloudy"
      ),
      arithmetic("math-add", "What is 17 + 25?", "42"),
      arithmetic("math-mul", "What is 6 * 7?", "42")
    ]
  end

  defp weather(id, input, city, expected) do
    %{
      id: id,
      input: input,
      tags: ["tools", "weather"],
      split: "test",
      scorers: [
        {Trajectory, expected: [%{name: "get_weather", args: %{"city" => city}}]},
        {Contains, values: [city, expected], case_sensitive: false}
      ]
    }
  end

  defp arithmetic(id, input, answer) do
    %{
      id: id,
      input: input,
      tags: ["math"],
      split: "test",
      scorers: [
        {Trajectory, expected: [], mode: :strict},
        {Contains, values: [answer]}
      ]
    }
  end

  @impl Nous.Eval
  def scorers, do: [NoToolErrors]

  @impl Nous.Eval
  def setup(_opts) do
    case System.get_env("NOUS_EVAL_EXAMPLE_MODEL") do
      model when is_binary(model) and model != "" ->
        {:ok, %{model: model, installed?: false}}

      _ ->
        install? = Nous.ModelDispatcher.resolve() == Nous.ModelDispatcher

        if install?,
          do: Nous.ModelDispatcher.put_dispatcher(__MODULE__.ScriptedModel)

        {:ok, %{model: @scripted_model, installed?: install?}}
    end
  end

  @impl Nous.Eval
  def teardown(%{installed?: true}), do: Nous.ModelDispatcher.put_dispatcher(nil)
  def teardown(_state), do: :ok

  @impl Nous.Eval
  def agent(%{state: %{model: model}}) do
    Nous.new(model,
      instructions:
        "Answer weather questions with the get_weather tool and arithmetic directly. " <>
          "Name the city in weather answers.",
      tools: [weather_tool()],
      model_settings: %{temperature: 0}
    )
  end

  @doc "The example's `get_weather` tool."
  @spec weather_tool() :: Nous.Tool.t()
  def weather_tool do
    Nous.Tool.from_function(&__MODULE__.get_weather/2,
      name: "get_weather",
      description: "Get the current weather for a city.",
      parameters: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string", "description" => "The city name"}},
        "required" => ["city"]
      }
    )
  end

  @forecasts %{
    "paris" => "sunny, 24°C",
    "oslo" => "light rain, 9°C",
    "tokyo" => "cloudy, 18°C"
  }

  @doc false
  # The tool body: a fixed forecast table.
  def get_weather(_ctx, %{"city" => city}) when is_binary(city) do
    case Map.fetch(@forecasts, String.downcase(city)) do
      {:ok, forecast} -> "#{city}: #{forecast}"
      :error -> "#{city}: no forecast available"
    end
  end

  defmodule ScriptedModel do
    @moduledoc false
    # A deterministic stand-in for a chat model, installed by the example's
    # setup/1. It reads the conversation and the offered tool schemas the way
    # a model would: a weather question gets a `get_weather` call only when an
    # offered tool's description mentions the weather; a tool result is
    # turned into the answer; `a + b` / `a * b` / `a - b` are computed.

    alias Nous.{Message, Usage}

    @cities ["Paris", "Oslo", "Tokyo", "Cairo"]

    def request(_model, messages, settings) do
      {:ok, reply(messages, Map.get(settings, :tools, []))}
    end

    def request_stream(_model, _messages, _settings), do: {:error, :streaming_not_supported}

    def count_tokens(messages), do: messages |> Enum.map(&tokens/1) |> Enum.sum()

    defp reply(messages, tools) do
      case messages |> Enum.reject(&(&1.role == :system)) |> List.last() do
        %Message{role: :tool} = result ->
          answer(messages, "Here is the forecast: " <> Message.extract_text(result) <> ".")

        %Message{role: :user} = question ->
          respond(messages, Message.extract_text(question), weather_tool(tools))

        _ ->
          answer(messages, "I don't know.")
      end
    end

    defp respond(messages, text, tool) do
      city = Enum.find(@cities, &String.contains?(String.downcase(text), String.downcase(&1)))

      cond do
        city && text =~ ~r/weather|rain|forecast/i && tool ->
          call =
            %{
              id: "call_" <> Integer.to_string(:erlang.phash2({city, length(messages)})),
              name: tool,
              arguments: %{"city" => city}
            }

          Message.assistant("", tool_calls: [call], metadata: meta(messages, 12, "tool_calls"))

        city ->
          answer(messages, "I cannot look up the weather in #{city}.")

        match = Regex.run(~r/(-?\d+)\s*([+*-])\s*(-?\d+)/, text) ->
          [_, a, op, b] = match

          answer(
            messages,
            "The answer is #{compute(String.to_integer(a), op, String.to_integer(b))}."
          )

        true ->
          answer(messages, "I don't know.")
      end
    end

    defp compute(a, "+", b), do: a + b
    defp compute(a, "*", b), do: a * b
    defp compute(a, "-", b), do: a - b

    # The name of the first offered tool whose description mentions the
    # weather (tool schemas arrive in the provider's shape).
    defp weather_tool(tools) do
      Enum.find_value(tools, fn tool ->
        function = tool["function"] || tool[:function] || tool
        name = function["name"] || function[:name]
        description = function["description"] || function[:description] || ""
        if is_binary(name) and description =~ ~r/weather/i, do: name
      end)
    end

    defp answer(messages, text) do
      Message.assistant(text, metadata: meta(messages, tokens(text), "stop"))
    end

    defp meta(messages, output, finish_reason) do
      input = count_tokens(messages)

      %{
        usage: %Usage{
          requests: 1,
          input_tokens: input,
          output_tokens: output,
          total_tokens: input + output
        },
        finish_reason: finish_reason
      }
    end

    defp tokens(%Message{} = message), do: tokens(Message.extract_text(message) || "")
    defp tokens(text) when is_binary(text), do: div(String.length(text), 4) + 1
  end
end
