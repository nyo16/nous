# Datasets in YAML and JSONL
#
# Cases live in data files (schema `nous.case/1`) that name their scorers by
# string. The same cases ship in two formats under examples/eval/data/:
# support_faq.yaml and support_faq.jsonl. Runs fully offline.
#
# Run with: mix run examples/eval/02_yaml_dataset.exs

require Logger
Logger.configure(level: :warning)

alias Nous.Eval.Dataset

yaml_path = Path.expand("data/support_faq.yaml", __DIR__)
jsonl_path = Path.expand("data/support_faq.jsonl", __DIR__)

# Loading validates everything up front (unknown keys, scorers and scorer
# options are errors), so a dataset that loads is one the runner can execute.
{:ok, yaml} = Dataset.load(yaml_path)
{:ok, jsonl} = Dataset.load(jsonl_path)

IO.puts("Dataset #{yaml.name}: #{length(yaml.cases)} cases")

for c <- yaml.cases do
  scorers = Enum.map_join(c.scorers, ", ", & &1.module.id())
  IO.puts("  #{c.id} [split #{c.split}] tags=#{inspect(c.tags)} scorers=#{scorers}")
end

# The content hash ignores the file format, key order and case order, so a
# run record tells exactly which data it saw.
IO.puts("\nSame hash in YAML and JSONL: #{yaml.hash == jsonl.hash}")

# Cases without `split:` get one from a hash of their group (default: the
# id), so adding cases never moves the others. Filter like `--split`/`--tag`:
returns = Dataset.filter(yaml, tags: ["returns"])
IO.puts("Cases tagged returns: #{Enum.map_join(returns.cases, ", ", & &1.id)}\n")

defmodule Examples.Eval.SupportModel do
  # A deterministic stand-in for the LLM, installed by the task's setup/1.
  alias Nous.Message

  def request(_model, messages, _settings) do
    question = messages |> List.last() |> Message.extract_text() |> String.downcase()

    answer =
      cond do
        question =~ "60 days" -> "Sorry, refunds are only possible within 30 days of delivery."
        question =~ "return" -> "You can return any item within 30 days of delivery."
        question =~ "shipping" -> "Standard shipping takes 3-5 business days."
        question =~ "hi" -> "Hello! How can I help you?"
        true -> "I don't know."
      end

    # The agent runner reads usage from every response's metadata.
    {:ok, Message.assistant(answer, metadata: %{usage: %Nous.Usage{requests: 1}})}
  end

  def request_stream(_model, _messages, _settings), do: {:error, :streaming_not_supported}
  def count_tokens(_messages), do: 0
end

defmodule Examples.Eval.SupportFaq do
  use Nous.Eval

  # dataset/0 may return a file path; the runner loads and validates it.
  @impl Nous.Eval
  def dataset, do: Path.expand("data/support_faq.yaml", __DIR__)

  # Task-wide scorers apply to every case in the file, before the file's own.
  @impl Nous.Eval
  def scorers, do: [{Nous.Eval.Scorers.NotContains, values: ["I don't know"]}]

  @impl Nous.Eval
  def setup(_opts) do
    Nous.ModelDispatcher.put_dispatcher(Examples.Eval.SupportModel)
    {:ok, nil}
  end

  @impl Nous.Eval
  def teardown(_state), do: Nous.ModelDispatcher.put_dispatcher(nil)

  @impl Nous.Eval
  def agent(_ctx), do: Nous.new("openai:gpt-4o-mini", instructions: "You are Acme support.")
end

# A message-list input (the greeting case) runs as Nous.run(agent, messages: ...).
{:ok, run} = Nous.Eval.run(Examples.Eval.SupportFaq, k: 1)

# Markdown is what a CI job posts as a PR comment.
IO.puts(Nous.Eval.Reporter.render(run, format: :markdown))

# Scorer names a file can use are the built-ins ("contains", "regex",
# "similarity", "trajectory", "judge", ...) plus your own, registered with
#
#     config :nous, :eval_scorers, %{"house_style" => MyApp.Eval.HouseStyle}
#
# (the module must define option_keys/0; see 03_custom_scorer.exs).
