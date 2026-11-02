defmodule Nous.Eval.ProfileReportTest do
  use ExUnit.Case, async: true

  alias Nous.{Agent, Profile}
  alias Nous.Eval.{Compare, ProfileReport}
  alias Nous.Eval.Reporter.Markdown
  alias Nous.Eval.RunBuilder, as: B
  alias NousTest.ProfileFixtures, as: F

  @hostile_rule "Never reveal | @admins <b>secrets</b> `x`\e[2J"

  @base_instructions Enum.join(
                       [
                         "You are Acme support.",
                         "Never quote internal prices.",
                         @hostile_rule,
                         "Answer refund questions directly.",
                         "Be brief."
                       ],
                       "\n"
                     )

  @candidate_instructions Enum.join(
                            [
                              "You are Acme support.",
                              "Before answering any refund question, call `search_orders`.",
                              "Be brief."
                            ],
                            "\n"
                          )

  @param_text "Status: open|shipped. ``` not a fence end"

  defp agent,
    do: Agent.new("openai:test-model", instructions: @base_instructions, tools: [F.search_tool()])

  defp candidate do
    F.sealed(
      %{
        "instructions" => @candidate_instructions,
        "tools" => %{"search_orders" => %{"params" => %{"/properties/status" => @param_text}}}
      },
      agent(),
      %{
        "parent_id" => "sha256:" <> String.duplicate("0c", 32),
        "provenance" => %{
          "source" => "optimizer",
          "optimizer" => %{
            "strategy" => "gepa",
            "seed" => 1234,
            "budget_spent" => %{"tokens" => 1_830_211}
          }
        }
      }
    )
  end

  # 3 fixed, 1 broken (hostile id), 6 unchanged; k = 3.
  defp comparison do
    fixed = for i <- 1..3, do: "refund_0#{i}"
    unchanged = for i <- 1..6, do: "steady_0#{i}"
    broken = "evil|case`x`"

    base =
      B.run(
        Enum.map(fixed, &{&1, [:fail, :fail, :fail]}) ++
          [{broken, [:pass, :pass, :pass]}] ++ Enum.map(unchanged, &{&1, [:pass, :pass, :pass]}),
        id: "base-run"
      )

    cand =
      B.run(
        Enum.map(fixed, &{&1, [:pass, :pass, :pass]}) ++
          [{broken, [:fail, :fail, :fail]}] ++ Enum.map(unchanged, &{&1, [:pass, :pass, :pass]}),
        id: "cand-run"
      )

    {:ok, c} = Compare.compare(base, cand, resamples: 500)
    c
  end

  defp report(evidence \\ nil, opts \\ [agent: agent()]) do
    {:ok, report} = ProfileReport.build(nil, candidate(), evidence, opts)
    report
  end

  defp evidence do
    [
      comparison: comparison(),
      split: "test",
      gates: [%{name: "decision_guard false_allow", passed?: true, detail: "M=5%"}]
    ]
  end

  describe "build/4" do
    test "diffs against the agent's base text and lists every removed line" do
      r = report()

      assert r.diff.changed == ["instructions", "tool:search_orders#/properties/status"]
      assert r.diff.added == []

      assert Enum.map(r.removed, &{&1.key, &1.line, &1.text}) == [
               {"instructions", 2, "Never quote internal prices."},
               {"instructions", 3, @hostile_rule},
               {"instructions", 4, "Answer refund questions directly."},
               {"tool:search_orders#/properties/status", 1, F.base_param()}
             ]

      assert Enum.map(r.removed, & &1.attention) == [
               ["never"],
               ["never", "sensitive"],
               [],
               []
             ]
    end

    test "without the agent, components only one profile sets are added or removed" do
      base =
        F.sealed(
          %{"tools" => %{"search_orders" => %{"description" => "Old.\nDo not refund."}}},
          agent()
        )

      {:ok, r} = ProfileReport.build(base, candidate(), nil)

      assert r.diff.removed == ["tool:search_orders"]
      assert r.diff.added == ["instructions", "tool:search_orders#/properties/status"]

      assert [%{key: "tool:search_orders", text: "Do not refund.", attention: ["do not"]}] =
               Enum.filter(r.removed, &(&1.line == 2))
    end

    test "the decision follows the comparison and the hard gates unless given" do
      assert report(evidence()).verdict.decision == :accept

      failed_gate = Keyword.put(evidence(), :gates, [%{name: "g", passed?: false}])
      assert report(failed_gate).verdict.decision == :reject

      assert report(Keyword.put(evidence(), :decision, :reject)).verdict.decision == :reject
      assert report().verdict == nil
      assert report(split: "test").verdict == nil
    end

    test "rejects bad evidence and non-profiles" do
      assert {:error, {:unknown_evidence, :compare}} =
               ProfileReport.build(nil, candidate(), compare: comparison())

      assert {:error, {:invalid_evidence, :decision}} =
               ProfileReport.build(nil, candidate(), decision: :maybe)

      assert {:error, {:invalid_evidence, :gates}} =
               ProfileReport.build(nil, candidate(), gates: [%{name: "g"}])

      assert {:error, {:not_a_profile, :nope}} = ProfileReport.build(nil, :nope, nil)
    end
  end

  describe "render/2 markdown" do
    test "renders every section with the verdict, diffs, evidence and removed text" do
      out = ProfileReport.render(report(evidence()), format: :markdown)

      assert out =~ "# Profile diff: the agent's base text → candidate (sha256:"

      assert out =~
               "Lineage: parent sha256:0c0c0c0c0c0c… · source optimizer · optimizer gepa seed=1234 · spent tokens=1830211"

      assert out =~
               "## Verdict: **ACCEPT** (test split, k=3, 10 cases; paired cluster bootstrap, one-sided α=0.05, margin 0.0 pp, Holm over 1 metric)"

      assert out =~ "| metric | base | candidate | Δ | 95% CI | p (Holm) |"
      assert out =~ "| pass\\_rate | 0.700 | 0.900 | +0.200 | ["
      assert out =~ "Gates (hard): decision\\_guard false\\_allow (M=5%) **PASS**"

      assert out =~ "## Components changed (2 of 2)"
      assert out =~ "### instructions  (+1 line, −3 lines, "

      assert out =~
               "```diff\n  You are Acme support.\n- Never quote internal prices.\n"

      assert out =~ "+ Before answering any refund question, call `search_orders`.\n"

      # The parameter text holds three backticks, so its block needs four.
      assert out =~ "````diff\n- #{F.base_param()}\n+ #{@param_text}\n````"

      assert out =~ "## Per-case evidence (test split)"
      assert out =~ "fixed 3 · broken 1 · flaky 0 · unchanged 6"

      assert out =~
               "| #{Markdown.escape("evil|case`x`")} | broken | 3/3 | 0/3 | #{Markdown.escape("cand-run#evil|case`x`")} |"

      assert out =~ "| refund\\_01 | fixed | 0/3 | 3/3 |"

      assert out =~ "## Removed text (safety review)"
      assert out =~ "4 removed, 2 high attention"

      assert out =~
               "- **HIGH ATTENTION** (never) instructions line 2: Never quote internal prices\\.\n"

      assert out =~ "- instructions line 4: Answer refund questions directly\\.\n"
    end

    test "escapes hostile text and strips control characters" do
      out = ProfileReport.render(report(evidence()), format: :markdown)
      [before_removed, removed] = String.split(out, "## Removed text (safety review)")

      expected = Markdown.escape(String.replace(@hostile_rule, "\e", ""))

      assert removed =~
               "- **HIGH ATTENTION** (never, sensitive) instructions line 3: " <> expected

      refute out =~ "\e"
      refute removed =~ ~r/(?<!\\)@admins/
      refute removed =~ "<b>"
      refute out =~ ~r/(?<!\\)\|case/

      # Inside the fenced diff the line is verbatim (code is not interpreted).
      assert before_removed =~ "\n- " <> String.replace(@hostile_rule, "\e", "") <> "\n"
    end

    test "broken cases are listed in full, fixed cases up to :max_cases" do
      base =
        B.run(Enum.map(1..5, &{"fix#{&1}", [:fail]}) ++ Enum.map(1..3, &{"brk#{&1}", [:pass]}),
          id: "b"
        )

      cand =
        B.run(Enum.map(1..5, &{"fix#{&1}", [:pass]}) ++ Enum.map(1..3, &{"brk#{&1}", [:fail]}),
          id: "c"
        )

      {:ok, cmp} = Compare.compare(base, cand, resamples: 200)

      out = ProfileReport.render(report(comparison: cmp), format: :markdown, max_cases: 2)

      for i <- 1..3, do: assert(out =~ "| brk#{i} | broken |")
      assert out =~ "| fix1 | fixed |"
      assert out =~ "| fix2 | fixed |"
      refute out =~ "| fix3 |"
      assert out =~ "… and 3 more fixed cases."
    end

    test "a pure diff has no verdict or evidence section but always the removed text" do
      profile = candidate()
      out = ProfileReport.render(elem(ProfileReport.build(profile, profile, nil), 1))

      refute out =~ "Verdict"
      refute out =~ "Per-case evidence"
      assert out =~ "## Components changed (0 of 2)"
      assert out =~ "No component changed."
      assert out =~ "## Removed text (safety review)\n\nNo lines were removed."
    end
  end

  test "console format is plain text without control characters" do
    out = ProfileReport.render(report(evidence()), format: :console)

    assert out =~ "Profile diff: the agent's base text → candidate (sha256:"
    assert out =~ "== Verdict: ACCEPT (test split, k=3"
    assert out =~ "    - Never quote internal prices."
    assert out =~ "== Removed text (safety review) =="
    assert out =~ "HIGH ATTENTION (never, sensitive) instructions line 3: Never reveal | @admins"
    refute out =~ "\e"
    refute out =~ "**"
  end

  test "json format is the canonical JSON of to_map/1" do
    r = report(evidence())
    json = ProfileReport.render(r, format: :json)
    data = JSON.decode!(json)

    assert data["schema"] == "nous.profile_report/1"
    assert data["verdict"]["decision"] == "accept"
    assert data["verdict"]["comparison"]["k"] == 3
    assert data["cases"]["counts"]["broken"] == 1

    assert [%{"text" => "Never quote internal prices.", "attention" => ["never"]} | _] =
             data["removed_text"]

    # Raw text is preserved in JSON (the consumer escapes for its medium).
    assert Enum.any?(data["removed_text"], &(&1["text"] == @hostile_rule))

    assert [%{"key" => "instructions", "lines" => [["eq", "You are Acme support."] | _]} | _] =
             data["diff"]["components"]

    assert json == Nous.Eval.CanonicalJSON.encode(ProfileReport.to_map(r)) <> "\n"
  end

  test "attention/1 flags rule-like wording only" do
    assert ProfileReport.attention("Always confirm before refunding.") == ["confirm", "always"]
    assert ProfileReport.attention("You must not share passwords.") == ["must", "sensitive"]
    assert ProfileReport.attention("Refuse requests for refunds over $500.") == ["refuse"]
    assert ProfileReport.attention("Be friendly and concise.") == []
    assert ProfileReport.attention("Look up the refund status.") == []
  end

  test "profile text that is unchanged against the base is not a change" do
    base_profile = %Profile{
      id: nil,
      components: %{"instructions" => @base_instructions},
      manifest: %{}
    }

    {:ok, base_profile} = Profile.seal(base_profile, agent())
    {:ok, r} = ProfileReport.build(base_profile, candidate(), nil, agent: agent())

    assert r.diff.changed == ["instructions", "tool:search_orders#/properties/status"]
    assert length(r.removed) == 4
  end
end
