defmodule Nous.Eval.RunBuilder do
  @moduledoc false
  # Builds synthetic `Nous.Eval.Run`s for summary, comparison and reporter
  # tests. A run is described per case as a list of sample specs:
  #
  #     RunBuilder.run([{"a", [:pass, :fail, :pass]}, {"b", [:error]}], seed: 1)
  #
  # A sample spec is a verdict (`:pass | :fail | :error | nil`) or
  # `{verdict, overrides}` where overrides are `Nous.Eval.Sample` fields plus
  # `:score` (the value of the "check" score) and `:extra_scores`.
  #
  #   * `:pass` / `:fail` - outcome `:ok`, one "check" score, case_score 1.0/0.0
  #   * `:error` - outcome `:ok`, a "check" score plus a "judge" scorer error
  #     of kind `:judge_unparseable` (an error sample keeps the other scores)
  #   * `nil` - never ran: outcome `:budget_exhausted`, no verdict

  alias Nous.Eval.{Run, Sample, Score, ScorerError}

  @doc "A run with the given cases."
  def run(cases, opts \\ []) do
    samples =
      Enum.flat_map(cases, fn {case_id, specs} ->
        specs |> Enum.with_index() |> Enum.map(fn {spec, i} -> sample(case_id, i, spec) end)
      end)

    k = cases |> Enum.map(fn {_id, specs} -> length(specs) end) |> Enum.max(fn -> 1 end)

    struct!(
      Run,
      Keyword.merge(
        [
          id: "run-" <> Integer.to_string(:erlang.phash2(cases)),
          task: "MyApp.Evals.Support",
          dataset_hash: "sha256:dataset",
          k: k,
          seed: 7,
          fingerprint: %{"id" => "sha256:fp", "model" => "openai:gpt-4o", "k" => k},
          samples: samples
        ],
        opts
      )
    )
  end

  @doc "`n_cases` cases named `c01`.. with the same spec list each."
  def uniform(n_cases, specs_fun) when is_function(specs_fun, 1) do
    for i <- 1..n_cases do
      {"c" <> String.pad_leading(Integer.to_string(i), 2, "0"), specs_fun.(i)}
    end
  end

  def sample(case_id, index, {verdict, overrides}), do: build(case_id, index, verdict, overrides)
  def sample(case_id, index, verdict), do: build(case_id, index, verdict, [])

  defp build(case_id, index, verdict, overrides) do
    {score_value, overrides} = Keyword.pop(overrides, :score, default_score(verdict))
    {extra, overrides} = Keyword.pop(overrides, :extra_scores, [])

    base =
      case verdict do
        nil ->
          %Sample{case_id: case_id, index: index, outcome: :budget_exhausted}

        :error ->
          %Sample{
            case_id: case_id,
            index: index,
            outcome: :ok,
            verdict: :error,
            scores: [check(score_value) | extra],
            scorer_errors: [
              %ScorerError{scorer: "judge", kind: :judge_unparseable, reason: "no verdict"}
            ]
          }
          |> ran()

        v when v in [:pass, :fail] ->
          %Sample{
            case_id: case_id,
            index: index,
            outcome: :ok,
            verdict: v,
            case_score: if(v == :pass, do: 1.0, else: 0.0),
            scores: [check(score_value) | extra]
          }
          |> ran()
      end

    struct!(base, overrides)
  end

  defp default_score(:fail), do: :fail
  defp default_score(_), do: :pass

  defp check(value) do
    %Score{
      name: "check",
      value: value,
      passed?: value == :pass or (is_float(value) and value >= 0.5)
    }
  end

  defp ran(sample) do
    %{
      sample
      | usage: %Nous.Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120, requests: 1},
        cost: 0.001,
        duration_ms: 1_000,
        iterations: 1
    }
  end
end
