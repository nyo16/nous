defmodule Nous.Eval.ReporterTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Compare, Reporter, Summary, Trace}
  alias Nous.Eval.Reporter.{Console, Markdown}
  alias Nous.Eval.RunBuilder, as: B

  doctest Nous.Eval.Reporter.Markdown

  defp render(subject, opts), do: subject |> Reporter.render(opts) |> IO.iodata_to_binary()

  defp compare!(base, cand, opts \\ []) do
    {:ok, c} = Compare.compare(base, cand, Keyword.merge([resamples: 500, seed: 1], opts))
    c
  end

  defp tiny_run do
    B.run([{"a", [:pass, :pass]}, {"b", [:pass, :fail]}, {"c", [:error, :fail]}],
      id: "run-1",
      seed: 3
    )
  end

  defp all(n, verdict), do: B.uniform(n, fn _ -> [verdict] end)

  # Every row of every Markdown table has as many unescaped pipes as its
  # header: no data broke out of a cell.
  defp tables_consistent?(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.chunk_by(&String.starts_with?(&1, "|"))
    |> Enum.filter(&String.starts_with?(hd(&1), "|"))
    |> Enum.all?(fn rows ->
      rows |> Enum.map(&length(Regex.scan(~r/(?<!\\)\|/, &1))) |> Enum.uniq() |> length() == 1
    end)
  end

  defp pass_comparison,
    do: compare!(B.run(all(4, :pass), id: "base"), B.run(all(4, :pass), id: "cand"))

  defp regression_comparison do
    compare!(
      B.run(all(30, :pass), id: "base"),
      B.run(B.uniform(30, fn i -> [if(i <= 15, do: :fail, else: :pass)] end), id: "cand")
    )
  end

  defp error_comparison do
    compare!(
      B.run(all(4, :pass), id: "base"),
      B.run(B.uniform(4, fn i -> [if(i == 1, do: :error, else: :pass)] end), id: "cand")
    )
  end

  describe "Console" do
    test "renders a run without colors (golden)" do
      assert render(tiny_run(), colors: false) == """
             Eval run run-1 (MyApp.Evals.Support): completed
             Cases 3, samples 6, k 2
             Verdicts: 3 pass, 2 fail, 1 error, 0 not run
             Error rate: 16.7%
             Pass rate: 60.0%  95% Wilson [23.1%, 88.2%]  95% clustered [0.0%, 100.0%]
             pass@2: 100.0%  pass^2: 50.0% (2 cases)
             MDE (one-sided alpha 0.05, 80% power): 101.5 pp
             Scorers:
               check: pass 66.7% [30.0%, 90.3%], mean 0.667, skipped 0, errors none
               judge: no scores, skipped 0, errors judge_unparseable=1
             Errors by kind: judge_unparseable=1
             Agent outcomes: 6 ok, 0 error, 0 killed, 0 budget_exhausted
             Resources: cost $0.0060 total, $0.0010/sample; latency mean 1000 ms, p95 1000 ms; tokens 720 total, 120/sample
             Failing cases (2): b, c
             """
    end

    test "renders each verdict, with ANSI colors only when asked" do
      assert render(pass_comparison(), colors: false) =~ "Comparison: PASS\n"

      regression = render(regression_comparison(), colors: false)
      assert regression =~ "Comparison: REGRESSION\n"
      assert regression =~ "pass_rate regressed by -50.0 pp"
      assert regression =~ "Broken (15): c01, c02"
      refute regression =~ "\e["

      error = render(error_comparison(), colors: false)
      assert error =~ "Comparison: ERROR\n"
      assert error =~ "candidate error rate 25.0% exceeds max_error_rate 0.0%"

      assert render(regression_comparison(), colors: true) =~
               IO.ANSI.red() <> "REGRESSION" <> IO.ANSI.reset()
    end

    test "strips control characters from ids" do
      run = B.run([{"evil\e[2J\nid", [:fail]}])
      out = render(run, colors: false)

      assert out =~ "Failing cases (1): evil?[2J?id\n"
      refute out =~ "\e"
    end

    test "caps case lists" do
      c = regression_comparison()
      out = Console.render(c, colors: false, max_cases: 3) |> IO.iodata_to_binary()
      assert out =~ "Broken (15): c01, c02, c03, ... (12 more)\n"
    end
  end

  describe "Markdown" do
    test "renders each verdict" do
      assert render(pass_comparison(), format: :markdown) =~ "### Eval comparison: **PASS**"

      regression = render(regression_comparison(), format: :markdown)
      assert regression =~ "### Eval comparison: **REGRESSION**"
      assert regression =~ "| pass\\_rate | 100.0% | 50.0% | -50.0 pp |"
      assert regression =~ "**regression** |"
      assert regression =~ "No significant change ≠ no change"
      assert regression =~ "**Broken (15):** c01, c02"

      error = render(error_comparison(), format: :markdown)
      assert error =~ "### Eval comparison: **ERROR**"
      assert error =~ "| judge\\_unparseable | 0 | 1 |"
    end

    test "escapes hostile case ids so they cannot break tables or inject markup" do
      hostile = "a|b`rm -rf`[x](http://evil)<img>@team"
      base = B.run([{hostile, [:pass]}, {"ok", [:pass]}], id: "base")
      cand = B.run([{hostile, [:fail]}, {"ok", [:pass]}], id: "cand")
      # the id is also a tag, so it lands in a table cell
      out =
        render(compare!(base, cand, cases: %{hostile => [hostile], "ok" => [hostile]}),
          format: :markdown
        )

      escaped = ~S"a\|b\`rm \-rf\`\[x\]\(http\://evil\)\<img\>\@team"
      assert out =~ "**Broken (1):** " <> escaped
      assert out =~ "| " <> escaped <> " | 2 |"
      refute out =~ hostile
      refute out =~ "<img>"
      assert tables_consistent?(out)
    end

    test "escapes scorer names and labels" do
      score = %Nous.Eval.Score{name: "tone|x", value: {:label, "**bold**"}, passed?: true}
      run = B.run([{"a", [{:pass, extra_scores: [score]}]}])
      out = render(run, format: :markdown)

      assert out =~ "| tone\\|x |"
      assert out =~ "\\*\\*bold\\*\\* 1"
      assert tables_consistent?(out)
    end

    test "a run report shows the MDE note, scorers and errors" do
      out = render(tiny_run(), format: :markdown)

      assert out =~ "### Eval run run\\-1: completed"
      assert out =~ "| MDE (80% power) | 101.5 pp |"
      assert out =~ "| check | 66.7% | [30.0%, 90.3%] | 0.667 | 0 | 0 |  |"
      assert out =~ "| judge\\_unparseable | 1 |"
      assert out =~ "**Failing cases (2):** b, c"
    end

    test "caps case lists and keeps the count" do
      out = Markdown.render(regression_comparison(), max_cases: 2) |> IO.iodata_to_binary()
      assert out =~ "**Broken (15):** c01, c02, … and 13 more"
    end
  end

  describe "JSON" do
    test "a run renders its summary, never the trace" do
      secret = "TRACE-ONLY-SECRET"

      trace = %Trace{
        trace_id: "0123456789abcdef0123456789abcdef",
        events: [
          %Trace.Event{
            name: [:nous, :agent, :run, :stop],
            measurements: %{},
            metadata: %{output: secret},
            at: 0,
            seq: 0
          }
        ]
      }

      run = B.run([{"a", [{:pass, trace: trace, output: secret}]}])
      out = render(run, format: :json)

      refute out =~ secret
      assert JSON.decode!(out) == run |> Summary.build() |> JSON.encode!() |> JSON.decode!()
    end

    test "a comparison renders Compare.to_map/1" do
      c = regression_comparison()
      decoded = c |> Reporter.render(format: :json) |> IO.iodata_to_binary() |> JSON.decode!()

      assert decoded["verdict"] == "regression"
      assert decoded == c |> Compare.to_map() |> JSON.encode!() |> JSON.decode!()
    end
  end

  describe "dispatch" do
    defmodule Custom do
      @behaviour Nous.Eval.Reporter
      @impl true
      def render(_subject, opts), do: ["custom ", Keyword.fetch!(opts, :tag)]
    end

    test "uses a reporter module given as the format" do
      assert render(tiny_run(), format: Custom, tag: "x") == "custom x"
    end

    test "rejects unknown formats" do
      assert_raise ArgumentError, fn -> Reporter.render(tiny_run(), format: :html) end
    end

    test "a stored summary is rendered as is" do
      run = tiny_run()
      stored = %{run | summary: Summary.build(run), samples: []}
      assert render(stored, colors: false) == render(run, colors: false)
    end
  end
end
