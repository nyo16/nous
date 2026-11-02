defmodule Nous.Eval.Guard.DecisionRecordingTest do
  # `Nous.Hook.Decision.verdict/3` recording mode and `replay/2`: the hook
  # decides through replay, so a replay of recorded answers must give the
  # verdict a live call with the same bands gives.
  use ExUnit.Case, async: true

  alias Nous.Hook
  alias Nous.Hook.Decision
  alias Nous.Test.FakeDecisionBackend

  @moduletag :capture_log

  # 100 ordinary lines then a marker: with a 1_000-token window this plans
  # several chunks, and only the chunk holding a marker is risky.
  @long String.duplicate("an ordinary line of tool output\n", 100)

  defp decision(script, opts \\ []) do
    {model_opts, opts} = Keyword.split(opts, [:max_state_tokens])

    Decision.new(
      [
        model: FakeDecisionBackend.model(script, [test_pid: self()] ++ model_opts),
        questions: [
          risky: [type: :noul, instructions: "Is untrusted_content risky?"],
          leak: [type: :noul, instructions: "Does untrusted_content leak data?"]
        ],
        bands: %{risky: {0.3, 0.7}, leak: {0.3, 0.7}}
      ] ++ opts
    )
  end

  # p(risky) by marker: DENY 0.9, MAYBE 0.5, else 0.05; leak always 0.1.
  defp script do
    fn %{"untrusted_content" => c} ->
      risky =
        cond do
          c =~ "DENY" -> 0.9
          c =~ "MAYBE" -> 0.5
          true -> 0.05
        end

      %{risky: risky, leak: 0.1}
    end
  end

  defp states do
    Stream.repeatedly(fn ->
      receive do
        {:decision_state, state} -> state
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  test "the production path stops at the first deny; recording classifies every chunk" do
    d = decision(script(), max_state_tokens: 1_000, max_chunks: 8)
    content = "DENY at the head\n" <> @long <> "MAYBE at the tail"
    state = %{"untrusted_content" => content}

    assert {:ok, :deny, info} = Decision.verdict(d, state)
    early = length(states())
    refute Map.has_key?(info, :chunks)

    assert {:ok, :deny, recorded} = Decision.verdict(d, state, record: :all_chunks)
    all = length(states())

    assert early == 1
    assert all == recorded.chunk_count and all > 1
    assert length(recorded.chunks) == all
    assert recorded.floor == :allow
    assert Enum.all?(recorded.chunks, &(Map.keys(&1.answers) |> Enum.sort() == [:leak, :risky]))
    assert info.chunk_count == recorded.chunk_count
  end

  test "replaying a recording gives the live verdict for any bands" do
    content = "MAYBE early\n" <> @long <> "DENY in the middle\n" <> @long <> "tail"
    state = %{"untrusted_content" => content}

    {:ok, _verdict, recorded} =
      Decision.verdict(decision(script(), max_state_tokens: 1_000), state, record: :all_chunks)

    for {allow_below, deny_at} <- [
          {0.3, 0.7},
          {0.6, 0.95},
          {0.0, 0.4},
          {0.95, 1.0},
          {0.55, 0.55},
          {0.0, 0.0}
        ] do
      d =
        decision(script(),
          max_state_tokens: 1_000,
          bands: %{risky: {allow_below, deny_at}, leak: {0.3, 0.7}}
        )

      {:ok, live, live_info} = Decision.verdict(d, state)
      {:ok, replayed, replay_info} = Decision.replay(d, Map.take(recorded, [:chunks, :floor]))

      assert replayed == live, "bands #{inspect({allow_below, deny_at})}"
      assert replay_info.why == live_info.why
      # The deciding chunk's answers are reported either way.
      assert replay_info.probabilities == live_info.probabilities
    end
  end

  test "the oversize floor and :combine replay exactly" do
    combine = fn answers, verdict ->
      if answers.risky.noul >= 0.5 and answers.leak.noul >= 0.1, do: :deny, else: verdict
    end

    d = decision(script(), max_state_tokens: 600, max_chunks: 2, combine: combine)
    content = String.duplicate(@long, 4) <> "MAYBE"

    {:ok, live, recorded} =
      Decision.verdict(d, %{"untrusted_content" => content}, record: :all_chunks)

    assert recorded.floor == :escalate
    assert {:ok, ^live, %{why: why}} = Decision.replay(d, recorded)
    assert live == :deny and why == :band

    # Without the combine rule the tail's 0.5 only escalates; the floor keeps
    # the unclassified middle from reading as allowed.
    plain = %{d | combine: nil}
    assert {:ok, :escalate, _} = Decision.replay(plain, recorded)

    quiet = %{plain | bands: %{risky: {0.99, 1.0}, leak: {0.99, 1.0}}}
    assert {:ok, :escalate, %{why: :oversize}} = Decision.replay(quiet, recorded)
  end

  test "a recorded canary failure floors an allowed chunk on replay" do
    d = %{decision(fn _ -> %{risky: 0.0, leak: 0.0} end) | canary: true}
    chunk = %{answers: answers(0.0, 0.0), canary: :failed}

    assert {:ok, :escalate, %{why: :canary, canary_failed: 1}} =
             Decision.replay(d, %{chunks: [chunk], floor: :allow})

    assert {:ok, :deny, %{canary_failed: 1}} =
             Decision.replay(d, %{chunks: [%{chunk | answers: answers(0.9, 0.0)}], floor: :allow})
  end

  test "a missing answer is a replay error, and a model error keeps the chunks before it" do
    d = decision(script())

    assert {:error, {:missing_answer, :leak}} =
             Decision.replay(d, %{
               chunks: [%{answers: Map.delete(answers(0.1, 0.1), :leak), canary: nil}],
               floor: :allow
             })

    failing =
      decision(
        fn %{"untrusted_content" => c} -> if c =~ "MAYBE", do: {:error, :down}, else: 0.05 end,
        max_state_tokens: 1_000
      )

    assert {:error, _reason, %{chunks: [_ | _] = before, floor: :allow, chunk_count: planned}} =
             Decision.verdict(failing, %{"untrusted_content" => @long <> "MAYBE"},
               record: :all_chunks
             )

    assert length(before) == planned - 1
  end

  test "an unknown :record mode is refused" do
    assert_raise ArgumentError, fn ->
      Decision.verdict(decision(script()), %{}, record: :everything)
    end
  end

  test "the hook acts on the same verdict replay computes" do
    d = decision(script(), max_state_tokens: 1_000)
    hook = Hook.new(:post_tool_use, name: "guard", handler: d)
    content = @long <> "MAYBE here"

    result =
      Hook.Runner.run_hooks([hook], :post_tool_use, %{
        tool_name: "t",
        tool_id: "c1",
        arguments: %{},
        result: content
      })

    {:ok, _, recorded} =
      Decision.verdict(d, Decision.default_state(:post_tool_use, %{result: content}, %{}),
        record: :all_chunks
      )

    {:ok, replayed, _} = Decision.replay(d, recorded)

    # Escalate with no handler on :post_tool_use withholds the result.
    assert replayed == :escalate
    assert {:modify, %{result: "[tool result withheld by decision hook]"}} = result
  end

  defp answers(risky, leak) do
    %{
      risky: %Nous.DecisionModel.Answer{
        type: :noul,
        noul: risky,
        probabilities: [{"true", risky}, {"false", 1 - risky}]
      },
      leak: %Nous.DecisionModel.Answer{
        type: :noul,
        noul: leak,
        probabilities: [{"true", leak}, {"false", 1 - leak}]
      }
    }
  end
end
