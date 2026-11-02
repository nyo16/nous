# Custom Scorers and Composition
#
# A scorer module implementing the Nous.Eval.Scorer behaviour, an inline
# Scorers.Function, and how required gates, soft weights and the case
# threshold combine into a verdict. Runs fully offline.
#
# Run with: mix run examples/eval/03_custom_scorer.exs

require Logger
Logger.configure(level: :warning)

defmodule Examples.Eval.WordLimit do
  # A reusable scorer: passes when the answer has at most `max` words. The
  # value is a float in 0.0..1.0 so it can also sit in a soft group.
  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.{Score, ScoreInput, ScorerError}

  @impl true
  def id, do: "word_limit"

  # Options are validated once per run, before any agent call: a bad option
  # fails the whole run instead of every sample.
  @impl true
  def init(opts) do
    case Keyword.pop(opts, :max) do
      {max, []} when is_integer(max) and max > 0 -> {:ok, %{max: max}}
      {_, []} -> {:error, "word_limit: :max must be a positive integer"}
      {_, unknown} -> {:error, "word_limit: unknown options #{inspect(Keyword.keys(unknown))}"}
    end
  end

  @impl true
  def score(%ScoreInput{output: text}, %{max: max}) when is_binary(text) do
    words = text |> String.split() |> length()

    {:ok,
     %Score{
       name: id(),
       value: min(1.0, max / max(words, 1)),
       passed?: words <= max,
       reason: "#{words} words (max #{max})",
       details: %{words: words}
     }}
  end

  # A failed agent run has no output: that is a fail of the agent, not an
  # error of the instrument.
  def score(%ScoreInput{output: nil}, _config),
    do: {:ok, %Score{name: id(), value: :fail, passed?: false, reason: "run_failed"}}

  # Structured output is a misconfiguration: say so instead of guessing.
  def score(%ScoreInput{}, _config),
    do: {:error, %ScorerError{scorer: id(), kind: :invalid_config, reason: "needs text output"}}

  # What identifies this scorer in the run fingerprint: changing `max`
  # makes runs non-comparable without a rescore.
  @impl true
  def describe(config), do: config

  # Options a YAML/JSONL dataset may set once the scorer is registered.
  @impl true
  def option_keys, do: [:max]
end

defmodule Examples.Eval.CatalogModel do
  # A deterministic stand-in for the LLM, installed by the task's setup/1.
  alias Nous.Message

  @answers %{
    "kettle" => "A 1.7 litre steel kettle for $39.",
    "lamp" =>
      "This beautiful handcrafted desk lamp brings warm, focused light to any " <>
        "workspace, study or reading nook for just $59.",
    "chair" => "An ergonomic office chair.",
    "mug" => "A stoneware mug for $12."
  }

  def request(_model, messages, _settings) do
    prompt = messages |> List.last() |> Message.extract_text()
    {_, answer} = Enum.find(@answers, {nil, "I don't know."}, fn {k, _} -> prompt =~ k end)
    {:ok, Message.assistant(answer, metadata: %{usage: %Nous.Usage{requests: 1}})}
  end

  def request_stream(_model, _messages, _settings), do: {:error, :streaming_not_supported}
  def count_tokens(_messages), do: 0
end

defmodule Examples.Eval.Catalog do
  use Nous.Eval

  alias Nous.Eval.Scorers.{Function, Similarity}

  @impl Nous.Eval
  def dataset do
    [
      product("kettle", "A 1.7 litre steel kettle for $39."),
      product("lamp", "A warm desk lamp for $59."),
      product("chair", "An ergonomic office chair for $199."),
      # A case-level scorer with a bug: it expects metadata the case lacks.
      # The raise becomes a ScorerError and the sample's verdict is :error,
      # never :fail - a broken instrument says nothing about the agent.
      Map.put(product("mug", "A stoneware mug for $12."), :scorers, [
        {Function, name: "has_sku", fun: &__MODULE__.has_sku?/1}
      ])
    ]
  end

  defp product(item, description) do
    %{
      id: "describe-#{item}",
      input: "Describe the #{item} in one sentence with its price.",
      expected: %{"output" => description},
      # The soft group's weighted mean must reach this for a pass.
      threshold: 0.6
    }
  end

  # Function scorers take named captures: an anonymous fn cannot be
  # fingerprinted, so editing it would not change the run fingerprint.
  def mentions_price?(input), do: input.output =~ "$"
  def has_sku?(input), do: Map.fetch!(input.case.metadata, "sku") != nil

  # The verdict, in order: any scorer error -> :error; any required score
  # failed -> :fail; soft weighted mean below the threshold -> :fail; else
  # :pass. weight: 0 would track a metric without affecting the verdict.
  @impl Nous.Eval
  def scorers do
    [
      # A gate (required: true is the default).
      {Examples.Eval.WordLimit, max: 12},
      # Soft: mentioning the price counts twice as much as wording.
      {Function,
       name: "mentions_price", fun: &__MODULE__.mentions_price?/1, required: false, weight: 2},
      # Reads the case's expected["output"].
      {Similarity, threshold: 0.5, required: false, weight: 1}
    ]
  end

  @impl Nous.Eval
  def setup(_opts) do
    Nous.ModelDispatcher.put_dispatcher(Examples.Eval.CatalogModel)
    {:ok, nil}
  end

  @impl Nous.Eval
  def teardown(_state), do: Nous.ModelDispatcher.put_dispatcher(nil)

  @impl Nous.Eval
  def agent(_ctx), do: Nous.new("openai:gpt-4o-mini", instructions: "Write catalog copy.")
end

{:ok, run} = Nous.Eval.run(Examples.Eval.Catalog, k: 1)

format = fn
  value when is_float(value) -> :erlang.float_to_binary(value, decimals: 2)
  value -> inspect(value)
end

for s <- run.samples do
  # case_score is the gated objective: 0.0 when a gate failed, else the soft
  # weighted mean; nil when the verdict is :error.
  IO.puts("#{s.case_id}: #{s.verdict} (case_score #{format.(s.case_score)})")

  for score <- s.scores do
    IO.puts("  #{score.name} = #{format.(score.value)} passed?=#{score.passed?} #{score.reason}")
  end

  for error <- s.scorer_errors, do: IO.puts("  ERROR #{Exception.message(error)}")
end

# Registering the scorer under a name lets dataset files use it:
#
#     scorers:
#       - scorer: word_limit
#         max: 12
#         required: false
#
# Usually this goes in config (config :nous, :eval_scorers, %{...}).
Application.put_env(:nous, :eval_scorers, %{"word_limit" => Examples.Eval.WordLimit})

{:ok, spec} = Nous.Eval.Scorer.resolve("word_limit", %{"max" => 12, "required" => false})
IO.puts("\nResolved from a file entry: #{inspect(spec)}")
