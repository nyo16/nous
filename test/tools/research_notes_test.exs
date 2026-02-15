defmodule Nous.Tools.ResearchNotesTest do
  use ExUnit.Case, async: true

  alias Nous.Tools.ResearchNotes
  alias Nous.Tool.ContextUpdate
  alias Nous.RunContext

  describe "add_finding/2" do
    test "records a finding with ContextUpdate" do
      ctx = RunContext.new(%{})

      {:ok, result, %ContextUpdate{} = update} =
        ResearchNotes.add_finding(ctx, %{
          "claim" => "Elixir runs on the BEAM VM",
          "source_url" => "https://elixir-lang.org",
          "source_title" => "Elixir Homepage",
          "confidence" => 0.95
        })

      assert result.status == "recorded"
      assert result.finding.claim == "Elixir runs on the BEAM VM"
      assert result.finding.source_url == "https://elixir-lang.org"
      assert result.finding.source_title == "Elixir Homepage"
      assert result.finding.confidence == 0.95
      assert result.finding.recorded_at != nil
      assert result.total_findings == 1

      # Verify ContextUpdate has an append operation for :research_findings
      ops = ContextUpdate.operations(update)
      assert length(ops) == 1
      assert {:append, :research_findings, finding} = hd(ops)
      assert finding.claim == "Elixir runs on the BEAM VM"
    end

    test "uses default confidence of 0.7 when not provided" do
      ctx = RunContext.new(%{})

      {:ok, result, _update} =
        ResearchNotes.add_finding(ctx, %{"claim" => "Some fact"})

      assert result.finding.confidence == 0.7
    end

    test "detects duplicates via Jaro distance" do
      existing_finding = %{
        claim: "Elixir runs on the BEAM virtual machine",
        source_url: "https://elixir-lang.org",
        source_title: "Elixir Homepage",
        confidence: 0.9,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      ctx = RunContext.new(%{research_findings: [existing_finding]})

      # Very similar claim (Jaro distance > 0.85)
      {:ok, result, update} =
        ResearchNotes.add_finding(ctx, %{
          "claim" => "Elixir runs on the BEAM virtual machine"
        })

      assert result.status == "duplicate"
      assert result.message =~ "similar finding already exists"
      assert ContextUpdate.empty?(update)
    end

    test "allows sufficiently different claims" do
      existing_finding = %{
        claim: "Elixir runs on the BEAM virtual machine",
        source_url: nil,
        source_title: nil,
        confidence: 0.9,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      ctx = RunContext.new(%{research_findings: [existing_finding]})

      {:ok, result, update} =
        ResearchNotes.add_finding(ctx, %{
          "claim" => "Phoenix is a web framework for Elixir"
        })

      assert result.status == "recorded"
      assert result.total_findings == 2
      refute ContextUpdate.empty?(update)
    end

    test "handles nil source fields" do
      ctx = RunContext.new(%{})

      {:ok, result, _update} =
        ResearchNotes.add_finding(ctx, %{"claim" => "A fact"})

      assert result.finding.source_url == nil
      assert result.finding.source_title == nil
    end
  end

  describe "list_findings/2" do
    test "returns all findings" do
      findings = [
        %{claim: "Fact A", confidence: 0.9, source_url: nil, source_title: nil, recorded_at: "t"},
        %{claim: "Fact B", confidence: 0.6, source_url: nil, source_title: nil, recorded_at: "t"},
        %{claim: "Fact C", confidence: 0.3, source_url: nil, source_title: nil, recorded_at: "t"}
      ]

      ctx = RunContext.new(%{research_findings: findings})

      result = ResearchNotes.list_findings(ctx, %{})

      assert result.count == 3
      assert result.findings == findings
      assert result.high_confidence == 1
      assert result.low_confidence == 1
    end

    test "returns empty results when no findings exist" do
      ctx = RunContext.new(%{})

      result = ResearchNotes.list_findings(ctx, %{})

      assert result.count == 0
      assert result.findings == []
      assert result.high_confidence == 0
      assert result.low_confidence == 0
    end
  end

  describe "add_gap/2" do
    test "records a knowledge gap" do
      ctx = RunContext.new(%{})

      {:ok, result, %ContextUpdate{} = update} =
        ResearchNotes.add_gap(ctx, %{"question" => "What is the performance overhead?"})

      assert result.status == "recorded"
      assert result.question == "What is the performance overhead?"
      assert result.total_gaps == 1

      ops = ContextUpdate.operations(update)
      assert length(ops) == 1
      assert {:append, :research_gaps, "What is the performance overhead?"} = hd(ops)
    end

    test "appends to existing gaps" do
      ctx = RunContext.new(%{research_gaps: ["Existing gap"]})

      {:ok, result, _update} =
        ResearchNotes.add_gap(ctx, %{"question" => "New gap"})

      assert result.total_gaps == 2
    end
  end

  describe "list_gaps/2" do
    test "returns all gaps" do
      ctx = RunContext.new(%{research_gaps: ["Gap 1", "Gap 2"]})

      result = ResearchNotes.list_gaps(ctx, %{})

      assert result.count == 2
      assert result.gaps == ["Gap 1", "Gap 2"]
    end

    test "returns empty results when no gaps exist" do
      ctx = RunContext.new(%{})

      result = ResearchNotes.list_gaps(ctx, %{})

      assert result.count == 0
      assert result.gaps == []
    end
  end

  describe "add_contradiction/2" do
    test "records a contradiction with ContextUpdate" do
      ctx = RunContext.new(%{})

      {:ok, result, %ContextUpdate{} = update} =
        ResearchNotes.add_contradiction(ctx, %{
          "claim_a" => "Elixir is dynamically typed",
          "claim_b" => "Elixir has a strong type system",
          "sources" => "https://source1.com, https://source2.com"
        })

      assert result.status == "recorded"
      assert result.contradiction.claim_a == "Elixir is dynamically typed"
      assert result.contradiction.claim_b == "Elixir has a strong type system"
      assert result.contradiction.sources == "https://source1.com, https://source2.com"
      assert result.contradiction.recorded_at != nil

      ops = ContextUpdate.operations(update)
      assert length(ops) == 1
      assert {:append, :research_contradictions, contradiction} = hd(ops)
      assert contradiction.claim_a == "Elixir is dynamically typed"
    end

    test "handles missing sources field" do
      ctx = RunContext.new(%{})

      {:ok, result, _update} =
        ResearchNotes.add_contradiction(ctx, %{
          "claim_a" => "Claim one",
          "claim_b" => "Claim two"
        })

      assert result.contradiction.sources == ""
    end
  end

  describe "all_tools/0" do
    test "returns five tools" do
      tools = ResearchNotes.all_tools()

      assert length(tools) == 5

      names = Enum.map(tools, & &1.name)
      assert "add_finding" in names
      assert "list_findings" in names
      assert "add_gap" in names
      assert "list_gaps" in names
      assert "add_contradiction" in names
    end

    test "all tools have correct structure" do
      tools = ResearchNotes.all_tools()

      for tool <- tools do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.parameters)
        assert is_function(tool.function)
        assert tool.takes_ctx == true
      end
    end
  end
end
